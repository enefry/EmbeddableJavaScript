#import "EJSBufferApple.h"

#include "ejs_buffer_js_bundle.h"

static NSError * EJSBufferRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static BOOL EJSBufferInstallBundledScriptsIntoContext(EJSContext *context,
                                                      const EJSBufferBundledScript *scripts,
                                                      size_t scriptCount,
                                                      NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSBufferRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSBufferBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSBufferRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                               @"EJSBinary bundled script must be valid UTF-8");
            }
            return NO;
        }

        if (![context evaluateScript:source filename:filename error:error]) {
            return NO;
        }
    }

    return YES;
}

BOOL EJSBufferInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSBufferInstallBundledScriptsIntoContext(context, ejs_buffer_scripts, ejs_buffer_scripts_count, error);
}

#ifdef EJS_TEST
BOOL EJSBufferInstallBundledScriptForTesting(EJSContext *context,
                                             const char *name,
                                             const unsigned char *code,
                                             size_t length,
                                             NSError **error) {
    EJSBufferBundledScript script = {
        .name = name,
        .code = code,
        .len = length
    };
    return EJSBufferInstallBundledScriptsIntoContext(context, &script, 1u, error);
}
#endif
