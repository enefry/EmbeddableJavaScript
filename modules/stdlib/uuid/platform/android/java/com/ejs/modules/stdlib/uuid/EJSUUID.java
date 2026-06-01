package com.ejs.modules.stdlib.uuid;

import com.ejs.platform.EJSContext;
import com.ejs.platform.EJSProvider;
import com.ejs.platform.EJSProviderOperation;
import com.ejs.platform.EJSProviderResponder;

import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.UUID;

public final class EJSUUID {
    private EJSUUID() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("Context is required");
        }
        for (EJSUUIDBundle.Script script : EJSUUIDBundle.SCRIPTS) {
            if (!context.evaluateScript(script.source, script.name)) {
                throw new IllegalStateException("Failed to evaluate " + script.name);
            }
        }
        if (!context.registerProvider(new UUIDProvider())) {
            throw new IllegalStateException("Failed to register ejs.uuid provider");
        }
        return true;
    }

    private static final class UUIDProvider implements EJSProvider {
        static final String MODULE_ID = "ejs.uuid";
        private static final EJSProviderOperation IMMEDIATE_OPERATION = new EJSProviderOperation() {
            @Override
            public void cancel() {}
        };

        @Override
        public String getModuleID() {
            return MODULE_ID;
        }

        @Override
        public EJSProviderOperation invokeMethod(String methodID, byte[] payload, byte[] transferBuffer, EJSContext context, EJSProviderResponder responder) {
            if (!"v4".equals(methodID)) {
                responder.finishWithData(null, new UnsupportedOperationException("Unsupported ejs.uuid method"));
                return IMMEDIATE_OPERATION;
            }
            String uuid = UUID.randomUUID().toString().toLowerCase(Locale.ROOT);
            byte[] result = ("{\"uuid\":\"" + uuid + "\"}").getBytes(StandardCharsets.UTF_8);
            responder.finishWithData(result, null);
            return IMMEDIATE_OPERATION;
        }
    }
}
