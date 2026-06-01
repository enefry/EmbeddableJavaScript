#import "EJSIPAddrApple.h"

#include "ejs_ipaddr_js_bundle.h"

static NSError *EJSIPAddrRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static BOOL EJSIPAddrInstallBundledScriptsIntoContext(EJSContext *context,
                                                      const EJSIPAddrBundledScript *scripts,
                                                      size_t scriptCount,
                                                      NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSIPAddrRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSIPAddrBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSIPAddrRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                               @"EJSIPAddr bundled script must be valid UTF-8");
            }
            return NO;
        }

        if (![context evaluateScript:source filename:filename error:error]) {
            return NO;
        }
    }

    return YES;
}

BOOL EJSIPAddrInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSIPAddrInstallBundledScriptsIntoContext(context, ejs_ipaddr_scripts, ejs_ipaddr_scripts_count, error);
}

#ifdef EJS_TEST
BOOL EJSIPAddrInstallBundledScriptForTesting(EJSContext *context,
                                             const char *name,
                                             const unsigned char *code,
                                             size_t length,
                                             NSError **error) {
    EJSIPAddrBundledScript script = {
        .name = name,
        .code = code,
        .len = length
    };
    return EJSIPAddrInstallBundledScriptsIntoContext(context, &script, 1u, error);
}
#endif
