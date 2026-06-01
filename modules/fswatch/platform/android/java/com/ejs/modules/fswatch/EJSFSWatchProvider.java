package com.ejs.modules.fswatch;

import android.os.FileObserver;
import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONObject;

final class EJSFSWatchProvider implements EJSProvider {
    private final EJSContext context;
    private final Policy policy;
    private final ExecutorService callbackExecutor = Executors.newSingleThreadExecutor(new DaemonFactory());
    private final Map<String, FileObserver> watchers = new ConcurrentHashMap<>();
    private final AtomicLong nextID = new AtomicLong(1);
    EJSFSWatchProvider(EJSContext context, String configJSON) throws Exception { this.context = context; this.policy = Policy.parse(configJSON); }
    public String getModuleID() { return "ejs.fswatch"; }

    public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext ignored, EJSProviderResponder responder) {
        try {
            JSONObject request = payload == null || payload.length == 0 ? new JSONObject() : new JSONObject(new String(payload, StandardCharsets.UTF_8));
            byte[] result;
            if ("watch".equals(methodID)) result = watch(request); else if ("close".equals(methodID)) result = close(request); else throw new ProviderException("Unsupported ejs.fswatch method: " + methodID);
            responder.finishWithData(result, null);
        } catch (Exception ex) { responder.finishWithData(null, ex); }
        return () -> {};
    }

    @Override public void close() {
        for (FileObserver observer : watchers.values()) {
            observer.stopWatching();
        }
        watchers.clear();
        callbackExecutor.shutdownNow();
    }

    private byte[] watch(JSONObject r) throws Exception {
        if (r.optBoolean("recursive", false)) throw new ProviderException("Recursive fswatch is not supported by Android FileObserver provider");
        String requestPath = required(r, "path"); String resolved = resolve(requestPath, r.optString("root", policy.defaultRoot));
        String id = Long.toString(nextID.getAndIncrement());
        FileObserver observer = new FileObserver(resolved, FileObserver.MODIFY | FileObserver.CREATE | FileObserver.DELETE | FileObserver.MOVED_FROM | FileObserver.MOVED_TO | FileObserver.ATTRIB | FileObserver.DELETE_SELF | FileObserver.MOVE_SELF) {
            public void onEvent(int event, String path) {
                if (!watchers.containsKey(id)) return;
                String type = ((event & (FileObserver.DELETE | FileObserver.DELETE_SELF | FileObserver.MOVED_FROM | FileObserver.MOVED_TO | FileObserver.MOVE_SELF | FileObserver.CREATE)) != 0) ? "rename" : "change";
                String eventPath = path == null ? requestPath : path;
                callbackExecutor.execute(() -> {
                    if (!watchers.containsKey(id)) return;
                    try { context.evaluateScript("globalThis.__EJSFSWatchDispatch && globalThis.__EJSFSWatchDispatch(" + JSONObject.quote(id) + "," + JSONObject.quote(type) + "," + JSONObject.quote(eventPath) + ");", "ejs_fswatch_event.js"); } catch (Exception ignored) {}
                });
            }
        };
        watchers.put(id, observer); observer.startWatching();
        return json(new JSONObject().put("watcherID", id).put("recursive", false));
    }

    private byte[] close(JSONObject r) throws Exception {
        FileObserver observer = watchers.remove(required(r, "watcherID"));
        if (observer == null) throw new ProviderException("watcher is closed or unknown");
        observer.stopWatching(); return json(new JSONObject().put("ok", true));
    }

    private String resolve(String path, String rootName) throws Exception {
        File root = policy.roots.get(rootName); if (root == null) throw new ProviderException("fswatch root is not allowed");
        File target = new File(path); if (target.isAbsolute() && !policy.allowAbsolutePath) throw new ProviderException("Absolute fswatch paths are not allowed");
        if (!policy.allowParentTraversal && pathContainsParent(path)) throw new ProviderException("Parent traversal is not allowed");
        if (!target.isAbsolute()) target = new File(root, path);
        String rootCanonical = policy.allowSymlinkEscape ? root.getAbsolutePath() : root.getCanonicalPath();
        String targetCanonical = policy.allowSymlinkEscape ? target.getAbsolutePath() : target.getCanonicalPath();
        if (!targetCanonical.equals(rootCanonical) && !targetCanonical.startsWith(rootCanonical + File.separator)) throw new ProviderException("Resolved fswatch path escapes its root");
        return targetCanonical;
    }

    private static boolean pathContainsParent(String path) { for (String p : path.split("[/\\\\]+")) if ("..".equals(p)) return true; return false; }
    private static String required(JSONObject o,String k)throws Exception{String v=o.optString(k,null);if(v==null||v.isEmpty())throw new ProviderException(k+" is required");return v;}
    private static byte[] json(JSONObject o){return o.toString().getBytes(StandardCharsets.UTF_8);} private static final class ProviderException extends Exception{ProviderException(String m){super(m);}}
    private static final class DaemonFactory implements ThreadFactory { public Thread newThread(Runnable r) { Thread t = new Thread(r, "ejs-fswatch-callback"); t.setDaemon(true); return t; } }
    private static final class Policy { final String defaultRoot; final Map<String,File> roots; final boolean allowAbsolutePath,allowParentTraversal,allowSymlinkEscape; Policy(String d,Map<String,File> r,boolean a,boolean p,boolean s){defaultRoot=d;roots=r;allowAbsolutePath=a;allowParentTraversal=p;allowSymlinkEscape=s;} static Policy parse(String j)throws Exception{ if(j==null||j.isEmpty())throw new ProviderException("Missing ejs.fswatch configuration"); JSONObject o=new JSONObject(j); String d=o.optString("defaultRoot",""); JSONObject ro=o.optJSONObject("roots"); if(o.optInt("version",0)!=1||d.isEmpty()||ro==null||ro.length()==0)throw new ProviderException("ejs.fswatch requires version, defaultRoot, and roots"); Map<String,File> roots=new HashMap<>(); java.util.Iterator<String> it=ro.keys(); while(it.hasNext()){String k=it.next(); String p=ro.getJSONObject(k).optString("path",""); if(p.isEmpty()||!new File(p).isAbsolute())throw new ProviderException("ejs.fswatch roots require absolute paths"); roots.put(k,new File(p));} if(!roots.containsKey(d))throw new ProviderException("ejs.fswatch defaultRoot must exist in roots"); JSONObject pp=o.optJSONObject("pathPolicy"); return new Policy(d,roots,pp!=null&&pp.optBoolean("allowAbsolutePath",false),pp!=null&&pp.optBoolean("allowParentTraversal",false),pp!=null&&pp.optBoolean("allowSymlinkEscape",false)); } }
}
