package com.ejs.modules.net;

import com.ejs.platform.EJSContext;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public final class EJSNet {
    public static final String NETWORK_CONFIGURATION_KEY = "ejs.network";
    private EJSNet() {}

    public static void installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("Context is required");
        context.registerProvider(new EJSNetProvider(context.configurationValueForKey(NETWORK_CONFIGURATION_KEY)));
        context.evaluateScript(readResource("/ejs/modules/net/net.js"), "js/net.js");
    }

    private static String readResource(String name) throws Exception {
        InputStream input = EJSNet.class.getResourceAsStream(name);
        if (input == null) throw new IllegalStateException("Missing bundled EJS net script: " + name);
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
