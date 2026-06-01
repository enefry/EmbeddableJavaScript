package com.ejs.platform;

import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public class EJSRuntime {
    private volatile long nativePtr;
    private final ExecutorService ownerExecutor;
    private volatile Thread ownerThread;
    private volatile boolean invalidated;

    static {
        System.loadLibrary("ejs_android_platform");
    }

    public EJSRuntime() {
        this(null);
    }

    public EJSRuntime(EJSRuntimeConfiguration configuration) {
        ownerExecutor = Executors.newSingleThreadExecutor(r -> {
            Thread thread = new Thread(r, "ejs-runtime-owner");
            thread.setDaemon(true);
            return thread;
        });
        long createdPtr;
        try {
            createdPtr = callOnOwner(() -> nativeCreate(configuration));
        } catch (Exception error) {
            ownerExecutor.shutdown();
            throw new IllegalStateException("Failed to create EJS runtime", error);
        }
        if (createdPtr == 0) {
            ownerExecutor.shutdown();
            throw new IllegalStateException("Failed to create EJS runtime");
        }
        nativePtr = createdPtr;
    }

    public EJSContext createContext(String contextID) throws Exception {
        return createContext(contextID, null);
    }

    public EJSContext createContext(String contextID, EJSContextConfiguration configuration) throws Exception {
        return callOnOwner(() -> nativeCreateContext(nativePtr, contextID, configuration));
    }

    public native void requestInterrupt();
    
    public synchronized void invalidate() {
        if (nativePtr != 0) {
            invalidated = true;
            try {
                requestInterrupt();
                runOnOwner(this::nativeInvalidate);
            } catch (RuntimeException runtimeError) {
                throw runtimeError;
            } catch (Exception error) {
                throw new IllegalStateException("Failed to invalidate EJS runtime", error);
            } finally {
                nativePtr = 0;
                ownerExecutor.shutdown();
            }
        }
    }

    boolean isInvalidated() {
        return invalidated || nativePtr == 0;
    }

    <T> T callOnOwner(Callable<T> task) throws Exception {
        if (Thread.currentThread() == ownerThread) {
            return task.call();
        }
        Future<T> future = ownerExecutor.submit(() -> {
            ownerThread = Thread.currentThread();
            return task.call();
        });
        try {
            return future.get();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw interrupted;
        } catch (ExecutionException wrapped) {
            Throwable cause = wrapped.getCause();
            if (cause instanceof Exception) {
                throw (Exception) cause;
            }
            if (cause instanceof Error) {
                throw (Error) cause;
            }
            throw new IllegalStateException(cause);
        }
    }

    void runOnOwner(OwnerRunnable task) throws Exception {
        callOnOwner(() -> {
            task.run();
            return null;
        });
    }

    void dispatchOnOwner(OwnerRunnable task, OwnerErrorHandler errorHandler) {
        if (task == null) {
            if (errorHandler != null) {
                errorHandler.onError(new IllegalArgumentException("Owner task is required"));
            }
            return;
        }
        if (isInvalidated()) {
            if (errorHandler != null) {
                errorHandler.onError(new IllegalStateException("EJS runtime is invalidated"));
            }
            return;
        }
        try {
            ownerExecutor.execute(() -> {
                ownerThread = Thread.currentThread();
                try {
                    if (isInvalidated()) {
                        if (errorHandler != null) {
                            errorHandler.onError(new IllegalStateException("EJS runtime is invalidated"));
                        }
                        return;
                    }
                    task.run();
                } catch (Exception error) {
                    if (errorHandler != null) {
                        errorHandler.onError(error);
                    }
                }
            });
        } catch (RuntimeException error) {
            if (errorHandler != null) {
                errorHandler.onError(error);
            } else {
                throw error;
            }
        }
    }

    interface OwnerRunnable {
        void run() throws Exception;
    }

    interface OwnerErrorHandler {
        void onError(Exception error);
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

    private native long nativeCreate(EJSRuntimeConfiguration config);
    private native EJSContext nativeCreateContext(long nativePtr, String contextID, EJSContextConfiguration config) throws Exception;
}
