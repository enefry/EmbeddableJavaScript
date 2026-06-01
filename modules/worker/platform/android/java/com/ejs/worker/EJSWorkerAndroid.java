package com.ejs.worker;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;
import com.ejs.platform.EJSRuntime;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class EJSWorkerAndroid {
    public static final String CONFIGURATION_KEY = "ejs.worker";

    public interface WorkerContextInstaller {
        void install(EJSContext workerContext) throws Exception;
    }

    public static final class InstallOptions {
        private WorkerContextInstaller workerContextInstaller;

        public WorkerContextInstaller getWorkerContextInstaller() { return workerContextInstaller; }
        public void setWorkerContextInstaller(WorkerContextInstaller installer) { this.workerContextInstaller = installer; }
    }

    private EJSWorkerAndroid() {}

    public static void installIntoContext(EJSContext context) throws Exception {
        installIntoContext(context, null);
    }

    public static void installIntoContext(EJSContext context, InstallOptions options) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("context is required");
        }
        EJSWorkerProvider provider = new EJSWorkerProvider(context, options == null ? null : options.getWorkerContextInstaller());
        context.registerProvider(provider);
        context.evaluateScript(EJSWorkerScripts.PARENT, "js/worker_parent.js");
    }

    private static final class ImmediateOperation implements EJSProviderOperation {
        @Override public void cancel() {}
    }

    private static final class WorkerLimits {
        int maxWorkers = 4;
        int maxQueuedMessages = 64;
        int maxMessageBytes = 1024 * 1024;
        int maxSourceBytes = 1024 * 1024;
        int startupTimeoutMs = 5000;
        int terminationTimeoutMs = 2000;
    }

    private static final class WorkerSource {
        String source;
        String filename;
        String type;
        String name;
    }

    private static final class WorkerInstance {
        final String workerID;
        final String name;
        final String specifier;
        final WorkerSource source;
        final WorkerLimits limits;
        final Map<String, byte[]> parentInbox = new HashMap<>();
        final Map<String, byte[]> childInbox = new HashMap<>();
        long nextMessageID = 1;
        volatile boolean terminated = false;
        volatile EJSRuntime runtime;
        volatile EJSContext context;
        volatile Thread thread;
        final CountDownLatch readyLatch = new CountDownLatch(1);
        volatile Exception startError;
        volatile boolean preserveParentInboxForClose = false;

        WorkerInstance(String workerID, String name, String specifier, WorkerSource source, WorkerLimits limits) {
            this.workerID = workerID;
            this.name = name;
            this.specifier = specifier;
            this.source = source;
            this.limits = limits;
        }
    }

    private static final class EJSWorkerProvider implements EJSProvider {
        private final EJSContext parentContext;
        private final WorkerContextInstaller workerContextInstaller;
        private final Map<String, WorkerInstance> workers = new HashMap<>();
        private final Map<String, WorkerInstance> retiredWorkers = new HashMap<>();

        EJSWorkerProvider(EJSContext parentContext, WorkerContextInstaller installer) {
            this.parentContext = parentContext;
            this.workerContextInstaller = installer;
        }

        @Override public String getModuleID() { return CONFIGURATION_KEY; }

        @Override
        public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            try {
                byte[] result;
                if ("create".equals(methodID)) {
                    result = create(payload == null ? new byte[0] : payload);
                } else if ("start".equals(methodID)) {
                    result = start(payload == null ? new byte[0] : payload);
                } else if ("postMessage".equals(methodID)) {
                    result = postMessage(payload == null ? new byte[0] : payload, transferBuffer == null ? new byte[0] : transferBuffer);
                } else if ("takeMessage".equals(methodID)) {
                    result = takeMessage(payload == null ? new byte[0] : payload);
                } else if ("terminate".equals(methodID)) {
                    result = terminate(payload == null ? new byte[0] : payload);
                } else {
                    throw new UnsupportedOperationException("Unsupported ejs.worker method: " + methodID);
                }
                responder.finishWithData(result, null);
            } catch (Exception error) {
                responder.finishWithData(null, error);
            }
            return new ImmediateOperation();
        }

        @Override public void close() {
            List<WorkerInstance> instances = new ArrayList<>();
            synchronized (workers) {
                instances.addAll(workers.values());
                instances.addAll(retiredWorkers.values());
                workers.clear();
                retiredWorkers.clear();
            }
            for (WorkerInstance instance : instances) {
                stop(instance);
            }
        }

        private byte[] create(byte[] payload) throws Exception {
            JSONObject request = parseObject(payload);
            String specifier = request.optString("specifier", "");
            JSONObject options = request.optJSONObject("options");
            String requestedName = options == null ? "" : options.optString("name", "");
            String requestedType = options == null ? "classic" : options.optString("type", "classic");
            if (!"classic".equals(requestedType) && !"module".equals(requestedType)) {
                throw new IllegalArgumentException("Worker type must be classic or module");
            }
            WorkerLimits limits = parseLimits(parentContext.configurationValueForKey(CONFIGURATION_KEY));
            synchronized (workers) {
                if (workers.size() >= limits.maxWorkers) {
                    throw new IllegalStateException("Worker limit exceeded");
                }
            }
            WorkerSource source = resolveSource(specifier, requestedName, requestedType, limits);
            String workerID = "worker-" + UUID.randomUUID();
            WorkerInstance instance = new WorkerInstance(workerID, source.name, specifier, source, limits);
            synchronized (workers) {
                workers.put(workerID, instance);
            }
            JSONObject response = new JSONObject();
            response.put("workerID", workerID);
            response.put("name", source.name);
            response.put("maxQueuedMessages", limits.maxQueuedMessages);
            return response.toString().getBytes(StandardCharsets.UTF_8);
        }

        private byte[] start(byte[] payload) throws Exception {
            WorkerInstance instance = getWorker(parseObject(payload).optString("workerID", ""));
            synchronized (instance) {
                if (instance.thread != null) {
                    return new byte[0];
                }
                instance.thread = new Thread(() -> runWorker(instance), "EJSWorker-" + instance.workerID);
                instance.thread.start();
            }
            if (!instance.readyLatch.await(instance.limits.startupTimeoutMs, TimeUnit.MILLISECONDS)) {
                stop(instance);
                throw new IllegalStateException("Worker startup timed out");
            }
            if (instance.startError != null) {
                stop(instance);
                throw instance.startError;
            }
            return new byte[0];
        }

        private void runWorker(WorkerInstance instance) {
            EJSRuntime runtime = null;
            EJSContext childContext = null;
            boolean ready = false;
            try {
                runtime = new EJSRuntime();
                childContext = runtime.createContext(instance.workerID);
                instance.runtime = runtime;
                instance.context = childContext;
                if (workerContextInstaller != null) {
                    workerContextInstaller.install(childContext);
                }
                childContext.registerProvider(new EJSWorkerChildProvider(this, instance));
                childContext.evaluateScript(EJSWorkerScripts.CHILD, "js/worker_child.js");
                JSONObject boot = new JSONObject();
                boot.put("workerID", instance.workerID);
                boot.put("maxQueuedMessages", instance.limits.maxQueuedMessages);
                childContext.evaluateScript("globalThis.__EJSWorkerBootstrap(" + boot.toString() + ");", "ejs_worker_bootstrap.js");
                ready = true;
                instance.readyLatch.countDown();
                if (instance.terminated) {
                    return;
                } else if ("module".equals(instance.source.type)) {
                    childContext.evaluateModule(instance.source.source, instance.source.filename, instance.source.filename);
                } else {
                    childContext.evaluateScript(instance.source.source, instance.source.filename);
                }
                synchronized (instance) {
                    while (!instance.terminated) {
                        instance.wait();
                    }
                }
            } catch (Exception error) {
                instance.startError = error;
                if (!ready) {
                    instance.readyLatch.countDown();
                }
                if (!instance.terminated) {
                    try {
                        enqueueToParent(instance, errorFrame(error));
                    } catch (Exception ignored) {
                    }
                }
            } finally {
                if (!ready) {
                    instance.readyLatch.countDown();
                }
                synchronized (instance) {
                    if (childContext != null) {
                        childContext.invalidate();
                    }
                    if (runtime != null) {
                        runtime.invalidate();
                    }
                    instance.context = null;
                    instance.runtime = null;
                    if (!instance.preserveParentInboxForClose) {
                        instance.parentInbox.clear();
                    }
                    instance.childInbox.clear();
                }
                cleanupRetiredWorker(instance);
            }
        }

        private byte[] postMessage(byte[] payload, byte[] transferBuffer) throws Exception {
            JSONObject request = parseObject(payload);
            WorkerInstance instance = getWorker(request.optString("workerID", ""));
            if (transferBuffer.length > instance.limits.maxMessageBytes) {
                throw new IllegalArgumentException("Worker message exceeds maxMessageBytes");
            }
            String direction = request.optString("direction", "");
            byte[] frame = frame(request.optJSONObject("envelope"), transferBuffer);
            if ("toChild".equals(direction)) {
                String messageID = enqueue(instance.childInbox, instance, frame);
                EJSContext child;
                synchronized (instance) {
                    child = instance.context;
                    if (instance.terminated) {
                        child = null;
                    }
                }
                if (child != null) {
                    dispatchWorkerMessage(child, instance, instance.childInbox, messageID);
                } else {
                    removeQueuedMessage(instance, instance.childInbox, messageID);
                }
            } else if ("toParent".equals(direction)) {
                String messageID = enqueue(instance.parentInbox, instance, frame);
                dispatchWorkerMessage(parentContext, instance, instance.parentInbox, messageID);
            } else {
                throw new IllegalArgumentException("Unsupported worker message direction");
            }
            return new byte[0];
        }

        private byte[] takeMessage(byte[] payload) throws Exception {
            JSONObject request = parseObject(payload);
            WorkerInstance instance = getWorkerForTake(request.optString("workerID", ""));
            String messageID = request.optString("messageID", "");
            String direction = request.optString("direction", "");
            Map<String, byte[]> inbox = "toChild".equals(direction) ? instance.childInbox : instance.parentInbox;
            synchronized (instance) {
                byte[] frame = inbox.remove(messageID);
                if (frame == null) {
                    throw new IllegalArgumentException("Worker message not found");
                }
                cleanupRetiredWorker(instance);
                return frame;
            }
        }

        private byte[] terminate(byte[] payload) throws Exception {
            JSONObject request = parseObject(payload);
            WorkerInstance instance;
            synchronized (workers) {
                instance = workers.remove(request.optString("workerID", ""));
                if (instance == null) {
                    instance = retiredWorkers.remove(request.optString("workerID", ""));
                }
            }
            if (instance != null) {
                stop(instance);
            }
            return new byte[0];
        }

        private WorkerInstance getWorker(String workerID) {
            synchronized (workers) {
                WorkerInstance instance = workers.get(workerID);
                if (instance == null || instance.terminated) {
                    throw new IllegalStateException("Worker is not available");
                }
                return instance;
            }
        }

        private WorkerInstance getWorkerForTake(String workerID) {
            synchronized (workers) {
                WorkerInstance instance = workers.get(workerID);
                if (instance == null) {
                    instance = retiredWorkers.get(workerID);
                }
                if (instance == null) {
                    throw new IllegalStateException("Worker is not available");
                }
                return instance;
            }
        }

        private void cleanupRetiredWorker(WorkerInstance instance) {
            synchronized (instance) {
                if (!instance.terminated || !instance.parentInbox.isEmpty() || !instance.childInbox.isEmpty()) {
                    return;
                }
            }
            synchronized (workers) {
                WorkerInstance retired = retiredWorkers.get(instance.workerID);
                if (retired != instance) {
                    return;
                }
                synchronized (instance) {
                    if (instance.terminated && instance.parentInbox.isEmpty() && instance.childInbox.isEmpty()) {
                        retiredWorkers.remove(instance.workerID);
                    }
                }
            }
        }

        private void stop(WorkerInstance instance) {
            instance.terminated = true;
            EJSRuntime runtime = instance.runtime;
            if (runtime != null) {
                runtime.requestInterrupt();
            }
            synchronized (instance) {
                instance.notifyAll();
            }
            Thread thread = instance.thread;
            if (thread != null && thread != Thread.currentThread()) {
                try {
                    thread.join(instance.limits.terminationTimeoutMs);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
            synchronized (instance) {
                instance.parentInbox.clear();
                instance.childInbox.clear();
            }
        }

        private void enqueueToParent(WorkerInstance instance, byte[] frame) {
            try {
                String messageID = enqueue(instance.parentInbox, instance, frame);
                dispatchWorkerMessage(parentContext, instance, instance.parentInbox, messageID);
            } catch (Exception ignored) {}
        }

        private void dispatchWorkerMessage(EJSContext targetContext, WorkerInstance instance, Map<String, byte[]> inbox, String messageID) {
            String script = "globalThis.__EJSWorkerDispatch(" + quote(instance.workerID) + "," + quote(messageID) + ");";
            targetContext.dispatchScript(script, "ejs_worker_dispatch.js", error -> removeQueuedMessage(instance, inbox, messageID));
        }

        private void removeQueuedMessage(WorkerInstance instance, Map<String, byte[]> inbox, String messageID) {
            synchronized (instance) {
                inbox.remove(messageID);
            }
        }

        private WorkerLimits parseLimits(String config) {
            WorkerLimits limits = new WorkerLimits();
            if (config == null || config.length() == 0) {
                return limits;
            }
            try {
                JSONObject object = new JSONObject(config);
                JSONObject sourcePolicy = object.optJSONObject("sourcePolicy");
                JSONObject limitsObject = object.optJSONObject("limits");
                if (limitsObject == null && sourcePolicy != null) {
                    limitsObject = sourcePolicy.optJSONObject("limits");
                }
                if (limitsObject != null) {
                    limits.maxWorkers = positive(limitsObject, "maxWorkers", limits.maxWorkers);
                    limits.maxQueuedMessages = positive(limitsObject, "maxQueuedMessages", limits.maxQueuedMessages);
                    limits.maxMessageBytes = positive(limitsObject, "maxMessageBytes", limits.maxMessageBytes);
                    limits.maxSourceBytes = positive(limitsObject, "maxSourceBytes", limits.maxSourceBytes);
                    limits.startupTimeoutMs = positive(limitsObject, "startupTimeoutMs", limits.startupTimeoutMs);
                    limits.terminationTimeoutMs = positive(limitsObject, "terminationTimeoutMs", limits.terminationTimeoutMs);
                }
            } catch (Exception ignored) {}
            return limits;
        }

        private WorkerSource resolveSource(String specifier, String requestedName, String requestedType, WorkerLimits limits) throws Exception {
            JSONObject config = parentContext.configurationValueForKey(CONFIGURATION_KEY) == null ? new JSONObject() : new JSONObject(parentContext.configurationValueForKey(CONFIGURATION_KEY));
            JSONObject policy = config.optJSONObject("sourcePolicy");
            if (policy == null) {
                policy = config;
            }
            WorkerSource source = resolveInline(policy.opt("inlineScripts"), specifier, requestedType);
            if (source == null) {
                source = resolveFile(policy, specifier, requestedType);
            }
            if (source == null) {
                throw new IllegalArgumentException("Worker source is not allowed: " + specifier);
            }
            if (source.source.getBytes(StandardCharsets.UTF_8).length > limits.maxSourceBytes) {
                throw new IllegalArgumentException("Worker source exceeds maxSourceBytes");
            }
            if (requestedName != null && requestedName.length() > 0) {
                source.name = requestedName;
            }
            return source;
        }

        private WorkerSource resolveInline(Object inlineScripts, String specifier, String requestedType) throws Exception {
            if (inlineScripts instanceof JSONObject) {
                JSONObject object = ((JSONObject) inlineScripts).optJSONObject(specifier);
                if (object != null) return sourceFromInline(specifier, object, requestedType);
            } else if (inlineScripts instanceof JSONArray) {
                JSONArray array = (JSONArray) inlineScripts;
                for (int i = 0; i < array.length(); i++) {
                    JSONObject item = array.optJSONObject(i);
                    if (item != null && specifier.equals(item.optString("name", item.optString("specifier", "")))) {
                        return sourceFromInline(specifier, item, requestedType);
                    }
                }
            }
            return null;
        }

        private WorkerSource sourceFromInline(String specifier, JSONObject object, String requestedType) {
            WorkerSource source = new WorkerSource();
            source.name = object.optString("name", specifier);
            source.source = object.optString("source", "");
            source.type = object.optString("type", requestedType);
            source.filename = source.name.length() == 0 ? specifier : source.name;
            return source;
        }

        private WorkerSource resolveFile(JSONObject policy, String specifier, String requestedType) throws Exception {
            JSONObject scripts = policy.optJSONObject("scripts");
            JSONObject script = scripts == null ? null : scripts.optJSONObject(specifier);
            String path = script == null ? specifier : script.optString("path", specifier);
            String type = script == null ? requestedType : script.optString("type", requestedType);
            String defaultRoot = policy.optString("defaultRoot", "");
            String root = script == null ? defaultRoot : script.optString("root", defaultRoot);
            File file = new File(path);
            File canonicalRoot = null;
            if (root.length() > 0) {
                canonicalRoot = new File(root).getCanonicalFile();
            }
            if (!file.isAbsolute()) {
                if (root.length() == 0) return null;
                file = new File(canonicalRoot, path);
            } else if (!policy.optBoolean("allowAbsolutePath", false)) {
                return null;
            }
            File canonicalFile = file.getCanonicalFile();
            if (canonicalRoot != null && !isUnderRoot(canonicalRoot, canonicalFile)) {
                return null;
            }
            byte[] bytes = readFile(canonicalFile);
            WorkerSource source = new WorkerSource();
            source.name = script == null ? specifier : script.optString("name", specifier);
            source.source = new String(bytes, StandardCharsets.UTF_8);
            source.type = type;
            source.filename = canonicalFile.getPath();
            return source;
        }

        private boolean isUnderRoot(File root, File target) {
            String rootPath = root.getPath();
            String targetPath = target.getPath();
            return targetPath.equals(rootPath) || targetPath.startsWith(rootPath + File.separator);
        }
    }

    private static final class EJSWorkerChildProvider implements EJSProvider {
        private final EJSWorkerProvider parent;
        private final WorkerInstance instance;

        EJSWorkerChildProvider(EJSWorkerProvider parent, WorkerInstance instance) {
            this.parent = parent;
            this.instance = instance;
        }

        @Override public String getModuleID() { return CONFIGURATION_KEY; }

        @Override
        public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            try {
                byte[] result;
                if ("postMessage".equals(methodID)) {
                    JSONObject request = parseObject(payload == null ? new byte[0] : payload);
                    byte[] frame = frame(request.optJSONObject("envelope"), transferBuffer == null ? new byte[0] : transferBuffer);
                    String messageID = enqueue(instance.parentInbox, instance, frame);
                    parent.dispatchWorkerMessage(parent.parentContext, instance, instance.parentInbox, messageID);
                    result = new byte[0];
                } else if ("takeMessage".equals(methodID)) {
                    JSONObject request = parseObject(payload == null ? new byte[0] : payload);
                    result = takeFrom(instance.childInbox, instance, request.optString("messageID", ""));
                } else if ("close".equals(methodID)) {
                    result = closeFromChild();
                } else if ("reportError".equals(methodID)) {
                    JSONObject error = parseObject(payload == null ? new byte[0] : payload);
                    result = reportError(error);
                } else {
                    throw new UnsupportedOperationException("Unsupported child ejs.worker method: " + methodID);
                }
                responder.finishWithData(result, null);
            } catch (Exception error) {
                responder.finishWithData(null, error);
            }
            return new ImmediateOperation();
        }

        private byte[] closeFromChild() throws Exception {
            byte[] frame = frame(new JSONObject().put("kind", "close"), new byte[0]);
            String messageID = enqueue(instance.parentInbox, instance, frame);
            instance.preserveParentInboxForClose = true;
            instance.terminated = true;
            synchronized (parent.workers) {
                parent.workers.remove(instance.workerID);
                parent.retiredWorkers.put(instance.workerID, instance);
            }
            parent.dispatchWorkerMessage(parent.parentContext, instance, instance.parentInbox, messageID);
            EJSRuntime runtime = instance.runtime;
            if (runtime != null) {
                runtime.requestInterrupt();
            }
            synchronized (instance) {
                instance.notifyAll();
            }
            return new byte[0];
        }

        private byte[] reportError(JSONObject error) throws Exception {
            byte[] frame = frame(new JSONObject().put("kind", "error").put("error", error), new byte[0]);
            String messageID = enqueue(instance.parentInbox, instance, frame);
            parent.dispatchWorkerMessage(parent.parentContext, instance, instance.parentInbox, messageID);
            return new byte[0];
        }
    }

    private static JSONObject parseObject(byte[] payload) throws Exception {
        if (payload == null || payload.length == 0) return new JSONObject();
        return new JSONObject(new String(payload, StandardCharsets.UTF_8));
    }

    private static int positive(JSONObject object, String key, int fallback) {
        int value = object.optInt(key, fallback);
        return value > 0 ? value : fallback;
    }

    private static String enqueue(Map<String, byte[]> inbox, WorkerInstance instance, byte[] frame) {
        synchronized (instance) {
            if (inbox.size() >= instance.limits.maxQueuedMessages) {
                throw new IllegalStateException("Worker native inbox exceeds maxQueuedMessages");
            }
            String messageID = Long.toString(instance.nextMessageID++);
            inbox.put(messageID, frame);
            return messageID;
        }
    }

    private static byte[] takeFrom(Map<String, byte[]> inbox, WorkerInstance instance, String messageID) {
        synchronized (instance) {
            byte[] frame = inbox.remove(messageID);
            if (frame == null) throw new IllegalArgumentException("Worker message not found");
            return frame;
        }
    }

    private static byte[] frame(JSONObject envelope, byte[] sidecar) throws Exception {
        JSONObject header = new JSONObject();
        header.put("envelope", envelope == null ? new JSONObject() : envelope);
        byte[] headerBytes = header.toString().getBytes(StandardCharsets.UTF_8);
        byte[] body = sidecar == null ? new byte[0] : sidecar;
        ByteArrayOutputStream out = new ByteArrayOutputStream(4 + headerBytes.length + body.length);
        int len = headerBytes.length;
        out.write(len & 0xff);
        out.write((len >>> 8) & 0xff);
        out.write((len >>> 16) & 0xff);
        out.write((len >>> 24) & 0xff);
        out.write(headerBytes);
        out.write(body);
        return out.toByteArray();
    }

    private static byte[] errorFrame(Exception error) throws Exception {
        JSONObject wrapped = new JSONObject();
        wrapped.put("kind", "error");
        wrapped.put("error", new JSONObject().put("message", error.getMessage() == null ? error.toString() : error.getMessage()).put("stack", error.toString()).put("filename", ""));
        return frame(wrapped, new byte[0]);
    }

    private static String quote(String value) {
        return JSONObject.quote(value == null ? "" : value);
    }

    private static byte[] readFile(File file) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        try (FileInputStream input = new FileInputStream(file)) {
            int count;
            while ((count = input.read(buffer)) >= 0) {
                out.write(buffer, 0, count);
            }
        }
        return out.toByteArray();
    }
}
