package com.ejs.modules.ws;

import com.ejs.platform.EJSContext;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public final class EJSWebSocket {
    private static final String NETWORK_CONFIGURATION_KEY = "ejs.network";
    private EJSWebSocket() {}

    public static void installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("Context is required");
        context.registerProvider(new EJSWebSocketProvider(context.configurationValueForKey(NETWORK_CONFIGURATION_KEY)));
        context.evaluateScript(readResource("/ejs/modules/ws/ws.js"), "js/ws.js");
    }

    private static String readResource(String name) throws Exception {
        InputStream input = EJSWebSocket.class.getResourceAsStream(name);
        if (input == null) throw new IllegalStateException("Missing bundled EJS WebSocket script: " + name);
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int read; while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
