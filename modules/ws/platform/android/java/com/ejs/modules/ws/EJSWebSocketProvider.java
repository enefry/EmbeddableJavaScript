package com.ejs.modules.ws;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.ssl.SSLSocketFactory;
import org.json.JSONArray;
import org.json.JSONObject;

final class EJSWebSocketProvider implements EJSProvider {
    private static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private static final int MAX_FRAME_PAYLOAD_BYTES = 16 * 1024 * 1024;
    private final ExecutorService executor = Executors.newCachedThreadPool(new DaemonFactory());
    private final Map<String, State> sockets = new ConcurrentHashMap<>();
    private final Map<String, CloseRequest> pendingCloses = new ConcurrentHashMap<>();
    private final Map<String, CloseRequest> completedCloses = new ConcurrentHashMap<>();
    private final Policy policy;
    EJSWebSocketProvider(String configJSON) throws Exception { policy = Policy.parse(configJSON); }
    public String getModuleID() { return "ejs.ws"; }

    public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
        Operation op = new Operation();
        attachExistingSocketCancel(methodID, payload, op);
        executor.execute(() -> { if (op.isCancelled()) return; try { responder.finishWithData(invoke(methodID, payload, transferBuffer, op), null); } catch (Exception ex) { if (!op.isCancelled()) responder.finishWithData(null, ex); } });
        return op;
    }

    @Override public void close() {
        for (State state : sockets.values()) {
            state.closed = true;
            try { state.socket.close(); } catch (Exception ignored) {}
        }
        sockets.clear();
        pendingCloses.clear();
        completedCloses.clear();
        executor.shutdownNow();
    }

    private void attachExistingSocketCancel(String methodID, byte[] payload, Operation op) {
        if ("connect".equals(methodID) || payload == null || payload.length == 0) return;
        try {
            JSONObject r = new JSONObject(new String(payload, StandardCharsets.UTF_8));
            String socketID = r.optString("socketID", "");
            State state = sockets.get(socketID);
            if (state != null) op.setCancelAction(() -> markClosed(socketID, state, 1006, "websocket operation cancelled", false));
        } catch (Exception ignored) {}
    }

    private byte[] invoke(String method, byte[] payload, byte[] transfer, Operation op) throws Exception {
        JSONObject r = payload == null || payload.length == 0 ? new JSONObject() : new JSONObject(new String(payload, StandardCharsets.UTF_8));
        switch (method) {
            case "connect": return connect(r, op);
            case "send": return send(r, transfer);
            case "close": return close(r);
            case "nextEvent": return nextEvent(r, op);
            default: throw new ProviderException("Unsupported ejs.ws method: " + method);
        }
    }

    private byte[] connect(JSONObject r, Operation op) throws Exception {
        if (!policy.ws) throw new ProviderException("websocket denied by ejs.network policy");
        String socketID = required(r, "socketID"); URI uri = URI.create(required(r, "url"));
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase();
        boolean secure = "wss".equals(scheme); if (!secure && !"ws".equals(scheme)) throw new ProviderException("websocket url is invalid");
        int port = uri.getPort() > 0 ? uri.getPort() : secure ? 443 : 80;
        CloseRequest pending = pendingCloses.remove(socketID);
        if (pending != null) {
            completedCloses.put(socketID, pending);
            return json(new JSONObject().put("socketID", socketID));
        }
        Socket socket = secure ? SSLSocketFactory.getDefault().createSocket(uri.getHost(), port) : new Socket(uri.getHost(), port);
        pending = pendingCloses.remove(socketID);
        if (pending != null) {
            completedCloses.put(socketID, pending);
            try { socket.close(); } catch (Exception ignored) {}
            return json(new JSONObject().put("socketID", socketID));
        }
        State state = new State(socket); sockets.put(socketID, state);
        op.setCancelAction(() -> markClosed(socketID, state, 1006, "websocket operation cancelled", false));
        String key = randomKey(); String path = (uri.getRawPath() == null || uri.getRawPath().isEmpty()) ? "/" : uri.getRawPath(); if (uri.getRawQuery() != null) path += "?" + uri.getRawQuery();
        try {
            StringBuilder req = new StringBuilder();
            req.append("GET ").append(path).append(" HTTP/1.1\r\nHost: ").append(uri.getHost()).append(":").append(port).append("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ").append(key).append("\r\n");
            JSONArray protocols = r.optJSONArray("protocols"); if (protocols != null && protocols.length() > 0) { req.append("Sec-WebSocket-Protocol: "); for (int i=0;i<protocols.length();i++){ if(i>0)req.append(", "); req.append(protocols.getString(i)); } req.append("\r\n"); }
            req.append("\r\n"); socket.getOutputStream().write(req.toString().getBytes(StandardCharsets.US_ASCII)); socket.getOutputStream().flush();
            String response = readHttpHeader(socket.getInputStream());
            if (!response.startsWith("HTTP/1.1 101") && !response.startsWith("HTTP/1.0 101")) throw new ProviderException("websocket handshake failed");
            if (!acceptMatches(response, key)) throw new ProviderException("websocket handshake accept mismatch");
            if (state.closed) return json(new JSONObject().put("socketID", socketID));
            state.events.add(new JSONObject().put("event", "open").put("protocol", selectedProtocol(response)));
            if (state.closed) return json(new JSONObject().put("socketID", socketID));
            executor.execute(() -> readLoop(socketID, state));
        } catch (Exception ex) {
            if (state.closed) return json(new JSONObject().put("socketID", socketID));
            sockets.remove(socketID, state);
            try { socket.close(); } catch (Exception ignored) {}
            throw ex;
        }
        return json(new JSONObject().put("socketID", socketID));
    }

    private byte[] send(JSONObject r, byte[] transfer) throws Exception {
        State s = require(required(r, "socketID")); String type = required(r, "messageType");
        if ("text".equals(type)) writeFrame(s.socket.getOutputStream(), 0x1, r.optString("data", "").getBytes(StandardCharsets.UTF_8));
        else if ("binary".equals(type)) writeFrame(s.socket.getOutputStream(), 0x2, transfer == null ? new byte[0] : transfer);
        else throw new ProviderException("websocket messageType must be text or binary");
        return json(new JSONObject().put("ok", true));
    }

    private byte[] close(JSONObject r) throws Exception {
        String socketID = required(r, "socketID");
        int code = r.optInt("code", 1000);
        String reason = r.optString("reason", "");
        State s = sockets.remove(socketID);
        if (s == null) {
            if (!completedCloses.containsKey(socketID)) pendingCloses.put(socketID, new CloseRequest(code, reason, true));
            return json(new JSONObject().put("ok", true));
        }
        ByteArrayOutputStream body = new ByteArrayOutputStream(); body.write((code >>> 8) & 255); body.write(code & 255); body.write(reason.getBytes(StandardCharsets.UTF_8));
        try { writeFrame(s.socket.getOutputStream(), 0x8, body.toByteArray()); } finally { markClosed(socketID, s, code, reason, true); }
        return json(new JSONObject().put("ok", true));
    }

    private byte[] nextEvent(JSONObject r, Operation op) throws Exception {
        String socketID = required(r, "socketID");
        State s = sockets.get(socketID);
        if (s == null) {
            CloseRequest completed = completedCloses.remove(socketID);
            if (completed != null) return json(closeEvent(completed));
            throw new ProviderException("websocket socket is closed or unknown");
        }
        op.setCancelAction(() -> markClosed(socketID, s, 1006, "websocket nextEvent cancelled", false));
        while (true) {
            JSONObject e = s.events.poll();
            if (e != null) return json(e);
            if (s.closed) { completedCloses.remove(socketID); return json(closeEvent(s)); }
            if (op.isCancelled()) throw new ProviderException("websocket nextEvent cancelled");
            Thread.sleep(10);
        }
    }

    private void readLoop(String id, State s) {
        try {
            InputStream in = s.socket.getInputStream();
            while (!s.closed) {
                Frame f = readFrame(in);
                if (f.opcode == 0x1) s.events.add(new JSONObject().put("event", "message").put("messageType", "text").put("data", new String(f.payload, StandardCharsets.UTF_8)));
                else if (f.opcode == 0x2) s.events.add(new JSONObject().put("event", "message").put("messageType", "binary").put("dataBase64", android.util.Base64.encodeToString(f.payload, android.util.Base64.NO_WRAP)));
                else if (f.opcode == 0x8) { int code = f.payload.length >= 2 ? (((f.payload[0]&255)<<8)|(f.payload[1]&255)) : 1000; String reason = f.payload.length > 2 ? new String(Arrays.copyOfRange(f.payload,2,f.payload.length), StandardCharsets.UTF_8) : ""; markClosed(id, s, code, reason, true); break; }
                else if (f.opcode == 0x9) writeFrame(s.socket.getOutputStream(), 0xA, f.payload);
            }
        } catch (Exception ex) { try { s.events.add(new JSONObject().put("event", "error").put("message", ex.getMessage() == null ? "websocket failed" : ex.getMessage())); } catch (Exception ignored) {} markClosed(id, s, 1006, "", false); }
    }

    private static Frame readFrame(InputStream in) throws Exception { int b0=readByte(in), b1=readByte(in); int opcode=b0&15; long len=b1&127; if(len==126) len=((readByte(in)&255)<<8)|(readByte(in)&255); else if(len==127){ len=0; for(int i=0;i<8;i++){ int next=readByte(in)&255; if(i==0 && (next&128)!=0) throw new ProviderException("websocket frame length is invalid"); len=(len<<8)|next; } } if(len<0||len>MAX_FRAME_PAYLOAD_BYTES||len>Integer.MAX_VALUE) throw new ProviderException("websocket frame exceeds maximum size"); byte[] mask=null; if((b1&128)!=0){ mask=new byte[4]; readFully(in,mask); } byte[] payload=new byte[(int)len]; readFully(in,payload); if(mask!=null) for(int i=0;i<payload.length;i++) payload[i]=(byte)(payload[i]^mask[i%4]); return new Frame(opcode,payload); }
    private static void writeFrame(OutputStream out, int opcode, byte[] payload) throws Exception { byte[] mask=new byte[4]; new SecureRandom().nextBytes(mask); ByteArrayOutputStream frame=new ByteArrayOutputStream(); frame.write(0x80|opcode); int len=payload.length; if(len<126) frame.write(0x80|len); else if(len<=65535){ frame.write(0x80|126); frame.write((len>>>8)&255); frame.write(len&255); } else { frame.write(0x80|127); for(int i=7;i>=0;i--) frame.write((len>>>(8*i))&255); } frame.write(mask); for(int i=0;i<payload.length;i++) frame.write(payload[i]^mask[i%4]); out.write(frame.toByteArray()); out.flush(); }
    private static int readByte(InputStream in) throws Exception { int b=in.read(); if(b<0) throw new ProviderException("websocket closed"); return b; }
    private static void readFully(InputStream in, byte[] b) throws Exception { int o=0; while(o<b.length){ int r=in.read(b,o,b.length-o); if(r<0) throw new ProviderException("websocket closed"); o+=r; } }
    private static String readHttpHeader(InputStream in) throws Exception { ByteArrayOutputStream out=new ByteArrayOutputStream(); int prev=0,cur; while((cur=in.read())>=0){ out.write(cur); String s=out.toString("US-ASCII"); if(s.endsWith("\r\n\r\n")) return s; prev=cur; } throw new ProviderException("websocket handshake closed"); }
    private static String selectedProtocol(String h){ for(String line:h.split("\r?\n")){ int i=line.indexOf(':'); if(i>0 && line.substring(0,i).trim().equalsIgnoreCase("Sec-WebSocket-Protocol")) return line.substring(i+1).trim(); } return ""; }
    private static boolean acceptMatches(String header, String key) throws Exception { String actual=headerValue(header,"Sec-WebSocket-Accept"); return actual!=null && expectedAccept(key).equals(actual.trim()); }
    private static String expectedAccept(String key) throws Exception { MessageDigest sha1=MessageDigest.getInstance("SHA-1"); byte[] digest=sha1.digest((key+GUID).getBytes(StandardCharsets.US_ASCII)); return android.util.Base64.encodeToString(digest, android.util.Base64.NO_WRAP); }
    private static String headerValue(String header,String name){ for(String line:header.split("\r?\n")){ int i=line.indexOf(':'); if(i>0 && line.substring(0,i).trim().equalsIgnoreCase(name)) return line.substring(i+1).trim(); } return null; }
    private static String randomKey(){ byte[] b=new byte[16]; new SecureRandom().nextBytes(b); return android.util.Base64.encodeToString(b, android.util.Base64.NO_WRAP); }
    private State require(String id) throws Exception { State s=sockets.get(id); if(s==null) throw new ProviderException("websocket socket is closed or unknown"); return s; }
    private static JSONObject closeEvent(State s) throws Exception { return new JSONObject().put("event", "close").put("code", s.closeCode).put("reason", s.closeReason).put("wasClean", s.wasClean); }
    private static JSONObject closeEvent(CloseRequest c) throws Exception { return new JSONObject().put("event", "close").put("code", c.code).put("reason", c.reason).put("wasClean", c.clean); }
    private void markClosed(String id, State s, int code, String reason, boolean clean) { if(id!=null){sockets.remove(id);completedCloses.put(id,new CloseRequest(code,reason,clean));} s.closeCode=code; s.closeReason=reason==null?"":reason; s.wasClean=clean; s.closed=true; try { if (s.closeQueued.compareAndSet(false, true)) s.events.add(closeEvent(s)); } catch (Exception ignored) {} try { s.socket.close(); } catch (Exception ignored) {} }
    private static String required(JSONObject o,String k)throws Exception{String v=o.optString(k,null);if(v==null||v.isEmpty())throw new ProviderException(k+" is required");return v;}
    private static byte[] json(JSONObject o){return o.toString().getBytes(StandardCharsets.UTF_8);} private static final class State{final Socket socket;final Queue<JSONObject>events=new ConcurrentLinkedQueue<>();final AtomicBoolean closeQueued=new AtomicBoolean(false);volatile boolean closed;volatile int closeCode=1006;volatile String closeReason="";volatile boolean wasClean;State(Socket s){socket=s;}} private static final class CloseRequest{final int code;final String reason;final boolean clean;CloseRequest(int c,String r,boolean cl){code=c;reason=r==null?"":r;clean=cl;}} private static final class Frame{final int opcode;final byte[]payload;Frame(int o,byte[]p){opcode=o;payload=p;}} private static final class Operation implements EJSProviderOperation{private final AtomicBoolean cancelled=new AtomicBoolean(false);private volatile Runnable cancelAction;boolean isCancelled(){return cancelled.get();}void setCancelAction(Runnable action){cancelAction=action;if(cancelled.get()&&action!=null)action.run();}public void cancel(){if(cancelled.compareAndSet(false,true)){Runnable action=cancelAction;if(action!=null)action.run();}}} private static final class DaemonFactory implements ThreadFactory{public Thread newThread(Runnable r){Thread t=new Thread(r,"ejs-ws");t.setDaemon(true);return t;}} private static final class ProviderException extends Exception{ProviderException(String m){super(m);}} private static final class Policy{final boolean ws;Policy(boolean w){ws=w;}static Policy parse(String j)throws Exception{if(j==null||j.isEmpty())return new Policy(false);JSONObject o=new JSONObject(j);JSONObject c=o.optJSONObject("capabilities");return new Policy(c!=null&&c.optBoolean("ws",false));}}
}
