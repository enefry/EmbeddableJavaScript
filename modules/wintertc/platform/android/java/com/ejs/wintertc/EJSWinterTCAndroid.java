package com.ejs.wintertc;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;
import org.json.JSONArray;
import org.json.JSONObject;

import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class EJSWinterTCAndroid {
    private EJSWinterTCAndroid() {}

    public static final class InstallOptions {
        private boolean installDefaultProviders;
        public boolean isInstallDefaultProviders() { return installDefaultProviders; }
        public void setInstallDefaultProviders(boolean installDefaultProviders) { this.installDefaultProviders = installDefaultProviders; }
    }

    public static void installIntoContext(EJSContext context) throws Exception {
        installIntoContext(context, null);
    }

    public static void installIntoContext(EJSContext context, InstallOptions options) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("context is required");
        }
        context.evaluateScript(EJSWinterTCScripts.BUNDLE, "wintertc_android_bundle.js");
        if (options != null && options.isInstallDefaultProviders()) {
            context.registerProvider(new ClockProvider());
            context.registerProvider(new CryptoProvider());
            context.registerProvider(new ConsoleProvider());
            context.registerProvider(new FetchProvider());
        }
    }

    private static final class ImmediateOperation implements EJSProviderOperation {
        @Override public void cancel() {}
    }

    private static final class ClockProvider implements EJSProvider {
        private final long startNanos = System.nanoTime();
        private final double timeOriginEpochMs = System.currentTimeMillis();
        @Override public String getModuleID() { return "wintertc.clock"; }
        @Override public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            responder.finishWithData(null, new UnsupportedOperationException("wintertc.clock only supports sync methods"));
            return new ImmediateOperation();
        }
        @Override public byte[] invokeSyncMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context) throws Exception {
            if (!"now".equals(methodID)) throw new UnsupportedOperationException("Unsupported wintertc.clock method");
            JSONObject response = new JSONObject();
            response.put("timeOriginEpochMs", timeOriginEpochMs);
            response.put("nowMs", (System.nanoTime() - startNanos) / 1000000.0);
            return response.toString().getBytes(StandardCharsets.UTF_8);
        }
    }

    private static final class CryptoProvider implements EJSProvider {
        private final SecureRandom random = new SecureRandom();
        @Override public String getModuleID() { return "wintertc.crypto"; }
        @Override public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            try {
                if (!"digest".equals(methodID)) throw new UnsupportedOperationException("Unsupported wintertc.crypto method");
                JSONObject request = parseObject(payload);
                String algorithm = request.optString("algorithm", "").toUpperCase(Locale.US).replace("-", "");
                String javaAlgorithm;
                if ("SHA256".equals(algorithm)) javaAlgorithm = "SHA-256";
                else if ("SHA384".equals(algorithm)) javaAlgorithm = "SHA-384";
                else if ("SHA512".equals(algorithm)) javaAlgorithm = "SHA-512";
                else throw new IllegalArgumentException("Unsupported digest algorithm");
                MessageDigest digest = MessageDigest.getInstance(javaAlgorithm);
                responder.finishWithData(digest.digest(transferBuffer == null ? new byte[0] : transferBuffer), null);
            } catch (Exception error) {
                responder.finishWithData(null, error);
            }
            return new ImmediateOperation();
        }
        @Override public byte[] invokeSyncMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context) throws Exception {
            if (!"getRandomValues".equals(methodID)) throw new UnsupportedOperationException("Unsupported wintertc.crypto sync method");
            int byteLength = parseObject(payload).optInt("byteLength", 0);
            if (byteLength < 0 || byteLength > 65536) throw new IllegalArgumentException("Invalid getRandomValues byteLength");
            byte[] bytes = new byte[byteLength];
            random.nextBytes(bytes);
            return bytes;
        }
    }

    private static final class ConsoleProvider implements EJSProvider {
        @Override public String getModuleID() { return "wintertc.console"; }
        @Override public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            try {
                if (!"write".equals(methodID)) throw new UnsupportedOperationException("Unsupported wintertc.console method");
                JSONObject request = parseObject(payload);
                JSONArray args = request.optJSONArray("args");
                StringBuilder line = new StringBuilder("[WinterTC ").append(request.optString("level", "log")).append("]");
                if (args != null) {
                    for (int i = 0; i < args.length(); i++) line.append(' ').append(args.optString(i));
                }
                System.out.println(line.toString());
                responder.finishWithData(new byte[0], null);
            } catch (Exception error) {
                responder.finishWithData(null, error);
            }
            return new ImmediateOperation();
        }
    }

    private static final class FetchProvider implements EJSProvider {
        private static final long STREAM_IDLE_TTL_MS = 30000;
        private final Map<String, StreamState> streams = new ConcurrentHashMap<>();
        private final Map<String, FetchOperation> activeRequests = new ConcurrentHashMap<>();
        private final ScheduledExecutorService streamCleanupExecutor = Executors.newSingleThreadScheduledExecutor(new ThreadFactory() {
            @Override public Thread newThread(Runnable runnable) {
                Thread thread = new Thread(runnable, "EJSWinterTCFetchStreamCleanup");
                thread.setDaemon(true);
                return thread;
            }
        });

        @Override public String getModuleID() { return "wintertc.fetch"; }
        @Override public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            if ("start".equals(methodID)) {
                FetchOperation operation = new FetchOperation(responder);
                try {
                    JSONObject request = parseObject(payload);
                    String signalId = request.optString("signalId", "");
                    operation.signalId = signalId;
                    if (signalId.length() > 0) activeRequests.put(signalId, operation);
                    byte[] body = transferBuffer == null ? new byte[0] : transferBuffer;
                    new Thread(() -> {
                        try {
                            operation.finish(start(request, body, operation), null);
                        } catch (Exception error) {
                            operation.finish(null, error);
                        } finally {
                            if (operation.signalId.length() > 0) activeRequests.remove(operation.signalId, operation);
                        }
                    }, "EJSWinterTCFetch-" + UUID.randomUUID()).start();
                } catch (Exception error) {
                    operation.finish(null, error);
                }
                return operation;
            }
            try {
                byte[] result;
                if ("pull".equals(methodID)) result = pull(payload);
                else if ("cancel".equals(methodID)) result = cancel(payload);
                else throw new UnsupportedOperationException("Unsupported wintertc.fetch method");
                responder.finishWithData(result, null);
            } catch (Exception error) {
                responder.finishWithData(null, error);
            }
            return new ImmediateOperation();
        }

        @Override public void close() {
            for (FetchOperation operation : activeRequests.values()) {
                operation.cancel();
            }
            activeRequests.clear();
            for (StreamState stream : streams.values()) {
                stream.close();
            }
            streams.clear();
            streamCleanupExecutor.shutdownNow();
        }

        private byte[] start(JSONObject request, byte[] body, FetchOperation operation) throws Exception {
            URL url = new URL(request.optString("url", ""));
            byte[] responseBody;
            int status = 200;
            String statusText = "OK";
            Map<String, String> headers = new HashMap<>();
            String finalUrl = url.toString();
            boolean redirected = false;
            if ("data".equalsIgnoreCase(url.getProtocol())) {
                DataUrl data = parseDataUrl(finalUrl);
                responseBody = data.body;
                headers.put("content-type", data.contentType);
                headers.put("content-length", Integer.toString(responseBody.length));
            } else if ("http".equalsIgnoreCase(url.getProtocol()) || "https".equalsIgnoreCase(url.getProtocol())) {
                HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                operation.setConnection(connection);
                connection.setInstanceFollowRedirects(true);
                connection.setRequestMethod(request.optString("method", "GET"));
                JSONArray headerPairs = request.optJSONArray("headers");
                if (headerPairs != null) {
                    for (int i = 0; i < headerPairs.length(); i++) {
                        JSONArray pair = headerPairs.optJSONArray(i);
                        if (pair != null && pair.length() >= 2) connection.addRequestProperty(pair.optString(0), pair.optString(1));
                    }
                }
                if (body.length > 0) {
                    connection.setDoOutput(true);
                    connection.getOutputStream().write(body);
                }
                operation.throwIfCancelled();
                status = connection.getResponseCode();
                statusText = connection.getResponseMessage() == null ? "" : connection.getResponseMessage();
                finalUrl = connection.getURL().toString();
                redirected = !finalUrl.equals(url.toString());
                for (Map.Entry<String, java.util.List<String>> entry : connection.getHeaderFields().entrySet()) {
                    if (entry.getKey() != null && entry.getValue() != null && !entry.getValue().isEmpty()) {
                        headers.put(entry.getKey().toLowerCase(Locale.US), entry.getValue().get(0));
                    }
                }
                InputStream input = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
                responseBody = input == null ? new byte[0] : readAll(input, operation);
                connection.disconnect();
                operation.setConnection(null);
            } else {
                throw new UnsupportedOperationException("Unsupported fetch URL scheme");
            }
            String streamId = responseBody.length == 0 ? "" : "fetch-stream-" + UUID.randomUUID();
            if (streamId.length() > 0) {
                StreamState stream = new StreamState(responseBody);
                operation.setStream(streamId, stream);
                streams.put(streamId, stream);
                scheduleStreamCleanup(streamId, stream);
            }
            JSONObject response = new JSONObject();
            response.put("streamId", streamId);
            response.put("status", status);
            response.put("statusText", statusText);
            response.put("headers", new JSONObject(headers));
            response.put("url", finalUrl);
            response.put("redirected", redirected);
            return response.toString().getBytes(StandardCharsets.UTF_8);
        }

        private byte[] pull(byte[] payload) throws Exception {
            JSONObject request = parseObject(payload);
            String streamId = request.optString("bodyStreamId", request.optString("streamId", ""));
            int maxBytes = Math.max(1, request.optInt("maxBytes", 65536));
            StreamState state = streams.get(streamId);
            if (state == null) return new byte[] {0x00};
            byte[] chunk = state.next(maxBytes);
            if (chunk == null) {
                removeStream(streamId, state);
                return new byte[] {0x00};
            }
            scheduleStreamCleanup(streamId, state);
            ByteArrayOutputStream out = new ByteArrayOutputStream(chunk.length + 1);
            out.write(0x01);
            out.write(chunk);
            return out.toByteArray();
        }

        private byte[] cancel(byte[] payload) throws Exception {
            JSONObject request = parseObject(payload);
            String streamId = request.optString("bodyStreamId", request.optString("streamId", ""));
            String signalId = request.optString("signalId", "");
            StreamState stream = streamId.length() == 0 ? null : streams.get(streamId);
            if (stream != null) removeStream(streamId, stream);
            FetchOperation operation = signalId.length() == 0 ? null : activeRequests.remove(signalId);
            if (operation != null) operation.cancel();
            return new byte[0];
        }

        private void scheduleStreamCleanup(String streamId, StreamState stream) {
            if (streamId.length() == 0 || stream.isClosed()) {
                return;
            }
            StreamCleanup cleanupTask = new StreamCleanup(streamId, stream);
            ScheduledFuture<?> cleanup = streamCleanupExecutor.schedule(cleanupTask, STREAM_IDLE_TTL_MS, TimeUnit.MILLISECONDS);
            cleanupTask.setFuture(cleanup);
            ScheduledFuture<?> previous = stream.replaceCleanup(cleanup);
            if (previous != null) {
                previous.cancel(false);
            }
        }

        private void removeStreamIfCleanupCurrent(String streamId, StreamState stream, ScheduledFuture<?> expectedCleanup) {
            if (streamId.length() == 0 || stream == null || !stream.isCleanup(expectedCleanup)) {
                return;
            }
            removeStream(streamId, stream);
        }

        private void removeStream(String streamId, StreamState stream) {
            if (streamId.length() == 0 || stream == null) {
                return;
            }
            if (streams.remove(streamId, stream)) {
                stream.close();
            } else {
                stream.cancelCleanup();
            }
        }

        private final class StreamCleanup implements Runnable {
            private final String streamId;
            private final StreamState stream;
            private volatile ScheduledFuture<?> future;

            StreamCleanup(String streamId, StreamState stream) {
                this.streamId = streamId;
                this.stream = stream;
            }

            void setFuture(ScheduledFuture<?> future) {
                this.future = future;
            }

            @Override public void run() {
                removeStreamIfCleanupCurrent(streamId, stream, future);
            }
        }
    }

    private static final class FetchOperation implements EJSProviderOperation {
        private final EJSProviderResponder responder;
        private final AtomicBoolean finished = new AtomicBoolean(false);
        private final AtomicBoolean cancelled = new AtomicBoolean(false);
        volatile String signalId = "";
        private volatile HttpURLConnection connection;
        private volatile String streamId = "";
        private volatile StreamState stream;

        FetchOperation(EJSProviderResponder responder) {
            this.responder = responder;
        }

        @Override public void cancel() {
            cancelled.set(true);
            HttpURLConnection currentConnection = connection;
            if (currentConnection != null) currentConnection.disconnect();
            StreamState currentStream = stream;
            if (currentStream != null) currentStream.close();
        }

        void setConnection(HttpURLConnection connection) {
            this.connection = connection;
            if (cancelled.get() && connection != null) connection.disconnect();
        }

        void setStream(String streamId, StreamState stream) {
            this.streamId = streamId;
            this.stream = stream;
            if (cancelled.get()) stream.close();
        }

        void throwIfCancelled() throws Exception {
            if (cancelled.get()) throw new InterruptedException("fetch request cancelled");
        }

        void finish(byte[] data, Exception error) {
            if (finished.compareAndSet(false, true)) {
                responder.finishWithData(data, error);
            }
        }
    }

    private static final class StreamState {
        final byte[] body;
        int offset;
        boolean closed;
        ScheduledFuture<?> cleanup;
        StreamState(byte[] body) { this.body = body; }
        synchronized byte[] next(int maxBytes) {
            if (closed) return null;
            if (offset >= body.length) return null;
            int count = Math.min(maxBytes, body.length - offset);
            byte[] chunk = new byte[count];
            System.arraycopy(body, offset, chunk, 0, count);
            offset += count;
            return chunk;
        }
        synchronized ScheduledFuture<?> replaceCleanup(ScheduledFuture<?> nextCleanup) {
            if (closed) {
                nextCleanup.cancel(false);
                return null;
            }
            ScheduledFuture<?> previous = cleanup;
            cleanup = nextCleanup;
            return previous;
        }
        synchronized void cancelCleanup() {
            ScheduledFuture<?> current = cleanup;
            cleanup = null;
            if (current != null) current.cancel(false);
        }
        synchronized boolean isClosed() {
            return closed;
        }
        synchronized boolean isCleanup(ScheduledFuture<?> expectedCleanup) {
            return !closed && cleanup == expectedCleanup;
        }
        synchronized void close() {
            closed = true;
            offset = body.length;
            cancelCleanup();
        }
    }

    private static final class DataUrl {
        byte[] body;
        String contentType;
    }

    private static JSONObject parseObject(byte[] payload) throws Exception {
        if (payload == null || payload.length == 0) return new JSONObject();
        return new JSONObject(new String(payload, StandardCharsets.UTF_8));
    }

    private static byte[] readAll(InputStream input, FetchOperation operation) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            operation.throwIfCancelled();
            out.write(buffer, 0, count);
        }
        input.close();
        return out.toByteArray();
    }

    private static DataUrl parseDataUrl(String value) throws Exception {
        String payload = value.substring("data:".length());
        int comma = payload.indexOf(',');
        if (comma < 0) throw new IllegalArgumentException("Invalid data URL");
        String metadata = payload.substring(0, comma);
        String data = payload.substring(comma + 1);
        DataUrl result = new DataUrl();
        result.contentType = "text/plain;charset=US-ASCII";
        boolean base64 = false;
        if (metadata.length() > 0) {
            String[] parts = metadata.split(";");
            if (parts.length > 0 && parts[0].length() > 0) result.contentType = parts[0];
            for (String part : parts) if ("base64".equalsIgnoreCase(part)) base64 = true;
        }
        if (base64) {
            result.body = Base64.decode(URLDecoder.decode(data, "UTF-8"), Base64.DEFAULT);
        } else {
            result.body = URLDecoder.decode(data, "UTF-8").getBytes(StandardCharsets.UTF_8);
        }
        return result;
    }
}
