package com.ejs.platform;

public interface EJSProvider {
    String getModuleID();

    EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) throws Exception;

    default byte[] invokeSyncMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context) throws Exception {
        throw new UnsupportedOperationException("Synchronous invoke not supported");
    }

    default void close() throws Exception {
    }
}
