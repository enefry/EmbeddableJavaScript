package com.ejs.modules.kv;

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
import android.util.Base64;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;

public final class EJSKeyValueStore {
    public static final String CONFIGURATION_KEY = "ejs.kv";
    private EJSKeyValueStore() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("EJSContext is required");
        Policy policy = Policy.fromJSON(context.configurationValueForKey(CONFIGURATION_KEY));
        context.registerProvider(new Provider(policy));
        context.evaluateScript(readResource("/com/ejs/modules/kv/kv.js"), "ejs://modules/kv/kv.js");
        context.evaluateScript(readResource("/com/ejs/modules/kv/storage.js"), "ejs://modules/kv/storage.js");
        return true;
    }

    private static String readResource(String name) throws Exception {
        InputStream input = EJSKeyValueStore.class.getResourceAsStream(name);
        if (input == null) throw new IllegalStateException("Missing resource " + name);
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) >= 0) out.write(buffer, 0, n);
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

    private static final class StorePolicy {
        final String name;
        final File path;
        final boolean canRead;
        final boolean canWrite;
        final boolean createIfMissing;
        StorePolicy(String name, File path, boolean canRead, boolean canWrite, boolean createIfMissing) throws Exception {
            this.name = name;
            this.path = path.getCanonicalFile();
            this.canRead = canRead;
            this.canWrite = canWrite;
            this.createIfMissing = createIfMissing;
        }
    }

    private static final class Policy {
        final String defaultStore;
        final Map<String, StorePolicy> stores;
        final int maxKeyBytes;
        final int maxValueBytes;
        final int maxKeysPerList;
        Policy(String defaultStore, Map<String, StorePolicy> stores, int maxKeyBytes, int maxValueBytes, int maxKeysPerList) {
            this.defaultStore = defaultStore;
            this.stores = Collections.unmodifiableMap(stores);
            this.maxKeyBytes = maxKeyBytes;
            this.maxValueBytes = maxValueBytes;
            this.maxKeysPerList = maxKeysPerList;
        }
        static Policy fromJSON(String json) throws Exception {
            if (json == null || json.isEmpty()) throw new IllegalArgumentException("Missing ejs.kv configuration");
            JSONObject object = new JSONObject(json);
            if (object.optInt("version", -1) != 1) throw new IllegalArgumentException("ejs.kv requires version 1");
            String defaultStore = object.optString("defaultStore", "");
            JSONObject storesObject = object.optJSONObject("stores");
            if (defaultStore.isEmpty() || storesObject == null || storesObject.length() == 0) {
                throw new IllegalArgumentException("ejs.kv requires defaultStore and stores");
            }
            Map<String, StorePolicy> stores = new HashMap<>();
            JSONArray names = storesObject.names();
            for (int i = 0; names != null && i < names.length(); i++) {
                String name = names.getString(i);
                if (name.isEmpty()) throw new IllegalArgumentException("ejs.kv store names must be non-empty strings");
                JSONObject store = storesObject.optJSONObject(name);
                String path = store == null ? "" : store.optString("path", "");
                JSONArray permissions = store == null ? null : store.optJSONArray("permissions");
                boolean canRead = false, canWrite = false;
                for (int p = 0; permissions != null && p < permissions.length(); p++) {
                    String permission = permissions.optString(p, "");
                    if ("read".equals(permission)) canRead = true;
                    else if ("write".equals(permission)) canWrite = true;
                }
                File file = new File(path);
                if (path.isEmpty() || !file.isAbsolute() || (!canRead && !canWrite)) {
                    throw new IllegalArgumentException("ejs.kv stores require absolute paths and permissions");
                }
                stores.put(name, new StorePolicy(name, file, canRead, canWrite, store.optBoolean("createIfMissing", false)));
            }
            if (!stores.containsKey(defaultStore)) throw new IllegalArgumentException("ejs.kv defaultStore must exist in stores");
            return new Policy(defaultStore, stores, unsigned(object, "maxKeyBytes", 512), unsigned(object, "maxValueBytes", 1024 * 1024), unsigned(object, "maxKeysPerList", 1000));
        }
        private static int unsigned(JSONObject object, String key, int fallback) {
            if (!object.has(key)) return fallback;
            long value = object.optLong(key, fallback);
            return value >= 0 && value <= Integer.MAX_VALUE ? (int)value : fallback;
        }
    }

    private static final class Provider implements EJSProvider {
        private final Policy policy;
        private final Map<String, SQLiteDatabase> dbs = new HashMap<>();
        private final ExecutorService executor = Executors.newSingleThreadExecutor(new DaemonFactory("ejs-kv"));
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
                        byte[] data = result(methodID, safePayload, transferBuffer);
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
            for (SQLiteDatabase db : dbs.values()) {
                try { db.close(); } catch (Exception ignored) {}
            }
            dbs.clear();
            executor.shutdown();
        }
        private synchronized byte[] result(String method, byte[] payload, byte[] transfer) throws Exception {
            if (closed) throw new IllegalStateException("ejs.kv provider is closed");
            if (!method.equals("get") && !method.equals("set") && !method.equals("delete") && !method.equals("has") && !method.equals("keys") && !method.equals("clear")) throw new UnsupportedOperationException("Unsupported ejs.kv method");
            JSONObject request = new JSONObject(new String(payload, StandardCharsets.UTF_8));
            boolean write = method.equals("set") || method.equals("delete") || method.equals("clear");
            StorePolicy store = storeFor(request, write);
            if (method.equals("keys")) return keys(store);
            if (method.equals("clear")) { db(store, true).execSQL("DELETE FROM kv_entries"); return ok(); }
            String key = request.optString("key", null);
            if (key == null || key.isEmpty()) throw new IllegalArgumentException("kv key must be a non-empty string");
            if (key.getBytes(StandardCharsets.UTF_8).length > policy.maxKeyBytes) throw new IllegalArgumentException("kv key exceeds maxKeyBytes");
            if (method.equals("get")) return get(store, key);
            if (method.equals("set")) { set(store, key, transfer == null ? new byte[0] : transfer); return ok(); }
            if (method.equals("delete")) return deleted(store, key);
            return exists(store, key);
        }
        private StorePolicy storeFor(JSONObject request, boolean write) throws Exception {
            String name = request.has("store") && !request.isNull("store") ? request.optString("store", "") : policy.defaultStore;
            if (name.isEmpty()) throw new IllegalArgumentException("kv store must be a non-empty string");
            StorePolicy store = policy.stores.get(name);
            if (store == null) throw new SecurityException("kv store is not allowed");
            if (write && !store.canWrite) throw new SecurityException("kv store does not allow writes");
            if (!write && !store.canRead) throw new SecurityException("kv store does not allow reads");
            return store;
        }
        private SQLiteDatabase db(StorePolicy store, boolean create) throws Exception {
            File database = new File(store.path, "kv.sqlite3").getCanonicalFile();
            SQLiteDatabase cached = dbs.get(database.getPath());
            if (cached != null && cached.isOpen()) return cached;
            if (!store.path.exists()) {
                if (!store.createIfMissing && !create) throw new SecurityException("kv store is missing and createIfMissing is false");
                if (!store.path.mkdirs() && !store.path.isDirectory()) throw new IllegalStateException("Failed to create kv store");
            }
            if (!store.path.isDirectory()) throw new SecurityException("kv store path is not a directory");
            int flags = SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.CREATE_IF_NECESSARY;
            if (!store.canWrite && !create) flags = SQLiteDatabase.OPEN_READONLY;
            SQLiteDatabase opened = SQLiteDatabase.openDatabase(database.getPath(), null, flags);
            if (store.canWrite || create) {
                opened.execSQL("PRAGMA journal_mode=WAL");
                opened.execSQL("CREATE TABLE IF NOT EXISTS kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL)");
            }
            dbs.put(database.getPath(), opened);
            return opened;
        }
        private byte[] get(StorePolicy store, String key) throws Exception {
            Cursor c = db(store, false).rawQuery("SELECT value FROM kv_entries WHERE key=?", new String[]{key});
            try {
                if (!c.moveToFirst()) return json(new JSONObject().put("found", false));
                byte[] value = c.getBlob(0);
                return json(new JSONObject()
                    .put("found", true)
                    .put("value", Base64.encodeToString(value == null ? new byte[0] : value, Base64.NO_WRAP)));
            } finally { c.close(); }
        }
        private void set(StorePolicy store, String key, byte[] value) throws Exception {
            if (value.length > policy.maxValueBytes) throw new IllegalArgumentException("kv value exceeds maxValueBytes");
            SQLiteStatement s = db(store, true).compileStatement("INSERT OR REPLACE INTO kv_entries(key,value,updated_at) VALUES(?,?,?)");
            try { s.bindString(1, key); s.bindBlob(2, value); s.bindLong(3, System.currentTimeMillis()); s.executeInsert(); } finally { s.close(); }
        }
        private byte[] deleted(StorePolicy store, String key) throws Exception {
            SQLiteStatement s = db(store, false).compileStatement("DELETE FROM kv_entries WHERE key=?");
            try { s.bindString(1, key); return json(new JSONObject().put("deleted", s.executeUpdateDelete() > 0)); } finally { s.close(); }
        }
        private byte[] exists(StorePolicy store, String key) throws Exception {
            Cursor c = db(store, false).rawQuery("SELECT 1 FROM kv_entries WHERE key=? LIMIT 1", new String[]{key});
            try { return json(new JSONObject().put("exists", c.moveToFirst())); } finally { c.close(); }
        }
        private byte[] keys(StorePolicy store) throws Exception {
            JSONArray array = new JSONArray();
            Cursor c = db(store, false).rawQuery("SELECT key FROM kv_entries ORDER BY key LIMIT ?", new String[]{String.valueOf(policy.maxKeysPerList)});
            try { while (c.moveToNext()) array.put(c.getString(0)); } finally { c.close(); }
            return json(new JSONObject().put("keys", array));
        }
        private byte[] ok() { return "{\"ok\":true}".getBytes(StandardCharsets.UTF_8); }
        private byte[] json(JSONObject o) { return o.toString().getBytes(StandardCharsets.UTF_8); }
    }
    private static final class DaemonFactory implements ThreadFactory {
        private final String name;
        DaemonFactory(String name) { this.name = name; }
        public Thread newThread(Runnable r) { Thread thread = new Thread(r, name); thread.setDaemon(true); return thread; }
    }
}
