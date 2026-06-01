package com.ejs.modules.fs;

import android.system.ErrnoException;
import android.system.Os;
import android.system.StructStatVfs;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.CopyOption;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.DirectoryStream;
import java.nio.file.NoSuchFileException;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public final class EJSFileSystem {
    public static final String CONFIGURATION_KEY = "ejs.fs";
    private EJSFileSystem() {}
    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("EJSContext is required");
        context.registerProvider(new Provider(Policy.fromJSON(context.configurationValueForKey(CONFIGURATION_KEY))));
        context.evaluateScript(readResource("/com/ejs/modules/fs/fs.js"), "ejs://modules/fs/fs.js");
        return true;
    }
    private static String readResource(String name) throws Exception { InputStream input = EJSFileSystem.class.getResourceAsStream(name); if (input == null) throw new IllegalStateException("Missing resource " + name); try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) { byte[] b = new byte[8192]; int n; while ((n = in.read(b)) >= 0) out.write(b, 0, n); return out.toString("UTF-8"); } }
    private static final class AsyncOperation implements EJSProviderOperation {
        private final AtomicBoolean cancelled = new AtomicBoolean(false);
        private volatile Future<?> future;
        void setFuture(Future<?> future) { this.future = future; if (cancelled.get() && future != null) future.cancel(true); }
        boolean isCancelled() { return cancelled.get(); }
        @Override public void cancel() { if (cancelled.compareAndSet(false, true)) { Future<?> f = future; if (f != null) f.cancel(true); } }
    }
    private static final class Root { final String name; final File path; final boolean read; final boolean write; final boolean create; Root(String name, File path, boolean read, boolean write, boolean create) throws Exception { this.name = name; this.path = path.getCanonicalFile(); this.read = read; this.write = write; this.create = create; } }
    private static final class Policy { final String defaultRoot; final Map<String, Root> roots; final long limitBytes; Policy(String defaultRoot, Map<String, Root> roots, long limitBytes) { this.defaultRoot = defaultRoot; this.roots = Collections.unmodifiableMap(roots); this.limitBytes = limitBytes; }
        static Policy fromJSON(String json) throws Exception { if (json == null || json.isEmpty()) throw new IllegalArgumentException("Missing ejs.fs configuration"); JSONObject o = new JSONObject(json); if (o.optInt("version", -1) != 1) throw new IllegalArgumentException("ejs.fs requires version 1"); String def = o.optString("defaultRoot", ""); JSONObject ro = o.optJSONObject("roots"); if (def.isEmpty() || ro == null || ro.length() == 0) throw new IllegalArgumentException("ejs.fs requires defaultRoot and roots"); Map<String, Root> roots = new HashMap<>(); JSONArray names = ro.names(); for (int i = 0; names != null && i < names.length(); i++) { String name = names.getString(i); JSONObject r = ro.optJSONObject(name); String path = r == null ? "" : r.optString("path", ""); JSONArray ps = r == null ? null : r.optJSONArray("permissions"); boolean read = false, write = false; for (int p = 0; ps != null && p < ps.length(); p++) { String permission = ps.optString(p, ""); if ("read".equals(permission)) read = true; else if ("write".equals(permission)) write = true; } File f = new File(path); if (name.isEmpty() || path.isEmpty() || !f.isAbsolute() || (!read && !write)) throw new IllegalArgumentException("ejs.fs roots require absolute paths and permissions"); roots.put(name, new Root(name, f, read, write, r.optBoolean("createIfMissing", false))); } if (!roots.containsKey(def)) throw new IllegalArgumentException("ejs.fs defaultRoot must exist in roots"); return new Policy(def, roots, o.optLong("limitBytes", 8L * 1024L * 1024L)); }
    }
    private static final class Handle { final int id; final RandomAccessFile file; final boolean read; final boolean write; final File path; Handle(int id, RandomAccessFile file, boolean read, boolean write, File path) { this.id = id; this.file = file; this.read = read; this.write = write; this.path = path; } }
    private static final class OpenFlags { final boolean read; final boolean write; final boolean append; final boolean truncate; final boolean create; final boolean exclusive; OpenFlags(boolean read, boolean write, boolean append, boolean truncate, boolean create, boolean exclusive) { this.read = read; this.write = write; this.append = append; this.truncate = truncate; this.create = create; this.exclusive = exclusive; } }
    private static final class Provider implements EJSProvider {
        private final Policy policy; private final AtomicInteger nextHandle = new AtomicInteger(1); private final Map<Integer, Handle> handles = new HashMap<>();
        private final ExecutorService executor = Executors.newSingleThreadExecutor(new DaemonFactory("ejs-fs"));
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
        private synchronized byte[] result(String method, byte[] payload, byte[] transfer) throws Exception {
            if (closed) throw new IllegalStateException("ejs.fs provider is closed");
            JSONObject r = payload.length == 0 ? new JSONObject() : new JSONObject(new String(payload, StandardCharsets.UTF_8));
            switch (method) {
                case "readFile": return Files.readAllBytes(path(r, false, true).toPath());
                case "writeFile": {
                    File wf = path(r, true, false);
                    byte[] data = transfer == null ? new byte[0] : transfer;
                    ensureWriteLimit(data.length);
                    Files.write(wf.toPath(), data, writeOptions(r));
                    return ok();
                }
                case "stat": return stat(path(r, false, true), false);
                case "lstat": return stat(pathNoFollow(r, false, true), true);
                case "exists": return json(new JSONObject().put("exists", Files.exists(pathNoFollow(r, false, false).toPath(), LinkOption.NOFOLLOW_LINKS)));
                case "access": access(r); return ok();
                case "open": return open(r);
                case "fileHandleRead": return hread(r);
                case "fileHandleWrite": return hwrite(r, transfer);
                case "fileHandleTruncate": htruncate(r); return ok();
                case "fileHandleDatasync":
                case "fileHandleSync": handle(r).file.getFD().sync(); return ok();
                case "fileHandleClose": close(r.optInt("handle", -1)); return ok();
                case "readdir":
                case "list": return readdir(path(r, false, true));
                case "mkdir": {
                    File d = path(r, true, false);
                    if (r.optBoolean("recursive", false)) {
                        if (!d.mkdirs() && !d.isDirectory()) throw new IllegalStateException("Failed to create directory");
                    } else if (!d.mkdir()) throw new IllegalStateException("Failed to create directory");
                    return ok();
                }
                case "copyFile": {
                    File src = path(r, false, true);
                    File dst = path(r, true, false, "newPath", "newRoot");
                    ensureWriteLimit(Files.size(src.toPath()));
                    Files.copy(src.toPath(), dst.toPath(), copyOptions(r));
                    return ok();
                }
                case "rename": Files.move(path(r, true, true).toPath(), path(r, true, false, "newPath", "newRoot").toPath(), StandardCopyOption.REPLACE_EXISTING); return ok();
                case "delete":
                case "remove":
                case "rm":
                case "unlink": delete(pathNoFollow(r, true, false).toPath(), r.optBoolean("recursive", false), r.optBoolean("force", false)); return ok();
                case "readLink": return json(new JSONObject().put("target", Files.readSymbolicLink(pathNoFollow(r, false, true).toPath()).toString()));
                case "link": Files.createLink(path(r, true, false, "newPath", "newRoot").toPath(), path(r, false, true).toPath()); return ok();
                case "symlink": Files.createSymbolicLink(path(r, true, false).toPath(), symlinkTarget(r)); return ok();
                case "statFs": return statfs(path(r, false, true));
                case "makeTempDir": return temp(r, true);
                case "makeTempFile": return temp(r, false);
                case "chmod": Os.chmod(pathNoFollow(r, true, false).getPath(), r.optInt("mode", 0644)); return ok();
                case "chown": Os.chown(path(r, true, false).getPath(), r.optInt("uid", -1), r.optInt("gid", -1)); return ok();
                case "lchown": Os.lchown(pathNoFollow(r, true, false).getPath(), r.optInt("uid", -1), r.optInt("gid", -1)); return ok();
                case "utime": File f = path(r, true, false); f.setLastModified((long)r.optDouble("mtimeMs", System.currentTimeMillis())); return ok();
                case "lutime": File lf = pathNoFollow(r, true, false); lf.setLastModified((long)r.optDouble("mtimeMs", System.currentTimeMillis())); return ok();
                default: throw new UnsupportedOperationException("Unsupported ejs.fs method");
            }
        }
        private Root root(JSONObject r, boolean write) throws Exception { String name = r.has("root") && !r.isNull("root") ? r.optString("root", "") : policy.defaultRoot; Root root = policy.roots.get(name); if (root == null) throw new SecurityException("fs root is not allowed"); if (write && !root.write) throw new SecurityException("fs root does not allow writes"); if (!write && !root.read) throw new SecurityException("fs root does not allow reads"); if (!root.path.exists()) { if (!root.create) throw new SecurityException("fs root is missing and createIfMissing is false"); if (!root.path.mkdirs() && !root.path.isDirectory()) throw new IllegalStateException("Failed to create fs root"); } if (!root.path.isDirectory()) throw new SecurityException("fs root path is not a directory"); return root; }
        private File path(JSONObject r, boolean write, boolean read) throws Exception { return path(r, write, read, "path", "root"); }
        private File path(JSONObject r, boolean write, boolean read, String pathKey, String rootKey) throws Exception { String p = r.optString(pathKey, ""); if (p.isEmpty() || p.contains("..")) throw new IllegalArgumentException("fs path must be a non-empty relative path without parent traversal"); Root root = rootKey.equals("root") ? root(r, write) : rootForName(r.has(rootKey) ? r.optString(rootKey) : r.optString("root", policy.defaultRoot), write); if (read && !root.read) throw new SecurityException("fs root does not allow reads"); File out = new File(root.path, p).getCanonicalFile(); String prefix = root.path.getCanonicalPath(); if (!out.getPath().equals(prefix) && !out.getPath().startsWith(prefix + File.separator)) throw new SecurityException("fs path escapes root"); return out; }
        private File pathNoFollow(JSONObject r, boolean write, boolean read) throws Exception { return pathNoFollow(r, write, read, "path", "root"); }
        private File pathNoFollow(JSONObject r, boolean write, boolean read, String pathKey, String rootKey) throws Exception { String p = r.optString(pathKey, ""); if (p.isEmpty() || p.contains("..")) throw new IllegalArgumentException("fs path must be a non-empty relative path without parent traversal"); Root root = rootKey.equals("root") ? root(r, write) : rootForName(r.has(rootKey) ? r.optString(rootKey) : r.optString("root", policy.defaultRoot), write); if (read && !root.read) throw new SecurityException("fs root does not allow reads"); Path rootPath = root.path.toPath().toRealPath(); Path out = rootPath.resolve(p).normalize(); if (!out.equals(rootPath) && !out.startsWith(rootPath)) throw new SecurityException("fs path escapes root"); Path current = rootPath; Path relative = rootPath.relativize(out); int count = relative.getNameCount(); for (int i = 0; i + 1 < count; i++) { current = current.resolve(relative.getName(i)); if (Files.isSymbolicLink(current)) throw new SecurityException("fs path traverses a symlink"); } return out.toFile(); }
        private Root rootForName(String name, boolean write) throws Exception { JSONObject o = new JSONObject().put("root", name); return root(o, write); }
        private String writeFlag(JSONObject r) { return r.has("flag") && !r.isNull("flag") ? r.optString("flag") : "w"; }
        private StandardOpenOption[] writeOptions(JSONObject r) {
            String flag = writeFlag(r);
            if ("w".equals(flag)) return new StandardOpenOption[]{StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE};
            if ("wx".equals(flag)) return new StandardOpenOption[]{StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE};
            throw new IllegalArgumentException("Unsupported fs write flag");
        }
        private CopyOption[] copyOptions(JSONObject r) {
            String flag = writeFlag(r);
            if ("w".equals(flag)) return new CopyOption[]{StandardCopyOption.REPLACE_EXISTING};
            if ("wx".equals(flag)) return new CopyOption[0];
            throw new IllegalArgumentException("Unsupported fs copy flag");
        }
        private Path symlinkTarget(JSONObject r) {
            String target = r.optString("target", "");
            if (target.isEmpty()) throw new IllegalArgumentException("symlink target is required");
            if (new File(target).isAbsolute() || pathContainsParent(target)) throw new SecurityException("Symlink target may not escape its root");
            return new File(target).toPath();
        }
        private static boolean pathContainsParent(String path) { for (String part : path.split("[/\\\\]+")) if ("..".equals(part)) return true; return false; }
        private OpenFlags parseFlags(String flags) { String f = flags == null || flags.isEmpty() ? "r" : flags; switch (f) { case "r": case "rs": return new OpenFlags(true, false, false, false, false, false); case "r+": case "rs+": return new OpenFlags(true, true, false, false, false, false); case "w": return new OpenFlags(false, true, false, true, true, false); case "wx": case "xw": return new OpenFlags(false, true, false, true, true, true); case "w+": return new OpenFlags(true, true, false, true, true, false); case "wx+": case "xw+": return new OpenFlags(true, true, false, true, true, true); case "a": return new OpenFlags(false, true, true, false, true, false); case "ax": case "xa": return new OpenFlags(false, true, true, false, true, true); case "a+": return new OpenFlags(true, true, true, false, true, false); case "ax+": case "xa+": return new OpenFlags(true, true, true, false, true, true); default: throw new IllegalArgumentException("unsupported fs open flags"); } }
        private byte[] open(JSONObject r) throws Exception { OpenFlags flags = parseFlags(r.optString("flags", "r")); File f = path(r, flags.write, flags.read); if (flags.write && f.getParentFile() != null) f.getParentFile().mkdirs(); if (flags.exclusive) Files.createFile(f.toPath()); else if (flags.create && !f.exists()) Files.createFile(f.toPath()); RandomAccessFile raf = new RandomAccessFile(f, flags.write ? "rw" : "r"); if (flags.truncate) { ensureWriteLimit(0); raf.setLength(0); } if (flags.append) raf.seek(raf.length()); int id = nextHandle.getAndIncrement(); handles.put(id, new Handle(id, raf, flags.read, flags.write, f)); return json(new JSONObject().put("handle", id)); }
        private Handle handle(JSONObject r) { Handle h = handles.get(r.optInt("handle", -1)); if (h == null) throw new IllegalArgumentException("fs file handle is closed"); return h; }
        private void close(int id) throws Exception { Handle h = handles.remove(id); if (h != null) h.file.close(); }
        @Override public synchronized void close() {
            closed = true;
            for (Handle handle : handles.values()) {
                try { handle.file.close(); } catch (Exception ignored) {}
            }
            handles.clear();
            executor.shutdown();
        }
        private byte[] hread(JSONObject r) throws Exception { Handle h = handle(r); if (!h.read) throw new SecurityException("fs handle does not allow reads"); int length = r.optInt("length", 0); if (r.has("position") && !r.isNull("position")) h.file.seek(r.optLong("position")); byte[] b = new byte[Math.max(0, length)]; int n = h.file.read(b); if (n < 0) n = 0; byte[] out = new byte[n]; System.arraycopy(b, 0, out, 0, n); return out; }
        private byte[] hwrite(JSONObject r, byte[] data) throws Exception { Handle h = handle(r); if (!h.write) throw new SecurityException("fs handle does not allow writes"); byte[] bytes = data == null ? new byte[0] : data; long position = r.has("position") && !r.isNull("position") ? r.optLong("position") : h.file.getFilePointer(); ensureWriteLimit(Math.max(h.file.length(), position + bytes.length)); if (r.has("position") && !r.isNull("position")) h.file.seek(position); h.file.write(bytes); return json(new JSONObject().put("bytesWritten", bytes.length)); }
        private void htruncate(JSONObject r) throws Exception { Handle h = handle(r); if (!h.write) throw new SecurityException("fs handle does not allow writes"); long length = r.optLong("length", 0); ensureWriteLimit(length); h.file.setLength(length); }
        private void ensureWriteLimit(long resultingSize) { if (policy.limitBytes >= 0 && resultingSize > policy.limitBytes) throw new SecurityException("fs write exceeds limitBytes"); }
        private void access(JSONObject r) throws Exception { File f = path(r, false, true); String mode = r.optString("mode", "read"); if ((mode.contains("read") || "r".equals(mode)) && !f.canRead()) throw new SecurityException("fs path is not readable"); if ((mode.contains("write") || "w".equals(mode)) && !f.canWrite()) throw new SecurityException("fs path is not writable"); }
        private byte[] stat(File f, boolean lstat) throws Exception { BasicFileAttributes a = Files.readAttributes(f.toPath(), BasicFileAttributes.class, lstat ? new LinkOption[]{LinkOption.NOFOLLOW_LINKS} : new LinkOption[0]); String type = a.isSymbolicLink() ? "symbolicLink" : a.isDirectory() ? "directory" : a.isRegularFile() ? "file" : "other"; int mode = a.isSymbolicLink() ? 0120000 : a.isDirectory() ? 0040000 : a.isRegularFile() ? 0100000 : 0; return json(new JSONObject().put("type", type).put("size", a.size()).put("mtimeMs", a.lastModifiedTime().toMillis()).put("atimeMs", a.lastAccessTime().toMillis()).put("ctimeMs", a.lastModifiedTime().toMillis()).put("birthtimeMs", a.creationTime().toMillis()).put("mode", mode).put("dev", 0).put("ino", 0).put("nlink", 1).put("uid", 0).put("gid", 0).put("rdev", 0).put("blksize", 0).put("blocks", 0)); }
        private byte[] readdir(File d) throws Exception { JSONArray entries = new JSONArray(); File[] files = d.listFiles(); if (files != null) for (File f : files) entries.put(new JSONObject().put("name", f.getName()).put("type", f.isDirectory() ? "directory" : f.isFile() ? "file" : "other")); return json(new JSONObject().put("entries", entries)); }
        private void delete(Path p, boolean recursive, boolean force) throws Exception { if (!Files.exists(p, LinkOption.NOFOLLOW_LINKS)) { if (force) return; throw new NoSuchFileException(p.toString()); } if (Files.isDirectory(p, LinkOption.NOFOLLOW_LINKS)) { if (!recursive) { Files.delete(p); return; } try (DirectoryStream<Path> stream = Files.newDirectoryStream(p)) { for (Path child : stream) delete(child, true, false); } } Files.delete(p); }
        private byte[] statfs(File f) throws Exception { StructStatVfs s = Os.statvfs(f.getPath()); return json(new JSONObject().put("type", 0).put("bsize", s.f_bsize).put("blocks", s.f_blocks).put("bfree", s.f_bfree).put("bavail", s.f_bavail).put("files", s.f_files).put("ffree", s.f_ffree)); }
        private byte[] temp(JSONObject r, boolean dir) throws Exception { File base = path(r, true, true); String prefix = r.optString("prefix", "tmp-"); File created = dir ? Files.createTempDirectory(base.toPath(), prefix).toFile() : Files.createTempFile(base.toPath(), prefix, "").toFile(); return json(new JSONObject().put("path", created.getName())); }
        private byte[] ok() { return "{\"ok\":true}".getBytes(StandardCharsets.UTF_8); } private byte[] json(JSONObject o) { return o.toString().getBytes(StandardCharsets.UTF_8); }
    }
    private static final class DaemonFactory implements ThreadFactory {
        private final String name;
        DaemonFactory(String name) { this.name = name; }
        public Thread newThread(Runnable r) { Thread thread = new Thread(r, name); thread.setDaemon(true); return thread; }
    }
}
