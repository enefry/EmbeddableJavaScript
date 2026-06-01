package com.ejs.modules.sqlite;

import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteStatement;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;

public final class EJSSQLite {
    public static final String CONFIGURATION_KEY = "ejs.sqlite";
    private static final long JS_MAX_SAFE_INTEGER = 9007199254740991L;
    private EJSSQLite() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("EJSContext is required");
        context.registerProvider(new Provider(Policy.fromJSON(context.configurationValueForKey(CONFIGURATION_KEY))));
        context.evaluateScript(readResource("/com/ejs/modules/sqlite/sqlite.js"), "ejs://modules/sqlite/sqlite.js");
        return true;
    }

    private static String readResource(String name) throws Exception {
        InputStream input = EJSSQLite.class.getResourceAsStream(name);
        if (input == null) throw new IllegalStateException("Missing resource " + name);
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int n; while ((n = in.read(buffer)) >= 0) out.write(buffer, 0, n);
            return out.toString("UTF-8");
        }
    }
    private static final class AsyncOperation implements EJSProviderOperation {
        private final AtomicBoolean cancelled = new AtomicBoolean(false);
        private volatile Future<?> future;
        void setFuture(Future<?> future) { this.future = future; if (cancelled.get() && future != null) future.cancel(true); }
        boolean isCancelled() { return cancelled.get(); }
        @Override public void cancel() { if (cancelled.compareAndSet(false, true)) { Future<?> f = future; if (f != null) f.cancel(true); } }
    }
    private static final class DatabasePolicy {
        final String name; final File path; final boolean canRead; final boolean canWrite; final boolean createIfMissing;
        DatabasePolicy(String name, File path, boolean canRead, boolean canWrite, boolean createIfMissing) throws Exception {
            this.name = name; this.path = path.getCanonicalFile(); this.canRead = canRead; this.canWrite = canWrite; this.createIfMissing = createIfMissing;
        }
    }
    private static final class Policy {
        final Map<String, DatabasePolicy> databases; final int maxRows; final int maxStatementBytes; final int maxResponseBytes;
        Policy(Map<String, DatabasePolicy> databases, int maxRows, int maxStatementBytes, int maxResponseBytes) { this.databases = Collections.unmodifiableMap(databases); this.maxRows = maxRows; this.maxStatementBytes = maxStatementBytes; this.maxResponseBytes = maxResponseBytes; }
        static Policy fromJSON(String json) throws Exception {
            if (json == null || json.isEmpty()) throw new IllegalArgumentException("Missing ejs.sqlite configuration");
            JSONObject object = new JSONObject(json);
            if (object.optInt("version", -1) != 1) throw new IllegalArgumentException("ejs.sqlite requires version 1");
            JSONObject databasesObject = object.optJSONObject("databases");
            if (databasesObject == null || databasesObject.length() == 0) throw new IllegalArgumentException("ejs.sqlite requires databases");
            Map<String, DatabasePolicy> databases = new HashMap<>();
            JSONArray names = databasesObject.names();
            for (int i = 0; names != null && i < names.length(); i++) {
                String name = names.getString(i); if (name.isEmpty()) throw new IllegalArgumentException("ejs.sqlite database names must be non-empty strings");
                JSONObject db = databasesObject.optJSONObject(name); String path = db == null ? "" : db.optString("path", ""); JSONArray permissions = db == null ? null : db.optJSONArray("permissions");
                boolean canRead = false, canWrite = false;
                for (int p = 0; permissions != null && p < permissions.length(); p++) { String permission = permissions.optString(p, ""); if ("read".equals(permission)) canRead = true; else if ("write".equals(permission)) canWrite = true; }
                File file = new File(path);
                if (path.isEmpty() || !file.isAbsolute() || (!canRead && !canWrite)) throw new IllegalArgumentException("ejs.sqlite databases require absolute paths and permissions");
                databases.put(name, new DatabasePolicy(name, file, canRead, canWrite, db.optBoolean("createIfMissing", false)));
            }
            return new Policy(databases, unsigned(object, "maxRows", 1000), unsigned(object, "maxStatementBytes", 64 * 1024), unsigned(object, "maxResponseBytes", 4 * 1024 * 1024));
        }
        private static int unsigned(JSONObject object, String key, int fallback) { if (!object.has(key)) return fallback; long value = object.optLong(key, fallback); return value >= 0 && value <= Integer.MAX_VALUE ? (int)value : fallback; }
    }
    private static final class Connection { final String id; final SQLiteDatabase db; final DatabasePolicy policy; final boolean readOnly; String activeTx; Connection(String id, SQLiteDatabase db, DatabasePolicy policy, boolean readOnly) { this.id = id; this.db = db; this.policy = policy; this.readOnly = readOnly; } }
    private static final class Provider implements EJSProvider {
        private final Policy policy; private final Map<String, Connection> connections = new HashMap<>();
        private final ExecutorService executor = Executors.newSingleThreadExecutor(new DaemonFactory("ejs-sqlite"));
        private boolean closed = false;
        Provider(Policy policy) { this.policy = policy; }
        @Override public String getModuleID() { return CONFIGURATION_KEY; }
        @Override public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            AsyncOperation operation = new AsyncOperation();
            byte[] safePayload = payload == null ? new byte[0] : payload;
            try {
                operation.setFuture(executor.submit(() -> {
                    if (operation.isCancelled()) return;
                    try {
                        byte[] data = result(methodID, safePayload);
                        if (!operation.isCancelled()) responder.finishWithData(data, null);
                    } catch (Exception error) {
                        if (!operation.isCancelled()) responder.finishWithData(null, error);
                    }
                }));
            } catch (RuntimeException error) {
                responder.finishWithData(null, error);
            }
            return operation;
        }
        @Override public synchronized void close() {
            closed = true;
            for (Connection connection : connections.values()) {
                try { connection.db.close(); } catch (Exception ignored) {}
            }
            connections.clear();
            executor.shutdown();
        }
        private synchronized byte[] result(String method, byte[] payload) throws Exception {
            if (closed) throw new IllegalStateException("ejs.sqlite provider is closed");
            if (!method.equals("open") && !method.equals("execute") && !method.equals("query") && !method.equals("begin") && !method.equals("commit") && !method.equals("rollback") && !method.equals("close")) throw new UnsupportedOperationException("Unsupported ejs.sqlite method");
            JSONObject request = new JSONObject(new String(payload, StandardCharsets.UTF_8));
            if (method.equals("open")) return open(request);
            if (method.equals("close")) { close(request); return ok(); }
            Connection c = connection(request);
            if (method.equals("execute")) { execute(c, request); return ok(); }
            if (method.equals("query")) return query(c, request);
            if (method.equals("begin")) { begin(c, request); return ok(); }
            if (method.equals("commit")) { endTx(c, request, true); return ok(); }
            endTx(c, request, false); return ok();
        }
        private byte[] open(JSONObject request) throws Exception {
            String name = request.optString("name", ""); if (name.isEmpty()) throw new IllegalArgumentException("sqlite database name must be a non-empty string");
            DatabasePolicy dbp = policy.databases.get(name); if (dbp == null) throw new SecurityException("sqlite database is not allowed");
            boolean readOnly = request.optBoolean("readOnly", false) || !dbp.canWrite;
            if (readOnly && !dbp.canRead) throw new SecurityException("sqlite database does not allow reads");
            if (!readOnly && !dbp.canWrite) throw new SecurityException("sqlite database does not allow writes");
            File parent = dbp.path.getParentFile(); if (parent != null && !parent.exists() && dbp.createIfMissing && !parent.mkdirs() && !parent.isDirectory()) throw new IllegalStateException("Failed to create sqlite database directory");
            if (!dbp.path.exists() && !dbp.createIfMissing) throw new SecurityException("sqlite database is missing and createIfMissing is false");
            int flags = readOnly ? SQLiteDatabase.OPEN_READONLY : (SQLiteDatabase.OPEN_READWRITE | (dbp.createIfMissing ? SQLiteDatabase.CREATE_IF_NECESSARY : 0));
            SQLiteDatabase db = SQLiteDatabase.openDatabase(dbp.path.getPath(), null, flags);
            String id = request.optString("connection", ""); if (id.isEmpty()) throw new IllegalArgumentException("sqlite connection is required");
            Connection previous = connections.remove(id); if (previous != null) previous.db.close();
            connections.put(id, new Connection(id, db, dbp, readOnly)); return ok();
        }
        private Connection connection(JSONObject request) { String id = request.optString("connection", ""); Connection c = connections.get(id); if (c == null || !c.db.isOpen()) throw new IllegalArgumentException("sqlite database is closed"); return c; }
        private void close(JSONObject request) { String id = request.optString("connection", ""); Connection c = connections.remove(id); if (c != null) c.db.close(); }
        private String sql(JSONObject request) { String sql = request.optString("sql", ""); if (sql.isEmpty()) throw new IllegalArgumentException("sqlite sql must be a non-empty string"); if (sql.getBytes(StandardCharsets.UTF_8).length > policy.maxStatementBytes) throw new IllegalArgumentException("sqlite statement exceeds maxStatementBytes"); return sql; }
        private void checkTx(Connection c, JSONObject request) { String tx = request.optString("transaction", null); if (c.activeTx != null && !c.activeTx.equals(tx)) throw new IllegalStateException("sqlite transaction mismatch"); }
        private void execute(Connection c, JSONObject request) throws Exception { if (c.readOnly || !c.policy.canWrite) throw new SecurityException("sqlite connection is read-only"); checkTx(c, request); SQLiteStatement s = c.db.compileStatement(sql(request)); try { bind(s, request.optJSONArray("params")); s.execute(); } finally { s.close(); } }
        private byte[] query(Connection c, JSONObject request) throws Exception {
            if (!c.policy.canRead) throw new SecurityException("sqlite database does not allow reads"); checkTx(c, request);
            String[] args = stringArgs(request.optJSONArray("params")); Cursor cursor = c.db.rawQuery(sql(request) + " LIMIT " + policy.maxRows, args);
            try { JSONArray rows = new JSONArray(); String[] names = cursor.getColumnNames(); while (cursor.moveToNext()) { JSONObject row = new JSONObject(); for (int i = 0; i < names.length; i++) putColumn(row, names[i], cursor, i); rows.put(row); } byte[] data = new JSONObject().put("rows", rows).toString().getBytes(StandardCharsets.UTF_8); if (data.length > policy.maxResponseBytes) throw new IllegalStateException("sqlite response exceeds maxResponseBytes"); return data; } finally { cursor.close(); }
        }
        private void begin(Connection c, JSONObject request) { String tx = request.optString("transaction", ""); if (tx.isEmpty()) throw new IllegalArgumentException("sqlite transaction is required"); if (c.activeTx != null) throw new IllegalStateException("sqlite nested transactions are not supported"); if (c.readOnly || !c.policy.canWrite) throw new SecurityException("sqlite connection is read-only"); c.db.beginTransaction(); c.activeTx = tx; }
        private void endTx(Connection c, JSONObject request, boolean commit) { String tx = request.optString("transaction", ""); if (!tx.equals(c.activeTx)) throw new IllegalStateException("sqlite transaction mismatch"); try { if (commit) c.db.setTransactionSuccessful(); } finally { c.db.endTransaction(); c.activeTx = null; } }
        private void bind(SQLiteStatement s, JSONArray params) throws Exception { for (int i = 0; params != null && i < params.length(); i++) { JSONObject p = params.getJSONObject(i); int idx = i + 1; String type = p.optString("type", ""); if ("null".equals(type)) s.bindNull(idx); else if ("boolean".equals(type)) s.bindLong(idx, p.optBoolean("value") ? 1 : 0); else if ("number".equals(type)) s.bindDouble(idx, p.optDouble("value")); else if ("string".equals(type)) s.bindString(idx, p.optString("value", "")); else throw new IllegalArgumentException("unsupported sqlite param type"); } }
        private String[] stringArgs(JSONArray params) throws Exception { if (params == null || params.length() == 0) return null; String[] args = new String[params.length()]; for (int i = 0; i < params.length(); i++) { JSONObject p = params.getJSONObject(i); args[i] = p.isNull("value") ? null : String.valueOf(p.get("value")); } return args; }
        private void putColumn(JSONObject row, String name, Cursor cursor, int index) throws Exception { switch (cursor.getType(index)) { case Cursor.FIELD_TYPE_NULL: row.put(name, JSONObject.NULL); break; case Cursor.FIELD_TYPE_INTEGER: long v = cursor.getLong(index); row.put(name, Math.abs(v) > JS_MAX_SAFE_INTEGER ? new JSONObject().put("type", "int64").put("value", String.valueOf(v)) : v); break; case Cursor.FIELD_TYPE_FLOAT: row.put(name, cursor.getDouble(index)); break; case Cursor.FIELD_TYPE_BLOB: row.put(name, android.util.Base64.encodeToString(cursor.getBlob(index), android.util.Base64.NO_WRAP)); break; default: row.put(name, cursor.getString(index)); } }
        private byte[] ok() { return "{\"ok\":true}".getBytes(StandardCharsets.UTF_8); }
    }
    private static final class DaemonFactory implements ThreadFactory {
        private final String name;
        DaemonFactory(String name) { this.name = name; }
        public Thread newThread(Runnable r) { Thread thread = new Thread(r, name); thread.setDaemon(true); return thread; }
    }
}
