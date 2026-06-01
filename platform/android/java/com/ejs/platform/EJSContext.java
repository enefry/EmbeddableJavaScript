package com.ejs.platform;

public class EJSContext {
    private volatile long nativePtr;
    private final EJSRuntime runtime;
    private final String contextID;

    private EJSContext(long nativePtr, EJSRuntime runtime, String contextID) {
        this.nativePtr = nativePtr;
        this.runtime = runtime;
        this.contextID = contextID;
    }

    public EJSRuntime getRuntime() { return runtime; }
    public String getContextID() { return contextID; }

    public boolean evaluateScript(String source, String filename) throws Exception {
        return runtime.callOnOwner(() -> nativeEvaluateScript(source, filename));
    }

    public void dispatchScript(String source, String filename) {
        dispatchScript(source, filename, null);
    }

    public void dispatchScript(String source, String filename, DispatchErrorHandler errorHandler) {
        if (source == null || filename == null) {
            throw new IllegalArgumentException("Source and filename are required");
        }
        runtime.dispatchOnOwner(() -> {
            if (!nativeEvaluateScript(source, filename) && errorHandler != null) {
                errorHandler.onError(new IllegalStateException("EJS context is invalidated"));
            }
        }, errorHandler == null ? null : errorHandler::onError);
    }

    public boolean evaluateModule(String source, String specifier, String sourceURL) throws Exception {
        return runtime.callOnOwner(() -> nativeEvaluateModule(source, specifier, sourceURL));
    }

    public boolean registerProvider(EJSProvider provider) throws Exception {
        return runtime.callOnOwner(() -> nativeRegisterProvider(provider));
    }

    public void unregisterProviderForModuleID(String moduleID) {
        runUnchecked(() -> nativeUnregisterProviderForModuleID(moduleID));
    }

    public void unregisterAllProviders() {
        runUnchecked(this::nativeUnregisterAllProviders);
    }

    public String configurationValueForKey(String key) {
        try {
            return runtime.callOnOwner(() -> nativeConfigurationValueForKey(key));
        } catch (RuntimeException runtimeError) {
            throw runtimeError;
        } catch (Exception error) {
            throw new IllegalStateException("Failed to read EJS context configuration", error);
        }
    }
    
    public synchronized void invalidate() {
        if (nativePtr != 0) {
            if (runtime == null || runtime.isInvalidated()) {
                nativePtr = 0;
                return;
            }
            runtime.requestInterrupt();
            runUnchecked(this::nativeInvalidate);
            nativePtr = 0;
        }
    }

    private void runUnchecked(EJSRuntime.OwnerRunnable task) {
        try {
            runtime.runOnOwner(task);
        } catch (RuntimeException runtimeError) {
            throw runtimeError;
        } catch (Exception error) {
            throw new IllegalStateException("Failed to run EJS context operation", error);
        }
    }

    @Override
    protected void finalize() throws Throwable {
        try {
            invalidate();
        } finally {
            super.finalize();
        }
    }

    private native void nativeInvalidate();
    private native boolean nativeEvaluateScript(String source, String filename) throws Exception;
    private native boolean nativeEvaluateModule(String source, String specifier, String sourceURL) throws Exception;
    private native boolean nativeRegisterProvider(EJSProvider provider) throws Exception;
    private native void nativeUnregisterProviderForModuleID(String moduleID);
    private native void nativeUnregisterAllProviders();
    private native String nativeConfigurationValueForKey(String key);

    public interface DispatchErrorHandler {
        void onError(Exception error);
    }
}
