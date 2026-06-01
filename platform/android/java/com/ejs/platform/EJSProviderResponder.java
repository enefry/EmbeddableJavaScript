package com.ejs.platform;

public class EJSProviderResponder {
    private long nativePtr;

    public EJSProviderResponder(long nativePtr) {
        this.nativePtr = nativePtr;
    }

    public synchronized boolean finishWithData(byte[] resultData, Exception error) {
        if (nativePtr != 0) {
            boolean res = nativeFinishWithData(resultData, error);
            nativePtr = 0;
            return res;
        }
        return false;
    }

    @Override
    protected void finalize() throws Throwable {
        try {
            synchronized (this) {
                if (nativePtr != 0) {
                    nativeDestroy(nativePtr);
                    nativePtr = 0;
                }
            }
        } finally {
            super.finalize();
        }
    }

    private native boolean nativeFinishWithData(byte[] resultData, Exception error);
    private static native void nativeDestroy(long nativePtr);
}
