#import "EJSPathApple.h"

#include "ejs_path_js_bundle.h"

static NSError * EJSPathRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static BOOL EJSPathInstallBundledScriptsIntoContext(EJSContext *context,
                                                    const EJSPathBundledScript *scripts,
                                                    size_t scriptCount,
                                                    NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSPathRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSPathBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSPathRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                             @"EJSPath bundled script must be valid UTF-8");
            }
            return NO;
        }

        if (![context evaluateScript:source filename:filename error:error]) {
            return NO;
        }
    }

    return YES;
}

BOOL EJSPathInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSPathInstallBundledScriptsIntoContext(context, ejs_path_scripts, ejs_path_scripts_count, error);
}

#ifdef EJS_TEST
BOOL EJSPathInstallBundledScriptForTesting(EJSContext *context,
                                           const char *name,
                                           const unsigned char *code,
                                           size_t length,
                                           NSError **error) {
    EJSPathBundledScript script = {
        .name = name,
        .code = code,
        .len = length
    };
    return EJSPathInstallBundledScriptsIntoContext(context, &script, 1u, error);
}
#endif
