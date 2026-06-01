package com.ejs.modules.system;

import android.os.Build;
import android.os.Process;
import android.system.Os;
import android.system.StructUtsname;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.Collections;

public final class EJSSystem {
    private static File cwd = new File(System.getProperty("user.dir", "/")).getAbsoluteFile();
    private EJSSystem() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("EJSContext is required");
        context.registerProvider(new Provider());
        context.evaluateScript(readResource("/com/ejs/modules/system/system.js"), "ejs://modules/system/system.js");
        return true;
    }

    private static String readResource(String name) throws Exception {
        InputStream input = EJSSystem.class.getResourceAsStream(name);
        if (input == null) throw new IllegalStateException("Missing resource " + name);
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int n; while ((n = in.read(buffer)) >= 0) out.write(buffer, 0, n);
            return out.toString("UTF-8");
        }
    }
    private static final class ImmediateOperation implements EJSProviderOperation { @Override public void cancel() {} }
    private static final class Provider implements EJSProvider {
        @Override public String getModuleID() { return "ejs.system"; }
        @Override public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            try { responder.finishWithData(result(methodID, payload == null ? new byte[0] : payload), null); }
            catch (Exception error) { responder.finishWithData(null, error); }
            return new ImmediateOperation();
        }
        private synchronized byte[] result(String method, byte[] payload) throws Exception {
            JSONObject request = payload.length == 0 ? new JSONObject() : new JSONObject(new String(payload, StandardCharsets.UTF_8));
            switch (method) {
                case "cwd": return json(new JSONObject().put("cwd", cwd.getPath()));
                case "chdir": { File next = new File(request.optString("path", "")).getCanonicalFile(); if (!next.isDirectory()) throw new IllegalArgumentException("chdir path is not a directory"); cwd = next; return ok(); }
                case "env": return json(new JSONObject().put("env", new JSONObject(System.getenv())));
                case "getenv": { String name = name(request); String value = System.getenv(name); return json(new JSONObject().put("value", value == null ? JSONObject.NULL : value)); }
                case "setenv": throw new UnsupportedOperationException("Android does not support mutating process environment");
                case "unsetenv": throw new UnsupportedOperationException("Android does not support mutating process environment");
                case "pid": return json(new JSONObject().put("pid", Process.myPid()));
                case "ppid": return json(new JSONObject().put("ppid", Os.getppid()));
                case "homeDir": return json(new JSONObject().put("homeDir", System.getProperty("user.home", "")));
                case "tmpDir": return json(new JSONObject().put("tmpDir", System.getProperty("java.io.tmpdir", "")));
                case "exePath": return json(new JSONObject().put("exePath", ""));
                case "hostName": return json(new JSONObject().put("hostName", InetAddress.getLocalHost().getHostName()));
                case "platform": return json(new JSONObject().put("platform", "android"));
                case "arch": return json(new JSONObject().put("arch", Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : System.getProperty("os.arch", "")));
                case "uname": return json(new JSONObject().put("uname", uname()));
                case "uptime": return json(new JSONObject().put("uptime", android.os.SystemClock.elapsedRealtime() / 1000.0));
                case "loadAvg": return json(new JSONObject().put("loadAvg", new JSONArray().put(0).put(0).put(0)));
                case "availableParallelism": return json(new JSONObject().put("availableParallelism", Math.max(1, Runtime.getRuntime().availableProcessors())));
                case "cpuInfo": return json(new JSONObject().put("cpuInfo", cpuInfo()));
                case "networkInterfaces": return json(new JSONObject().put("networkInterfaces", networkInterfaces()));
                case "userInfo": return json(new JSONObject().put("userInfo", userInfo()));
                default: throw new UnsupportedOperationException("Unsupported ejs.system method");
            }
        }
        private String name(JSONObject request) { String name = request.optString("name", ""); if (name.isEmpty() || name.indexOf('=') >= 0) throw new IllegalArgumentException("environment variable name is required"); return name; }
        private JSONObject uname() throws Exception { StructUtsname u = Os.uname(); return new JSONObject().put("sysname", u.sysname).put("nodename", u.nodename).put("release", u.release).put("version", u.version).put("machine", u.machine); }
        private JSONArray cpuInfo() throws Exception { JSONArray cpus = new JSONArray(); int count = Math.max(1, Runtime.getRuntime().availableProcessors()); for (int i = 0; i < count; i++) cpus.put(new JSONObject().put("model", Build.HARDWARE == null ? "" : Build.HARDWARE).put("speed", 0)); return cpus; }
        private JSONObject networkInterfaces() throws Exception { JSONObject result = new JSONObject(); for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) { JSONArray entries = new JSONArray(); for (InetAddress address : Collections.list(ni.getInetAddresses())) entries.put(new JSONObject().put("address", address.getHostAddress()).put("family", address instanceof java.net.Inet6Address ? "IPv6" : "IPv4").put("internal", address.isLoopbackAddress()).put("mac", "")); result.put(ni.getName(), entries); } return result; }
        private JSONObject userInfo() throws Exception { return new JSONObject().put("uid", Process.myUid()).put("gid", Process.myUid()).put("username", System.getProperty("user.name", "")).put("homedir", System.getProperty("user.home", "")).put("shell", ""); }
        private byte[] ok() { return "{\"ok\":true}".getBytes(StandardCharsets.UTF_8); }
        private byte[] json(JSONObject object) { return object.toString().getBytes(StandardCharsets.UTF_8); }
    }
}
