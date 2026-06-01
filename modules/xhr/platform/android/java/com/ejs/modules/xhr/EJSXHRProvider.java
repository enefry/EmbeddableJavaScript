package com.ejs.modules.xhr;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONArray;
import org.json.JSONObject;

final class EJSXHRProvider implements EJSProvider {
    private final ExecutorService executor = Executors.newCachedThreadPool(new DaemonFactory());
    private final Map<String, HttpURLConnection> active = new ConcurrentHashMap<>();
    private final Policy policy;
    EJSXHRProvider(String configJSON) throws Exception { policy = Policy.parse(configJSON); }
    public String getModuleID() { return "ejs.xhr"; }

    public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
        Operation op = new Operation();
        if ("abort".equals(methodID)) {
            try {
                JSONObject request = new JSONObject(new String(payload == null ? new byte[0] : payload, StandardCharsets.UTF_8));
                HttpURLConnection connection = active.remove(request.optString("requestID", ""));
                if (connection != null) connection.disconnect();
                responder.finishWithData(json(new JSONObject().put("ok", true)), null);
            } catch (Exception ex) { responder.finishWithData(null, ex); }
            return op;
        }
        if (!"send".equals(methodID)) {
            responder.finishWithData(null, new ProviderException("Unsupported ejs.xhr method: " + methodID));
            return op;
        }
        executor.execute(() -> {
            if (op.cancelled.get()) return;
        try { responder.finishWithData(send(new JSONObject(new String(payload == null ? new byte[0] : payload, StandardCharsets.UTF_8)), transferBuffer, op), null); }
            catch (Exception ex) { if (!op.cancelled.get()) responder.finishWithData(null, ex); }
        });
        return op;
    }

    @Override public void close() {
        for (HttpURLConnection connection : active.values()) {
            connection.disconnect();
        }
        active.clear();
        executor.shutdownNow();
    }

    private byte[] send(JSONObject r, byte[] transfer, Operation op) throws Exception {
        if (!policy.xhr) throw new ProviderException("xhr denied by ejs.network policy");
        String requestID = required(r, "requestID");
        URL url = new URL(required(r, "url"));
        String protocol = url.getProtocol().toLowerCase();
        if (!"http".equals(protocol) && !"https".equals(protocol)) throw new ProviderException("xhr url is invalid");
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) url.openConnection();
            active.put(requestID, c); op.connection = c;
            int timeout = Math.max(0, r.optInt("timeoutMs", 0));
            int effectiveTimeout = timeout == 0 ? policy.requestTimeoutMs : timeout;
            c.setConnectTimeout(effectiveTimeout); c.setReadTimeout(effectiveTimeout);
            c.setUseCaches(false); c.setInstanceFollowRedirects(true);
            c.setRequestMethod(required(r, "method"));
            JSONArray headers = r.optJSONArray("headers");
            if (headers != null) for (int i = 0; i < headers.length(); i++) { JSONObject h = headers.getJSONObject(i); c.setRequestProperty(h.optString("name"), h.optString("value")); }
            byte[] body = transfer != null ? transfer : r.has("bodyText") ? r.optString("bodyText", "").getBytes(StandardCharsets.UTF_8) : null;
            if (body != null) { c.setDoOutput(true); c.setFixedLengthStreamingMode(body.length); try (OutputStream out = c.getOutputStream()) { out.write(body); } }
            int status = c.getResponseCode();
            InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
            byte[] responseBody = readBounded(in, policy.maxBodyBytes);
            JSONObject response = new JSONObject().put("requestID", requestID).put("status", status).put("statusText", c.getResponseMessage() == null ? "" : c.getResponseMessage()).put("responseURL", c.getURL().toString()).put("bodyText", new String(responseBody, StandardCharsets.UTF_8)).put("bodyBase64", android.util.Base64.encodeToString(responseBody, android.util.Base64.NO_WRAP));
            JSONArray responseHeaders = new JSONArray();
            for (Map.Entry<String, List<String>> e : c.getHeaderFields().entrySet()) {
                if (e.getKey() == null || e.getValue() == null) continue;
                for (String v : e.getValue()) responseHeaders.put(new JSONObject().put("name", e.getKey()).put("value", v == null ? "" : v));
            }
            response.put("headers", responseHeaders);
            return json(response);
        } finally {
            active.remove(requestID);
            op.connection = null;
            if (c != null) c.disconnect();
        }
    }

    private static byte[] readBounded(InputStream in, int max) throws Exception {
        if (in == null) return new byte[0];
        try (InputStream input = in; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int total = 0; int read;
            while ((read = input.read(buffer)) >= 0) { total += read; if (total > max) throw new ProviderException("xhr response exceeds ejs.network limit"); out.write(buffer, 0, read); }
            return out.toByteArray();
        }
    }
    private static byte[] json(JSONObject o) { return o.toString().getBytes(StandardCharsets.UTF_8); }
    private static String required(JSONObject o, String k) throws Exception { String v = o.optString(k, null); if (v == null || v.length() == 0) throw new ProviderException(k + " is required"); return v; }
    private static final class Operation implements EJSProviderOperation { final AtomicBoolean cancelled = new AtomicBoolean(false); volatile HttpURLConnection connection; public void cancel() { cancelled.set(true); HttpURLConnection c = connection; if (c != null) c.disconnect(); } }
    private static final class DaemonFactory implements ThreadFactory { public Thread newThread(Runnable r) { Thread t = new Thread(r, "ejs-xhr"); t.setDaemon(true); return t; } }
    private static final class ProviderException extends Exception { ProviderException(String m) { super(m); } }
    private static final class Policy { final boolean xhr; final int requestTimeoutMs,maxBodyBytes; Policy(boolean x,int t,int b){xhr=x;requestTimeoutMs=t;maxBodyBytes=b;} static Policy parse(String json) throws Exception { if (json == null || json.length() == 0) return new Policy(false,30000,8*1024*1024); JSONObject o = new JSONObject(json); JSONObject c=o.optJSONObject("capabilities"); JSONObject h=o.optJSONObject("http"); JSONObject l=o.optJSONObject("limits"); return new Policy(c!=null&&c.optBoolean("xhr",false), h==null?30000:h.optInt("requestTimeoutMs",30000), l==null?8*1024*1024:l.optInt("maxBodyBytes",8*1024*1024)); } }
}
