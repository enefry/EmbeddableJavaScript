#import "EJSUUIDApple.h"

#import "EJSProvider.h"

#import "../../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_uuid_js_bundle.h"

#ifdef EJS_TEST
typedef NS_ENUM(NSInteger, EJSUUIDInstallFailureModeForTestingInternal) {
    EJSUUIDInstallFailureModeNoneForTestingInternal = 0,
    EJSUUIDInstallFailureModeBeginForTestingInternal = 1,
    EJSUUIDInstallFailureModeRegisterProviderForTestingInternal = 2,
    EJSUUIDInstallFailureModeCommitForTestingInternal = 3
};

static NSInteger EJSUUIDInstallFailureModeForTestingValue = EJSUUIDInstallFailureModeNoneForTestingInternal;
#endif

static NSError * EJSUUIDRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSUUIDProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"UUID provider failed");
}

@interface EJSUUIDProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@implementation EJSUUIDProvider

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.uuid";
    }
    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)payload;
    (void)transferBuffer;
    (void)context;

    if (![methodID isEqualToString:@"v4"]) {
        [responder finishWithData:nil error:EJSUUIDProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.uuid method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *uuid = NSUUID.UUID.UUIDString.lowercaseString;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"uuid": uuid } options:0 error:&error];
    [responder finishWithData:data error:error];
    return [[EJSImmediateOperation alloc] init];
}

@end

static NSInteger EJSUUIDConsumeInstallFailureModeForTesting(void) {
#ifdef EJS_TEST
    NSInteger mode = EJSUUIDInstallFailureModeForTestingValue;
    EJSUUIDInstallFailureModeForTestingValue = EJSUUIDInstallFailureModeNoneForTestingInternal;
    return mode;
#else
    return 0;
#endif
}

#ifdef EJS_TEST
void EJSUUIDSetInstallFailureModeForTesting(NSInteger mode) {
    EJSUUIDInstallFailureModeForTestingValue = mode;
}
#endif

static BOOL EJSUUIDInstallBundledScriptsIntoContext(EJSContext *context,
                                                    const EJSUUIDBundledScript *scripts,
                                                    size_t scriptCount,
                                                    NSError **error) {
    if (context == nil) {
        if (error != NULL) *error = EJSUUIDRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        return NO;
    }
    NSInteger failureMode = EJSUUIDConsumeInstallFailureModeForTesting();
    EJSAppleInstallTransaction transaction;
    EJSAppleInstallTransaction *transactionRef = &transaction;
#ifdef EJS_TEST
    if (failureMode == EJSUUIDInstallFailureModeBeginForTestingInternal) {
        transactionRef = NULL;
    }
#else
    (void)failureMode;
#endif
    if (!EJSAppleInstallTransactionBegin(transactionRef, context, @[ @"EJSUUID" ], error)) {
        return NO;
    }
    id<EJSProvider> provider = [[EJSUUIDProvider alloc] init];
#ifdef EJS_TEST
    if (failureMode == EJSUUIDInstallFailureModeRegisterProviderForTestingInternal) {
        provider = nil;
    }
#endif
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, provider, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSUUIDBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) *error = EJSUUIDRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"EJSUUID bundled script must be valid UTF-8");
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
        if (![context evaluateScript:source filename:filename error:error]) {
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
    }
#ifdef EJS_TEST
    if (failureMode == EJSUUIDInstallFailureModeCommitForTestingInternal) {
        transaction.context = nil;
    }
#endif
    if (!EJSAppleInstallTransactionCommit(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
    return YES;
}

BOOL EJSUUIDInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSUUIDInstallBundledScriptsIntoContext(context, ejs_uuid_scripts, ejs_uuid_scripts_count, error);
}

#ifdef EJS_TEST
BOOL EJSUUIDInstallBundledScriptForTesting(EJSContext *context,
                                           const char *name,
                                           const unsigned char *code,
                                           size_t length,
                                           NSError **error) {
    EJSUUIDBundledScript script = {
        .name = name,
        .code = code,
        .len = length
    };
    return EJSUUIDInstallBundledScriptsIntoContext(context, &script, 1u, error);
}
#endif
