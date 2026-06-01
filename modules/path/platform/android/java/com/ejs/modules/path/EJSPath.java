package com.ejs.modules.path;

import com.ejs.platform.EJSContext;

public final class EJSPath {
    private EJSPath() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("Context is required");
        }
        for (EJSPathBundle.Script script : EJSPathBundle.SCRIPTS) {
            if (!context.evaluateScript(script.source, script.name)) {
                throw new IllegalStateException("Failed to evaluate " + script.name);
            }
        }
        return true;
    }
}
