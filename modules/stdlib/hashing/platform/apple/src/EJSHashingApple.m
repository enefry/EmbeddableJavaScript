#import "EJSHashingApple.h"

#import "EJSProvider.h"

#import "../../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_hashing_js_bundle.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>

static NSError * EJSHashingRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSHashingProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"Hashing provider failed");
}

static NSDictionary * EJSHashingJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) *error = EJSHashingProviderError(EJSProviderErrorCodeInvalidArgument, @"hash payload is required");
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) *error = EJSHashingProviderError(EJSProviderErrorCodeInvalidArgument, @"hash payload must be a JSON object");
        return nil;
    }
    return (NSDictionary *)value;
}

static NSString * EJSHashingHexString(const unsigned char *bytes, NSUInteger length) {
    NSMutableString *result = [[NSMutableString alloc] initWithCapacity:length * 2u];
    for (NSUInteger i = 0u; i < length; ++i) {
        [result appendFormat:@"%02x", bytes[i]];
    }
    return result;
}

@interface EJSHashingProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@implementation EJSHashingProvider

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.hashing";
    }
    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;
    if (![methodID isEqualToString:@"digest"]) {
        [responder finishWithData:nil error:EJSHashingProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.hashing method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *error = nil;
    NSDictionary *request = EJSHashingJSONObjectFromData(payload, &error);
    if (request == nil) {
        [responder finishWithData:nil error:error];
        return [[EJSImmediateOperation alloc] init];
    }
    if (transferBuffer == nil) {
        [responder finishWithData:nil error:EJSHashingProviderError(EJSProviderErrorCodeInvalidArgument, @"digest requires a transfer buffer")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *algorithm = [request[@"algorithm"] isKindOfClass:[NSString class]] ? request[@"algorithm"] : @"";
    NSString *encoding = [request[@"encoding"] isKindOfClass:[NSString class]] ? request[@"encoding"] : @"hex";
    unsigned char digest[CC_SHA512_DIGEST_LENGTH] = { 0 };
    NSUInteger digestLength = 0u;
    if (transferBuffer.length > UINT32_MAX) {
        [responder finishWithData:nil error:EJSHashingProviderError(EJSProviderErrorCodeInvalidArgument, @"digest payload length exceeds CommonCrypto one-shot limit")];
        return [[EJSImmediateOperation alloc] init];
    }
    if ([algorithm isEqualToString:@"sha256"]) {
        CC_SHA256(transferBuffer.bytes, (CC_LONG)transferBuffer.length, digest);
        digestLength = CC_SHA256_DIGEST_LENGTH;
    } else if ([algorithm isEqualToString:@"sha512"]) {
        CC_SHA512(transferBuffer.bytes, (CC_LONG)transferBuffer.length, digest);
        digestLength = CC_SHA512_DIGEST_LENGTH;
    } else {
        [responder finishWithData:nil error:EJSHashingProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported hash algorithm")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSData *digestData = [NSData dataWithBytes:digest length:digestLength];
    NSString *digestString = nil;
    if ([encoding isEqualToString:@"base64"]) {
        digestString = [digestData base64EncodedStringWithOptions:0];
    } else if ([encoding isEqualToString:@"hex"]) {
        digestString = EJSHashingHexString(digest, digestLength);
    } else {
        [responder finishWithData:nil error:EJSHashingProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported hash encoding")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSData *result = [NSJSONSerialization dataWithJSONObject:@{ @"digest": digestString ?: @"" } options:0 error:&error];
    [responder finishWithData:result error:error];
    return [[EJSImmediateOperation alloc] init];
}

@end

BOOL EJSHashingInstallIntoContext(EJSContext *context, NSError **error) {
    if (context == nil) {
        if (error != NULL) *error = EJSHashingRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        return NO;
    }
    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSHashing" ], error)) {
        return NO;
    }
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, [[EJSHashingProvider alloc] init], error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
    for (size_t i = 0u; i < ejs_hashing_scripts_count; ++i) {
        const EJSHashingBundledScript *script = &ejs_hashing_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) *error = EJSHashingRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"EJSHashing bundled script must be valid UTF-8");
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
        if (![context evaluateScript:source filename:filename error:error]) {
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
    }
    if (!EJSAppleInstallTransactionCommit(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
    return YES;
}
