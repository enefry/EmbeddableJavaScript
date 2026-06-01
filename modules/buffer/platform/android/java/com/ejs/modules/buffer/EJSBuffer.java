package com.ejs.modules.buffer;

import com.ejs.platform.EJSContext;

public final class EJSBuffer {
    private EJSBuffer() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("Context is required");
        }
        for (EJSBufferBundle.Script script : EJSBufferBundle.SCRIPTS) {
            if (!context.evaluateScript(script.source, script.name)) {
                throw new IllegalStateException("Failed to evaluate " + script.name);
            }
        }
        return true;
    }
}
