package com.ejs.modules.net;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONArray;
import org.json.JSONObject;

final class EJSNetProvider implements EJSProvider {
    private final ExecutorService executor = Executors.newCachedThreadPool(new DaemonFactory("ejs-net"));
    private final Map<String, Socket> sockets = new ConcurrentHashMap<>();
    private final Map<String, ServerSocket> listeners = new ConcurrentHashMap<>();
    private final Map<String, DatagramSocket> datagrams = new ConcurrentHashMap<>();
    private final AtomicLong nextSocketID = new AtomicLong(1);
    private final AtomicLong nextListenerID = new AtomicLong(1);
    private final AtomicLong nextDatagramID = new AtomicLong(1);
    private final Policy policy;

    EJSNetProvider(String configJSON) throws Exception { this.policy = Policy.parse(configJSON); }
    public String getModuleID() { return "ejs.net"; }

    public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
        Operation op = new Operation();
        executor.execute(() -> {
            if (op.cancelled.get()) return;
            try {
                JSONObject request = payload == null || payload.length == 0 ? new JSONObject() : new JSONObject(new String(payload, StandardCharsets.UTF_8));
                byte[] result = invoke(methodID, request, transferBuffer == null ? new byte[0] : transferBuffer, op);
                if (!op.cancelled.get()) responder.finishWithData(result, null);
            } catch (Exception ex) {
                if (!op.cancelled.get()) responder.finishWithData(null, ex);
            }
        });
        return op;
    }

    @Override public void close() {
        closeAllQuietly(sockets);
        closeAllQuietly(listeners);
        closeAllQuietly(datagrams);
        executor.shutdownNow();
    }

    private byte[] invoke(String method, JSONObject r, byte[] transfer, Operation op) throws Exception {
        switch (method) {
            case "lookup": return lookup(r);
            case "tcpConnect": return tcpConnect(r, op);
            case "tcpListen": return tcpListen(r, op);
            case "tcpAccept": return tcpAccept(r, op);
            case "tcpRead": return tcpRead(r, op);
            case "tcpWrite": return tcpWrite(r, transfer);
            case "tcpShutdown": return tcpShutdown(r);
            case "tcpClose": return tcpClose(r);
            case "tcpListenerClose": return tcpListenerClose(r);
            case "udpBind": return udpBind(r, op);
            case "udpSend": return udpSend(r, transfer);
            case "udpRecv": return udpRecv(r);
            case "udpClose": return udpClose(r);
            default: throw new ProviderException("Unsupported ejs.net method: " + method);
        }
    }

    private byte[] lookup(JSONObject r) throws Exception {
        String host = requiredString(r, "host");
        int family = r.optInt("family", 0);
        if (!policy.lookup) throw new ProviderException("lookup denied by ejs.network policy");
        JSONArray addresses = new JSONArray();
        for (InetAddress address : InetAddress.getAllByName(host)) {
            int addressFamily = address instanceof Inet4Address ? 4 : address instanceof Inet6Address ? 6 : 0;
            if (addressFamily == 0 || (family != 0 && family != addressFamily)) continue;
            addresses.put(new JSONObject().put("address", address.getHostAddress()).put("family", addressFamily).put("canonicalName", address.getCanonicalHostName()));
        }
        return json(new JSONObject().put("addresses", addresses));
    }

    private byte[] tcpConnect(JSONObject r, Operation op) throws Exception {
        String host = requiredString(r, "host");
        int port = requiredPort(r, "port", false);
        if (!policy.tcpConnect) throw new ProviderException("tcpConnect denied by ejs.network policy");
        Socket socket = new Socket();
        op.closeable = socket;
        int timeout = Math.max(0, r.optInt("timeoutMs", 30000));
        socket.connect(new InetSocketAddress(host, port), timeout);
        socket.setTcpNoDelay(r.optBoolean("noDelay", true));
        String id = "tcp-" + nextSocketID.getAndIncrement();
        sockets.put(id, socket);
        op.setCancelAction(() -> closeAndRemoveQuietly(sockets, id));
        if (op.cancelled.get()) { closeAndRemoveQuietly(sockets, id); throw new ProviderException("tcpConnect cancelled"); }
        return json(new JSONObject().put("socketID", id).put("localAddress", endpoint(socket.getLocalAddress(), socket.getLocalPort())).put("remoteAddress", endpoint(socket.getInetAddress(), socket.getPort())));
    }

    private byte[] tcpListen(JSONObject r, Operation op) throws Exception {
        String host = r.optString("host", "0.0.0.0");
        int port = requiredPort(r, "port", true);
        if (!policy.tcpListen) throw new ProviderException("tcpListen denied by ejs.network policy");
        ServerSocket listener = new ServerSocket();
        op.closeable = listener;
        listener.setReuseAddress(r.optBoolean("reuseAddress", true));
        listener.bind(new InetSocketAddress(host, port), Math.max(1, r.optInt("backlog", 128)));
        String id = "lst-" + nextListenerID.getAndIncrement();
        listeners.put(id, listener);
        op.setCancelAction(() -> closeAndRemoveQuietly(listeners, id));
        if (op.cancelled.get()) { closeAndRemoveQuietly(listeners, id); throw new ProviderException("tcpListen cancelled"); }
        return json(new JSONObject().put("listenerID", id).put("localAddress", endpoint(listener.getInetAddress(), listener.getLocalPort())));
    }

    private byte[] tcpAccept(JSONObject r, Operation op) throws Exception {
        ServerSocket listener = require(listeners, requiredString(r, "listenerID"), "tcp listener");
        int timeout = Math.max(0, r.optInt("timeoutMs", 30000));
        long deadline = timeout == 0 ? 0L : System.currentTimeMillis() + timeout;
        listener.setSoTimeout(timeout == 0 ? 250 : Math.min(timeout, 250));
        Socket socket;
        while (true) {
            if (op.cancelled.get()) throw new ProviderException("tcpAccept cancelled");
            try {
                socket = listener.accept();
                break;
            } catch (SocketTimeoutException ex) {
                if (timeout != 0 && System.currentTimeMillis() >= deadline) throw ex;
            }
        }
        op.closeable = socket;
        socket.setTcpNoDelay(true);
        String id = "tcp-" + nextSocketID.getAndIncrement();
        sockets.put(id, socket);
        op.setCancelAction(() -> closeAndRemoveQuietly(sockets, id));
        if (op.cancelled.get()) { closeAndRemoveQuietly(sockets, id); throw new ProviderException("tcpAccept cancelled"); }
        return json(new JSONObject().put("socketID", id).put("localAddress", endpoint(socket.getLocalAddress(), socket.getLocalPort())).put("remoteAddress", endpoint(socket.getInetAddress(), socket.getPort())));
    }

    private byte[] tcpRead(JSONObject r, Operation op) throws Exception {
        Socket socket = require(sockets, requiredString(r, "socketID"), "tcp socket");
        socket.setSoTimeout(Math.max(0, r.optInt("timeoutMs", 30000)));
        op.closeable = socket;
        int max = Math.min(Math.max(1, r.optInt("maxBytes", 65536)), 1048576);
        byte[] buffer = new byte[max];
        int read = socket.getInputStream().read(buffer);
        if (read < 0) return new byte[0];
        return Arrays.copyOf(buffer, read);
    }

    private byte[] tcpWrite(JSONObject r, byte[] transfer) throws Exception {
        Socket socket = require(sockets, requiredString(r, "socketID"), "tcp socket");
        OutputStream out = socket.getOutputStream();
        out.write(transfer == null ? new byte[0] : transfer);
        out.flush();
        return json(new JSONObject().put("bytesWritten", transfer == null ? 0 : transfer.length));
    }

    private byte[] tcpShutdown(JSONObject r) throws Exception {
        Socket socket = require(sockets, requiredString(r, "socketID"), "tcp socket");
        String direction = r.optString("direction", "both");
        if ("read".equals(direction) || "both".equals(direction)) socket.shutdownInput();
        if ("write".equals(direction) || "both".equals(direction)) socket.shutdownOutput();
        return json(new JSONObject().put("ok", true));
    }

    private byte[] tcpClose(JSONObject r) throws Exception { closeAndRemove(sockets, requiredString(r, "socketID")); return json(new JSONObject().put("ok", true)); }
    private byte[] tcpListenerClose(JSONObject r) throws Exception { closeAndRemove(listeners, requiredString(r, "listenerID")); return json(new JSONObject().put("ok", true)); }

    private byte[] udpBind(JSONObject r, Operation op) throws Exception {
        String host = r.optString("host", "0.0.0.0");
        int port = requiredPort(r, "port", true);
        if (!policy.udp) throw new ProviderException("udpBind denied by ejs.network policy");
        DatagramSocket socket = new DatagramSocket(null);
        socket.setReuseAddress(r.optBoolean("reuseAddress", true));
        socket.bind(new InetSocketAddress(host, port));
        String id = "udp-" + nextDatagramID.getAndIncrement();
        datagrams.put(id, socket);
        op.setCancelAction(() -> closeAndRemoveQuietly(datagrams, id));
        if (op.cancelled.get()) { closeAndRemoveQuietly(datagrams, id); throw new ProviderException("udpBind cancelled"); }
        return json(new JSONObject().put("socketID", id).put("localAddress", endpoint(socket.getLocalAddress(), socket.getLocalPort())));
    }

    private byte[] udpSend(JSONObject r, byte[] transfer) throws Exception {
        DatagramSocket socket = require(datagrams, requiredString(r, "socketID"), "udp socket");
        byte[] data = transfer == null ? new byte[0] : transfer;
        if (data.length > policy.maxDatagramBytes) throw new ProviderException("udp datagram exceeds ejs.network limit");
        InetAddress host = InetAddress.getByName(requiredString(r, "host"));
        int port = requiredPort(r, "port", false);
        socket.send(new DatagramPacket(data, data.length, host, port));
        return json(new JSONObject().put("bytesSent", data.length));
    }

    private byte[] udpRecv(JSONObject r) throws Exception {
        DatagramSocket socket = require(datagrams, requiredString(r, "socketID"), "udp socket");
        socket.setSoTimeout(Math.max(0, r.optInt("timeoutMs", 30000)));
        byte[] buffer = new byte[Math.min(Math.max(1, r.optInt("maxBytes", 65536)), policy.maxDatagramBytes)];
        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
        socket.receive(packet);
        return json(new JSONObject().put("data", android.util.Base64.encodeToString(Arrays.copyOf(packet.getData(), packet.getLength()), android.util.Base64.NO_WRAP)).put("remoteAddress", endpoint(packet.getAddress(), packet.getPort())));
    }
    private byte[] udpClose(JSONObject r) throws Exception { DatagramSocket s = datagrams.remove(requiredString(r, "socketID")); if (s == null) throw new ProviderException("udp socket is closed or unknown"); s.close(); return json(new JSONObject().put("ok", true)); }

    private static JSONObject endpoint(InetAddress address, int port) throws Exception { String host = address == null ? "" : address.getHostAddress(); int family = address instanceof Inet6Address ? 6 : 4; return new JSONObject().put("address", host).put("family", family).put("port", port); }
    private static byte[] json(JSONObject o) { return o.toString().getBytes(StandardCharsets.UTF_8); }
    private static String requiredString(JSONObject o, String k) throws Exception { String v = o.optString(k, null); if (v == null || v.length() == 0) throw new ProviderException(k + " is required"); return v; }
    private static int requiredPort(JSONObject o, String k, boolean zero) throws Exception { int v = o.optInt(k, -1); if (v < (zero ? 0 : 1) || v > 65535) throw new ProviderException(k + " is invalid"); return v; }
    private static <T> T require(Map<String,T> m, String id, String what) throws Exception { T v = m.get(id); if (v == null) throw new ProviderException(what + " is closed or unknown"); return v; }
    private static void closeAndRemove(Map<String, ? extends java.io.Closeable> m, String id) throws Exception { java.io.Closeable c = m.remove(id); if (c == null) throw new ProviderException("resource is closed or unknown"); c.close(); }
    private static void closeAndRemoveQuietly(Map<String, ? extends java.io.Closeable> m, String id) { java.io.Closeable c = m.remove(id); if (c != null) try { c.close(); } catch (IOException ignored) {} }
    private static void closeAllQuietly(Map<String, ? extends java.io.Closeable> m) { for (java.io.Closeable c : m.values()) try { c.close(); } catch (IOException ignored) {} m.clear(); }

    private static final class Operation implements EJSProviderOperation { final AtomicBoolean cancelled = new AtomicBoolean(false); volatile Object closeable; volatile Runnable cancelAction; void setCancelAction(Runnable action) { cancelAction = action; if (cancelled.get() && action != null) action.run(); } public void cancel() { cancelled.set(true); Runnable action = cancelAction; if (action != null) { action.run(); return; } Object c = closeable; try { if (c instanceof Socket) ((Socket)c).close(); else if (c instanceof DatagramSocket) ((DatagramSocket)c).close(); } catch (IOException ignored) {} } }
    private static final class DaemonFactory implements ThreadFactory { private final String name; DaemonFactory(String name) { this.name = name; } public Thread newThread(Runnable r) { Thread t = new Thread(r, name); t.setDaemon(true); return t; } }
    private static final class ProviderException extends Exception { ProviderException(String m) { super(m); } }
    private static final class Policy { final boolean lookup,tcpConnect,tcpListen,udp; final int maxDatagramBytes; Policy(boolean l, boolean c, boolean s, boolean u, int m) { lookup=l; tcpConnect=c; tcpListen=s; udp=u; maxDatagramBytes=m; } static Policy parse(String json) throws Exception { if (json == null || json.length() == 0) return new Policy(false,false,false,false,65507); JSONObject o = new JSONObject(json); JSONObject c = o.optJSONObject("capabilities"); JSONObject lim = o.optJSONObject("limits"); return new Policy(c != null && c.optBoolean("dns", false), c != null && c.optBoolean("tcpConnect", false), c != null && c.optBoolean("tcpListen", false), c != null && c.optBoolean("udp", false), lim == null ? 65507 : lim.optInt("maxDatagramBytes", 65507)); } }
}
