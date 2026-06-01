package com.ejs.modules.stdlib.ipaddr;

import com.ejs.platform.EJSContext;

public final class EJSIPAddr {
    private EJSIPAddr() {}

    public static boolean installIntoContext(EJSContext context) throws Exception {
        if (context == null) {
            throw new IllegalArgumentException("Context is required");
        }
        for (EJSIPAddrBundle.Script script : EJSIPAddrBundle.SCRIPTS) {
            if (!context.evaluateScript(script.source, script.name)) {
                throw new IllegalStateException("Failed to evaluate " + script.name);
            }
        }
        return true;
    }
}
