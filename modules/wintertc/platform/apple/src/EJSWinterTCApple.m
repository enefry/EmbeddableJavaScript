#import "EJSWinterTCApple.h"

#import <CommonCrypto/CommonDigest.h>
#import <mach/mach_time.h>
#import <Security/Security.h>

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_wintertc_js_bundle.h"

@interface EJSWinterTCClockProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@interface EJSWinterTCCryptoProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@interface EJSWinterTCConsoleProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@interface EJSWinterTCFetchStreamState : NSObject
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, strong) NSMutableArray<NSData *> *chunks;
@property (nonatomic, assign) NSUInteger headChunkIndex;
@property (nonatomic, assign) NSUInteger headChunkOffset;
@property (nonatomic, assign) NSUInteger bufferedBytes;
@property (nonatomic, assign) BOOL completed;
@property (nonatomic, strong, nullable) NSError *terminalError;
@property (nonatomic, strong, nullable) EJSProviderResponder *startResponder;
@property (nonatomic, copy, nullable) NSString *signalID;
@property (nonatomic, copy) NSString *streamID;
@property (nonatomic, copy) NSString *requestURLString;
@end

@interface EJSWinterTCFetchProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@interface EJSWinterTCFetchProvider ()
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler;
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data;
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error;
@end

@interface EJSWinterTCFetchSessionDelegate : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, weak, nullable) EJSWinterTCFetchProvider *provider;
@end

@implementation EJSWinterTCInstallOptions

- (id)copyWithZone:(NSZone *)zone {
    EJSWinterTCInstallOptions *copy = [[[self class] allocWithZone:zone] init];

    copy.installDefaultProviders = self.installDefaultProviders;
    return copy;
}

@end

#ifdef EJS_TEST
static const char *g_ejs_wintertc_apple_test_init_source = NULL;
static NSInteger g_ejs_wintertc_apple_test_fail_script_index = -1;
static NSInteger g_ejs_wintertc_apple_test_fail_provider_index = -1;
static NSUInteger g_ejs_wintertc_apple_test_fetch_max_buffered_bytes = 1024u * 1024u;

void EJSWinterTCAppleTestSetInitSource(const char *source) {
    g_ejs_wintertc_apple_test_init_source = source;
}

void EJSWinterTCAppleTestSetInstallFailScriptIndex(NSInteger index) {
    g_ejs_wintertc_apple_test_fail_script_index = index;
}

void EJSWinterTCAppleTestSetInstallFailProviderIndex(NSInteger index) {
    g_ejs_wintertc_apple_test_fail_provider_index = index;
}

void EJSWinterTCAppleTestSetFetchMaxBufferedBytes(NSUInteger maxBufferedBytes) {
    g_ejs_wintertc_apple_test_fetch_max_buffered_bytes = maxBufferedBytes > 0u ? maxBufferedBytes : 1024u * 1024u;
}

#endif

static NSError * EJSWinterTCAppleError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
            NSLocalizedDescriptionKey: message
        } : @{};

    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSWinterTCProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"WinterTC provider failed");
}

static NSDictionary * EJSWinterTCJSONObjectFromPayload(NSData *payload, NSError **error) {
    if (payload.length == 0u) {
        return @{};
    }

    id value = [NSJSONSerialization JSONObjectWithData:payload options:0 error:error];

    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"WinterTC payload must be a JSON object");
        }

        return nil;
    }

    return (NSDictionary *)value;
}

static NSData * EJSWinterTCJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];

    if (data == nil && error != NULL && *error == nil) {
        *error = EJSWinterTCProviderError(EJSProviderErrorCodeInternal, @"Failed to encode WinterTC JSON response");
    }

    return data;
}

static NSString * EJSWinterTCConsoleStringFromValue(id value) {
    if (value == nil || value == [NSNull null]) {
        return @"null";
    }

    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }

    if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];

        if (data.length > 0u) {
            NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

            if (json.length > 0u) {
                return json;
            }
        }
    }

    NSString *description = [value description];
    return description.length > 0u ? description : @"";
}

static NSString * EJSWinterTCStringFromJSONValue(id value) {
    if (value == nil || value == [NSNull null]) {
        return @"";
    }

    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }

    return [value description] ? : @"";
}

static int EJSWinterTCHexNibble(unichar ch) {
    if (ch >= '0' && ch <= '9') {
        return (int)(ch - '0');
    }

    if (ch >= 'a' && ch <= 'f') {
        return 10 + (int)(ch - 'a');
    }

    if (ch >= 'A' && ch <= 'F') {
        return 10 + (int)(ch - 'A');
    }

    return -1;
}

static NSData * EJSWinterTCPercentDecodedData(NSString *value, NSError **error) {
    NSMutableData *data = [NSMutableData data];
    NSUInteger length = value.length;

    for (NSUInteger i = 0u; i < length; ++i) {
        unichar ch = [value characterAtIndex:i];

        if (ch == '%') {
            if (i + 2u >= length) {
                if (error != NULL) {
                    *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                      @"Invalid percent escape in data URL");
                }

                return nil;
            }

            int high = EJSWinterTCHexNibble([value characterAtIndex:i + 1u]);
            int low = EJSWinterTCHexNibble([value characterAtIndex:i + 2u]);

            if (high < 0 || low < 0) {
                if (error != NULL) {
                    *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                      @"Invalid percent escape in data URL");
                }

                return nil;
            }

            uint8_t byte = (uint8_t)((high << 4) | low);
            [data appendBytes:&byte length:1u];
            i += 2u;
            continue;
        }

        NSString *scalar = [value substringWithRange:NSMakeRange(i, 1u)];
        NSData *encoded = [scalar dataUsingEncoding:NSUTF8StringEncoding];

        if (encoded == nil) {
            if (error != NULL) {
                *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                  @"Invalid UTF-8 scalar in data URL");
            }

            return nil;
        }

        [data appendData:encoded];
    }

    return data;
}

static BOOL EJSWinterTCDecodeDataURL(NSURL *url,
                                     NSData **bodyOut,
                                     NSDictionary<NSString *, NSString *> **headersOut,
                                     NSError **error) {
    NSString *absolute = url.absoluteString;

    if (![absolute hasPrefix:@"data:"]) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"Expected a data URL");
        }

        return NO;
    }

    NSString *payload = [absolute substringFromIndex:5u];
    NSRange commaRange = [payload rangeOfString:@","];

    if (commaRange.location == NSNotFound) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid data URL");
        }

        return NO;
    }

    NSString *metadata = [payload substringToIndex:commaRange.location];
    NSString *dataPart = [payload substringFromIndex:commaRange.location + 1u];
    NSArray<NSString *> *metadataParts = metadata.length > 0u ? [metadata componentsSeparatedByString:@";"] : @[];
    BOOL isBase64 = NO;
    NSString *contentType = @"text/plain;charset=US-ASCII";

    if (metadataParts.count > 0u && metadataParts.firstObject.length > 0u) {
        contentType = metadataParts.firstObject;
    }

    for (NSString *part in metadataParts) {
        if ([part caseInsensitiveCompare:@"base64"] == NSOrderedSame) {
            isBase64 = YES;
        }
    }

    NSData *body = nil;

    if (isBase64) {
        NSString *decodedString = dataPart.stringByRemovingPercentEncoding ? : dataPart;
        body = [[NSData alloc] initWithBase64EncodedString:decodedString options:NSDataBase64DecodingIgnoreUnknownCharacters];

        if (body == nil) {
            if (error != NULL) {
                *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid base64 data URL");
            }

            return NO;
        }
    } else {
        body = EJSWinterTCPercentDecodedData(dataPart, error);

        if (body == nil) {
            return NO;
        }
    }

    if (bodyOut != NULL) {
        *bodyOut = body ? : [NSData data];
    }

    if (headersOut != NULL) {
        *headersOut = @{
                @"content-type": contentType,
                @"content-length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]
        };
    }

    return YES;
}

static NSDictionary<NSString *, NSString *> * EJSWinterTCHeadersFromHTTPResponse(NSHTTPURLResponse *response) {
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];

    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        NSString *name = EJSWinterTCStringFromJSONValue(key).lowercaseString;
        NSString *value = EJSWinterTCStringFromJSONValue(obj);

        if (name.length > 0u) {
            headers[name] = value;
        }
    }];
    return headers;
}

static BOOL EJSWinterTCIsValidHeaderValue(NSString *value) {
    if (value == nil) {
        return NO;
    }
    return [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location == NSNotFound;
}

static BOOL EJSWinterTCSetRequestHeader(NSMutableURLRequest *request,
                                        NSString *name,
                                        NSString *value,
                                        NSError **error) {
    if (name.length == 0u) {
        return YES;
    }

    if (!EJSWinterTCIsValidHeaderValue(value)) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid header value");
        }
        return NO;
    }

    NSString *existing = [request valueForHTTPHeaderField:name];

    if (existing.length > 0u) {
        [request setValue:[existing stringByAppendingFormat:@", %@", value] forHTTPHeaderField:name];
    } else {
        [request setValue:value forHTTPHeaderField:name];
    }
    return YES;
}

static BOOL EJSWinterTCApplyRequestHeaders(NSMutableURLRequest *request, id headers, NSError **error) {
    if ([headers isKindOfClass:[NSArray class]]) {
        for (id pair in (NSArray *)headers) {
            if (![pair isKindOfClass:[NSArray class]] || [(NSArray *)pair count] < 2u) {
                continue;
            }

            NSString *name = EJSWinterTCStringFromJSONValue(((NSArray *)pair)[0]);
            NSString *value = EJSWinterTCStringFromJSONValue(((NSArray *)pair)[1]);
            if (!EJSWinterTCSetRequestHeader(request, name, value, error)) {
                return NO;
            }
        }
    } else if ([headers isKindOfClass:[NSDictionary class]]) {
        __block BOOL invalidHeaderValue = NO;
        __block NSError *localError = nil;
        [(NSDictionary *)headers
         enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if (!EJSWinterTCSetRequestHeader(request,
                                             EJSWinterTCStringFromJSONValue(key),
                                             EJSWinterTCStringFromJSONValue(obj),
                                             &localError)) {
                invalidHeaderValue = YES;
                *stop = YES;
            }
        }];
        if (invalidHeaderValue) {
            if (error != NULL) {
                *error = localError;
            }
            return NO;
        }
    }
    return YES;
}

static NSUInteger EJSWinterTCFetchStreamMaxBufferedBytes(void) {
#ifdef EJS_TEST
    return g_ejs_wintertc_apple_test_fetch_max_buffered_bytes;
#else
    return 1024u * 1024u;
#endif
}

static NSData * EJSWinterTCFetchStartResponseData(NSInteger status,
                                                  NSString *statusText,
                                                  NSDictionary<NSString *, NSString *> *headers,
                                                  NSString *streamID,
                                                  NSString *urlString,
                                                  BOOL redirected,
                                                  NSError **error) {
    NSDictionary *response = @{
            @"streamId": streamID ? : @"",
            @"status": @(status),
            @"statusText": statusText ? : @"",
            @"headers": headers ? : @{},
            @"url": urlString ? : @"",
            @"redirected": @(redirected)
    };

    return EJSWinterTCJSONData(response, error);
}

@implementation EJSWinterTCClockProvider {
    uint64_t _startTicks;
    mach_timebase_info_data_t _timebase;
    double _timeOriginEpochMs;
}

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        _moduleID = @"wintertc.clock";
        _startTicks = mach_absolute_time();
        _timeOriginEpochMs = [[NSDate date] timeIntervalSince1970] * 1000.0;

        if (mach_timebase_info(&_timebase) != KERN_SUCCESS || _timebase.denom == 0u) {
            _timebase.numer = 1u;
            _timebase.denom = 1u;
        }
    }

    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)methodID;
    (void)payload;
    (void)transferBuffer;
    (void)context;
    [responder finishWithData:nil
                        error:EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                                       @"wintertc.clock only supports sync methods")];
    return [[EJSImmediateOperation alloc] init];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
    (void)payload;
    (void)transferBuffer;
    (void)context;

    if (![methodID isEqualToString:@"now"]) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported wintertc.clock method");
        }

        return nil;
    }

    uint64_t elapsedTicks = mach_absolute_time() - _startTicks;
    double elapsedNs = (double)elapsedTicks * (double)_timebase.numer / (double)_timebase.denom;
    NSDictionary *response = @{
            @"timeOriginEpochMs": @(_timeOriginEpochMs),
            @"nowMs": @(elapsedNs / 1000000.0)
    };
    return EJSWinterTCJSONData(response, error);
}

@end

@implementation EJSWinterTCCryptoProvider

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        _moduleID = @"wintertc.crypto";
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
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                                           @"Unsupported wintertc.crypto async method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSWinterTCJSONObjectFromPayload(payload, &parseError);

    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *algorithm = request[@"algorithm"];

    if (![algorithm isKindOfClass:[NSString class]]) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                           @"Digest algorithm is required")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSData *input = transferBuffer ? : [NSData data];

    if (input.length > UINT32_MAX) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                           @"Digest input is too large")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSMutableData *digest = nil;
    NSString *normalized = algorithm.uppercaseString;

    if ([normalized isEqualToString:@"SHA-256"]) {
        digest = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(input.bytes, (CC_LONG)input.length, digest.mutableBytes);
    } else if ([normalized isEqualToString:@"SHA-384"]) {
        digest = [NSMutableData dataWithLength:CC_SHA384_DIGEST_LENGTH];
        CC_SHA384(input.bytes, (CC_LONG)input.length, digest.mutableBytes);
    } else if ([normalized isEqualToString:@"SHA-512"]) {
        digest = [NSMutableData dataWithLength:CC_SHA512_DIGEST_LENGTH];
        CC_SHA512(input.bytes, (CC_LONG)input.length, digest.mutableBytes);
    } else {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                                           @"Unsupported digest algorithm")];
        return [[EJSImmediateOperation alloc] init];
    }

    [responder finishWithData:digest error:nil];
    return [[EJSImmediateOperation alloc] init];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
    (void)transferBuffer;
    (void)context;

    if (![methodID isEqualToString:@"getRandomValues"]) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported wintertc.crypto sync method");
        }

        return nil;
    }

    NSDictionary *request = EJSWinterTCJSONObjectFromPayload(payload, error);

    if (request == nil) {
        return nil;
    }

    id byteLengthValue = request[@"byteLength"];

    if (![byteLengthValue respondsToSelector:@selector(longLongValue)]) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"byteLength is required");
        }

        return nil;
    }

    long long byteLength = [byteLengthValue longLongValue];

    if (byteLength < 0 || byteLength > 65536) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument, @"byteLength is out of range");
        }

        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)byteLength];

    if (byteLength == 0) {
        return data;
    }

    int status = SecRandomCopyBytes(kSecRandomDefault, (size_t)byteLength, data.mutableBytes);

    if (status != errSecSuccess) {
        if (error != NULL) {
            *error = EJSWinterTCProviderError(EJSProviderErrorCodeInternal, @"Secure random generation failed");
        }

        return nil;
    }

    return data;
}

@end

@implementation EJSWinterTCConsoleProvider

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        _moduleID = @"wintertc.console";
    }

    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)transferBuffer;
    (void)context;

    if (![methodID isEqualToString:@"write"]) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                                           @"Unsupported wintertc.console method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSWinterTCJSONObjectFromPayload(payload, &parseError);

    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *level = [request[@"level"] isKindOfClass:[NSString class]] ? request[@"level"] : @"log";
    NSArray *args = [request[@"args"] isKindOfClass:[NSArray class]] ? request[@"args"] : @[];
    NSMutableArray *stringArgs = [NSMutableArray arrayWithCapacity:args.count];

    for (id arg in args) {
        [stringArgs addObject:EJSWinterTCConsoleStringFromValue(arg)];
    }

    NSString *line = [stringArgs componentsJoinedByString:@" "];
    NSLog(@"[EJS WinterTC %@] %@", level, line);

    NSData *response = EJSWinterTCJSONData(@{ @"ok": @YES }, NULL);
    [responder finishWithData:response error:nil];
    return [[EJSImmediateOperation alloc] init];
}

@end

@implementation EJSWinterTCFetchStreamState

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        _condition = [[NSCondition alloc] init];
        _chunks = [[NSMutableArray alloc] init];
        _headChunkIndex = 0u;
        _headChunkOffset = 0u;
        _bufferedBytes = 0u;
        _completed = NO;
        _streamID = NSUUID.UUID.UUIDString;
        _requestURLString = @"";
    }

    return self;
}

@end

@implementation EJSWinterTCFetchSessionDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    EJSWinterTCFetchProvider *provider = self.provider;
    if (provider == nil) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    [provider URLSession:session
                dataTask:dataTask
       didReceiveResponse:response
        completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.provider URLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    [self.provider URLSession:session task:task didCompleteWithError:error];
}

@end

@implementation EJSWinterTCFetchProvider {
    NSURLSession *_session;
    EJSWinterTCFetchSessionDelegate *_sessionDelegate;
    NSLock *_lock;
    NSMutableDictionary<NSString *, EJSWinterTCFetchStreamState *> *_streamsByID;
    NSMutableDictionary<NSString *, NSURLSessionDataTask *> *_tasksBySignalID;
    NSMutableDictionary<NSNumber *, EJSWinterTCFetchStreamState *> *_statesByTaskID;
    NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *_tasksByTaskID;
}

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        _moduleID = @"wintertc.fetch";
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 60.0;
        configuration.timeoutIntervalForResource = 300.0;
        _sessionDelegate = [[EJSWinterTCFetchSessionDelegate alloc] init];
        _sessionDelegate.provider = self;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:_sessionDelegate delegateQueue:nil];
        _lock = [[NSLock alloc] init];
        _streamsByID = [[NSMutableDictionary alloc] init];
        _tasksBySignalID = [[NSMutableDictionary alloc] init];
        _statesByTaskID = [[NSMutableDictionary alloc] init];
        _tasksByTaskID = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (void)dealloc {
    _sessionDelegate.provider = nil;
    [_session invalidateAndCancel];
}

- (NSString *)storeFetchState:(EJSWinterTCFetchStreamState *)state {
    [_lock lock];
    _streamsByID[state.streamID] = state;
    [_lock unlock];
    return state.streamID;
}

- (void)removeFetchStateForStreamID:(NSString *)streamID expectedState:(EJSWinterTCFetchStreamState *)expectedState {
    [_lock lock];
    EJSWinterTCFetchStreamState *current = _streamsByID[streamID];

    if (current == expectedState) {
        [_streamsByID removeObjectForKey:streamID];
    }

    [_lock unlock];
}

- (BOOL)finishPendingStartForState:(EJSWinterTCFetchStreamState *)state
                              data:(NSData *)data
                             error:(NSError *)error {
    EJSProviderResponder *startResponder = nil;
    [state.condition lock];
    startResponder = state.startResponder;
    state.startResponder = nil;
    [state.condition unlock];

    if (startResponder != nil) {
        [startResponder finishWithData:data error:error];
        return YES;
    }

    return NO;
}

- (EJSWinterTCFetchStreamState *)fetchStateForStreamID:(NSString *)streamID {
    [_lock lock];
    EJSWinterTCFetchStreamState *state = _streamsByID[streamID];
    [_lock unlock];
    return state;
}

- (void)finalizeTaskMappingsForState:(EJSWinterTCFetchStreamState *)state task:(NSURLSessionTask *)task {
    NSNumber *taskKey = @(task.taskIdentifier);
    [_lock lock];
    [_statesByTaskID removeObjectForKey:taskKey];
    [_tasksByTaskID removeObjectForKey:taskKey];
    if (state.signalID.length > 0u) {
        [_tasksBySignalID removeObjectForKey:state.signalID];
    }
    [_lock unlock];
}

- (void)terminateState:(EJSWinterTCFetchStreamState *)state
                 error:(NSError *)error
             completed:(BOOL)completed
                signal:(BOOL)signal {
    [state.condition lock];
    if (state.terminalError == nil) {
        state.terminalError = error;
    }
    state.completed = completed;
    if (signal) {
        [state.condition broadcast];
    }
    [state.condition unlock];
}

- (void)cancelState:(EJSWinterTCFetchStreamState *)state reason:(NSString *)reason {
    if (state == nil) {
        return;
    }

    NSError *abortError = EJSWinterTCProviderError(EJSProviderErrorCodeAborted,
                                                   reason.length > 0u ? reason : @"Fetch was cancelled");
    [self terminateState:state error:abortError completed:YES signal:YES];
    [self finishPendingStartForState:state data:nil error:abortError];

    NSURLSessionDataTask *task = nil;
    [_lock lock];
    if (state.signalID.length > 0u) {
        task = _tasksBySignalID[state.signalID];
        [_tasksBySignalID removeObjectForKey:state.signalID];
    }
    NSNumber *matchedTaskKey = nil;
    for (NSNumber *taskKey in _statesByTaskID) {
        if (_statesByTaskID[taskKey] == state) {
            matchedTaskKey = taskKey;
            break;
        }
    }
    if (matchedTaskKey != nil) {
        [_statesByTaskID removeObjectForKey:matchedTaskKey];
        NSURLSessionDataTask *mappedTask = _tasksByTaskID[matchedTaskKey];
        if (task == nil) {
            task = mappedTask;
        }
        [_tasksByTaskID removeObjectForKey:matchedTaskKey];
    }
    [_lock unlock];

    [self removeFetchStateForStreamID:state.streamID expectedState:state];

    if (task != nil) {
        [task cancel];
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;

    if ([methodID isEqualToString:@"pull"]) {
        [self pullWithPayload:payload responder:responder];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"cancel"]) {
        [self cancelStreamWithPayload:payload responder:responder];
        return [[EJSImmediateOperation alloc] init];
    }

    if (![methodID isEqualToString:@"start"]) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                                           @"Unsupported wintertc.fetch method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSWinterTCJSONObjectFromPayload(payload, &parseError);

    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *urlString = [request[@"url"] isKindOfClass:[NSString class]] ? request[@"url"] : nil;
    NSString *signalID = [request[@"signalId"] isKindOfClass:[NSString class]] ? request[@"signalId"] : nil;
    NSString *redirectMode = [request[@"redirect"] isKindOfClass:[NSString class]] ? request[@"redirect"] : @"follow";
    NSURL *url = urlString.length > 0u ? [NSURL URLWithString:urlString] : nil;

    if (url == nil || url.scheme.length == 0u) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                           @"Fetch URL is required")];
        return [[EJSImmediateOperation alloc] init];
    }

    if (![redirectMode isEqualToString:@"follow"] &&
        ![redirectMode isEqualToString:@"error"] &&
        ![redirectMode isEqualToString:@"manual"]) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                           @"Invalid redirect mode")];
        return [[EJSImmediateOperation alloc] init];
    }

    if (![redirectMode isEqualToString:@"follow"]) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                                           @"Only redirect mode 'follow' is supported")];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([url.scheme caseInsensitiveCompare:@"data"] == NSOrderedSame) {
        NSData *body = nil;
        NSDictionary<NSString *, NSString *> *headers = nil;
        NSError *dataError = nil;

        if (!EJSWinterTCDecodeDataURL(url, &body, &headers, &dataError)) {
            [responder finishWithData:nil error:dataError];
            return [[EJSImmediateOperation alloc] init];
        }

        EJSWinterTCFetchStreamState *state = [[EJSWinterTCFetchStreamState alloc] init];
        state.requestURLString = url.absoluteString ? : @"";
        if (body.length > 0u) {
            [state.chunks addObject:body];
            state.bufferedBytes = body.length;
        }
        state.completed = YES;
        NSString *streamID = [self storeFetchState:state];
        NSData *response = EJSWinterTCFetchStartResponseData(200,
                                                             @"OK",
                                                             headers,
                                                             streamID,
                                                             url.absoluteString,
                                                             NO,
                                                             NULL);
        [responder finishWithData:response error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([url.scheme caseInsensitiveCompare:@"http"] != NSOrderedSame &&
        [url.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeSecurity,
                                                           @"Fetch only supports data, http, and https URLs")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
    NSString *method = [request[@"method"] isKindOfClass:[NSString class]] ? request[@"method"] : @"GET";
    urlRequest.HTTPMethod = method.length > 0u ? method.uppercaseString : @"GET";

    if (transferBuffer != nil) {
        urlRequest.HTTPBody = transferBuffer;
    }

    NSError *headerError = nil;
    if (!EJSWinterTCApplyRequestHeaders(urlRequest, request[@"headers"], &headerError)) {
        [responder finishWithData:nil error:headerError];
        return [[EJSImmediateOperation alloc] init];
    }
    EJSWinterTCFetchStreamState *state = [[EJSWinterTCFetchStreamState alloc] init];
    state.requestURLString = url.absoluteString ? : @"";
    state.signalID = signalID;
    state.startResponder = responder;
    [self storeFetchState:state];
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:urlRequest];
    NSNumber *taskKey = @(task.taskIdentifier);
    [_lock lock];
    _statesByTaskID[taskKey] = state;
    _tasksByTaskID[taskKey] = task;
    if (signalID.length > 0u) {
        _tasksBySignalID[signalID] = task;
    }
    [_lock unlock];
    [task resume];
    return [[EJSBlockOperation alloc] initWithCancelBlock:^{
        [self cancelState:state reason:@"Fetch operation was cancelled"];
    }];
}

- (void)pullWithPayload:(NSData *)payload responder:(EJSProviderResponder *)responder {
    NSError *parseError = nil;
    NSDictionary *request = EJSWinterTCJSONObjectFromPayload(payload, &parseError);

    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return;
    }

    NSString *streamID = [request[@"bodyStreamId"] isKindOfClass:[NSString class]] ? request[@"bodyStreamId"] : nil;

    if (streamID.length == 0u) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                           @"bodyStreamId is required")];
        return;
    }

    NSUInteger maxBytes = 65536u;
    id maxBytesValue = request[@"maxBytes"];

    if ([maxBytesValue respondsToSelector:@selector(unsignedIntegerValue)]) {
        maxBytes = MAX((NSUInteger)1u, MIN((NSUInteger)1048576u, [maxBytesValue unsignedIntegerValue]));
    }

    EJSWinterTCFetchStreamState *state = [self fetchStateForStreamID:streamID];

    if (state == nil) {
        [responder finishWithData:nil
                            error:EJSWinterTCProviderError(EJSProviderErrorCodeInvalidArgument,
                                                           @"Unknown fetch body stream")];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        while (YES) {
            [state.condition lock];
            while (state.terminalError == nil &&
                   state.headChunkIndex >= state.chunks.count &&
                   !state.completed) {
                [state.condition wait];
            }

            if (state.terminalError != nil) {
                NSError *streamError = state.terminalError;
                [state.condition unlock];
                [self removeFetchStateForStreamID:streamID expectedState:state];
                [responder finishWithData:nil error:streamError];
                return;
            }

            if (state.headChunkIndex >= state.chunks.count) {
                [state.condition unlock];
                [self removeFetchStateForStreamID:streamID expectedState:state];
                uint8_t done = 0x00u;
                [responder finishWithData:[NSData dataWithBytes:&done length:1u] error:nil];
                return;
            }

            NSData *chunk = state.chunks[state.headChunkIndex];
            NSUInteger available = chunk.length > state.headChunkOffset ? chunk.length - state.headChunkOffset : 0u;

            if (available == 0u) {
                state.headChunkIndex += 1u;
                state.headChunkOffset = 0u;
                [state.condition unlock];
                continue;
            }

            NSUInteger chunkLength = MIN(available, maxBytes);
            NSMutableData *frame = [NSMutableData dataWithLength:chunkLength + 1u];
            uint8_t *bytes = frame.mutableBytes;
            bytes[0] = 0x01u;
            memcpy(bytes + 1u, (const uint8_t *)chunk.bytes + state.headChunkOffset, chunkLength);
            state.headChunkOffset += chunkLength;
            state.bufferedBytes -= chunkLength;

            if (state.headChunkOffset >= chunk.length) {
                state.headChunkIndex += 1u;
                state.headChunkOffset = 0u;
                if (state.headChunkIndex > 0u && state.headChunkIndex * 2u >= state.chunks.count) {
                    [state.chunks removeObjectsInRange:NSMakeRange(0u, state.headChunkIndex)];
                    state.headChunkIndex = 0u;
                }
            }

            [state.condition unlock];
            [responder finishWithData:frame error:nil];
            return;
        }
    });
}

- (void)cancelStreamWithPayload:(NSData *)payload responder:(EJSProviderResponder *)responder {
    NSError *parseError = nil;
    NSDictionary *request = EJSWinterTCJSONObjectFromPayload(payload, &parseError);

    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return;
    }

    NSString *streamID = [request[@"bodyStreamId"] isKindOfClass:[NSString class]] ? request[@"bodyStreamId"] : nil;
    NSString *signalID = [request[@"signalId"] isKindOfClass:[NSString class]] ? request[@"signalId"] : nil;

    if (streamID.length > 0u) {
        EJSWinterTCFetchStreamState *state = [self fetchStateForStreamID:streamID];
        [self cancelState:state reason:@"Fetch body stream cancelled"];
    }

    if (signalID.length > 0u) {
        NSURLSessionDataTask *task = nil;
        EJSWinterTCFetchStreamState *state = nil;
        [_lock lock];
        task = _tasksBySignalID[signalID];
        if (task != nil) {
            [_tasksBySignalID removeObjectForKey:signalID];
            state = _statesByTaskID[@(task.taskIdentifier)];
        }
        [_lock unlock];

        if (task != nil) {
            if (state != nil) {
                [self cancelState:state reason:@"Fetch signal cancelled"];
            } else {
                [task cancel];
            }
        }
    }

    NSData *response = EJSWinterTCJSONData(@{ @"ok": @YES }, NULL);
    [responder finishWithData:response error:nil];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
    (void)methodID;
    (void)payload;
    (void)transferBuffer;
    (void)context;

    if (error != NULL) {
        *error = EJSWinterTCProviderError(EJSProviderErrorCodeUnsupported,
                                          @"wintertc.fetch does not support sync methods");
    }

    return nil;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    EJSWinterTCFetchStreamState *state = nil;
    [_lock lock];
    state = _statesByTaskID[@(dataTask.taskIdentifier)];
    [_lock unlock];

    if (state == nil) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSError *responseError = EJSWinterTCProviderError(EJSProviderErrorCodeNetwork,
                                                          @"Fetch did not return an HTTP response");
        [self terminateState:state error:responseError completed:YES signal:YES];
        [self finishPendingStartForState:state data:nil error:responseError];
        [self removeFetchStateForStreamID:state.streamID expectedState:state];
        [self finalizeTaskMappingsForState:state task:dataTask];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSString *responseURL = httpResponse.URL.absoluteString;
    if (responseURL.length == 0u) {
        responseURL = dataTask.currentRequest.URL.absoluteString;
    }
    if (responseURL.length == 0u) {
        responseURL = state.requestURLString;
    }
    BOOL redirected = responseURL.length > 0u &&
                      state.requestURLString.length > 0u &&
                      ![responseURL isEqualToString:state.requestURLString];
    NSError *encodeError = nil;
    NSData *responseData = EJSWinterTCFetchStartResponseData(httpResponse.statusCode,
                                                             [NSHTTPURLResponse localizedStringForStatusCode:httpResponse.statusCode],
                                                             EJSWinterTCHeadersFromHTTPResponse(httpResponse),
                                                             state.streamID,
                                                             responseURL,
                                                             redirected,
                                                             &encodeError);
    if (encodeError != nil) {
        [self terminateState:state error:encodeError completed:YES signal:YES];
        [self finishPendingStartForState:state data:nil error:encodeError];
        [self removeFetchStateForStreamID:state.streamID expectedState:state];
        [self finalizeTaskMappingsForState:state task:dataTask];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    completionHandler(NSURLSessionResponseAllow);
    [self finishPendingStartForState:state data:responseData error:nil];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (data.length == 0u) {
        return;
    }

    EJSWinterTCFetchStreamState *state = nil;
    [_lock lock];
    state = _statesByTaskID[@(dataTask.taskIdentifier)];
    [_lock unlock];

    if (state == nil) {
        return;
    }

    BOOL overflowed = NO;
    NSError *overflowError = nil;
    [state.condition lock];
    if (state.terminalError == nil && !state.completed) {
        if (state.bufferedBytes + data.length > EJSWinterTCFetchStreamMaxBufferedBytes()) {
            overflowError = EJSWinterTCProviderError(EJSProviderErrorCodeInternal,
                                                     @"Fetch stream buffered data exceeded limit");
            state.terminalError = overflowError;
            state.completed = YES;
            overflowed = YES;
            [state.condition broadcast];
        } else {
            [state.chunks addObject:data];
            state.bufferedBytes += data.length;
            [state.condition signal];
        }
    }
    [state.condition unlock];

    if (overflowed) {
        [self finishPendingStartForState:state data:nil error:overflowError];
        [dataTask cancel];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    EJSWinterTCFetchStreamState *state = nil;
    [_lock lock];
    state = _statesByTaskID[@(task.taskIdentifier)];
    [_lock unlock];

    if (state == nil) {
        return;
    }

    [self finalizeTaskMappingsForState:state task:task];

    if (error != nil) {
        [self terminateState:state error:error completed:YES signal:YES];
        BOOL failedBeforeStartCompleted = [self finishPendingStartForState:state data:nil error:error];
        if (failedBeforeStartCompleted) {
            [self removeFetchStateForStreamID:state.streamID expectedState:state];
        }
        return;
    }

    [state.condition lock];
    state.completed = YES;
    [state.condition broadcast];
    [state.condition unlock];
}

@end

static NSArray<NSString *> * EJSWinterTCOwnedGlobalNames(void) {
    return @[
        @"setTimeout",
        @"clearTimeout",
        @"setInterval",
        @"clearInterval",
        @"queueMicrotask",
        @"Event",
        @"CustomEvent",
        @"ErrorEvent",
        @"PromiseRejectionEvent",
        @"EventTarget",
        @"AbortSignal",
        @"AbortController",
        @"onerror",
        @"onunhandledrejection",
        @"onrejectionhandled",
        @"addEventListener",
        @"removeEventListener",
        @"dispatchEvent",
        @"reportError",
        @"URLSearchParams",
        @"URL",
        @"TextEncoder",
        @"TextDecoder",
        @"Blob",
        @"File",
        @"ReadableStream",
        @"Headers",
        @"Request",
        @"Response",
        @"fetch",
        @"crypto",
        @"performance",
        @"console",
        @"WinterTC"
    ];
}

static BOOL EJSWinterTCRegisterDefaultProviders(EJSAppleInstallTransaction *transaction, NSError **error) {
    NSArray *providers = @[
        [[EJSWinterTCClockProvider alloc] init],
        [[EJSWinterTCCryptoProvider alloc] init],
        [[EJSWinterTCConsoleProvider alloc] init],
        [[EJSWinterTCFetchProvider alloc] init]
    ];

    for (NSUInteger i = 0u; i < providers.count; ++i) {
#ifdef EJS_TEST
        if (g_ejs_wintertc_apple_test_fail_provider_index >= 0 &&
            (NSUInteger)g_ejs_wintertc_apple_test_fail_provider_index == i) {
            if (error != NULL) {
                *error = EJSWinterTCAppleError(EJSRuntimeErrorCodeInternal, @"WinterTC test provider install sentinel");
            }
            return NO;
        }
#endif

        id<EJSProvider> provider = providers[i];
        if (!EJSAppleInstallTransactionRegisterProvider(transaction, provider, error)) {
            return NO;
        }
    }

    return YES;
}

BOOL EJSWinterTCInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSWinterTCInstallIntoContextWithOptions(context, nil, error);
}

BOOL EJSWinterTCInstallIntoContextWithOptions(EJSContext                *context,
                                              EJSWinterTCInstallOptions *options,
                                              NSError                   **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSWinterTCAppleError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }

        return NO;
    }

#ifdef EJS_TEST

    if (g_ejs_wintertc_apple_test_init_source != NULL) {
        NSString *source = [NSString stringWithUTF8String:g_ejs_wintertc_apple_test_init_source];

        if (source == nil) {
            if (error != NULL) {
                *error = EJSWinterTCAppleError(EJSRuntimeErrorCodeInvalidArgument, @"WinterTC test source must be valid UTF-8");
            }

            return NO;
        }

        return [context evaluateScript:source filename:@"wintertc_test_init.js" error:error];
    }

#endif

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, EJSWinterTCOwnedGlobalNames(), error)) {
        return NO;
    }

    for (size_t i = 0u; i < ejs_wintertc_scripts_count; ++i) {
#ifdef EJS_TEST
        if (g_ejs_wintertc_apple_test_fail_script_index >= 0 &&
            (size_t)g_ejs_wintertc_apple_test_fail_script_index == i) {
            if (error != NULL) {
                *error = EJSWinterTCAppleError(EJSRuntimeErrorCodeInternal, @"WinterTC test install sentinel");
            }
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
#endif

        const EJSWinterTCBundledScript *script = &ejs_wintertc_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSWinterTCAppleError(EJSRuntimeErrorCodeInvalidArgument,
                                               @"WinterTC bundled script must be valid UTF-8");
            }

            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }

        if (![context evaluateScript:source filename:filename error:error]) {
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
    }

    BOOL installDefaultProviders = options != nil && options.installDefaultProviders;
    if (installDefaultProviders && !EJSWinterTCRegisterDefaultProviders(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    if (!EJSAppleInstallTransactionCommit(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    return YES;
}
