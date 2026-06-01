package com.ejs.modules.fswatch;

import com.ejs.platform.EJSContext;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public final class EJSFSWatch {
    public static final String CONFIGURATION_KEY = "ejs.fswatch";
    private EJSFSWatch() {}

    public static void installIntoContext(EJSContext context) throws Exception {
        if (context == null) throw new IllegalArgumentException("Context is required");
        context.registerProvider(new EJSFSWatchProvider(context, context.configurationValueForKey(CONFIGURATION_KEY)));
        context.evaluateScript(readResource("/ejs/modules/fswatch/fswatch.js"), "js/fswatch.js");
    }

    private static String readResource(String name) throws Exception {
        InputStream input = EJSFSWatch.class.getResourceAsStream(name);
        if (input == null) throw new IllegalStateException("Missing bundled EJS fswatch script: " + name);
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192]; int read; while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
