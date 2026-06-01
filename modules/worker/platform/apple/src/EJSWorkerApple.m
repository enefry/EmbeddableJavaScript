#import "EJSWorkerApple.h"

#import "EJSApplePlatform.h"
#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_worker_js_bundle.h"

#include <limits.h>

NSString * const EJSWorkerConfigurationKey = @"ejs.worker";

static const unsigned long long EJSWorkerDefaultMaxWorkers = 4ull;
static const unsigned long long EJSWorkerDefaultMaxQueuedMessages = 64ull;
static const unsigned long long EJSWorkerDefaultMaxMessageBytes = 1024ull * 1024ull;
static const unsigned long long EJSWorkerDefaultMaxSourceBytes = 1024ull * 1024ull;
static const unsigned long long EJSWorkerDefaultStartupTimeoutMs = 5000ull;
static const unsigned long long EJSWorkerDefaultTerminationTimeoutMs = 2000ull;

#ifdef EJS_TEST
static NSInteger g_ejs_worker_apple_test_fail_script_index = -1;

void EJSWorkerAppleTestSetInstallFailScriptIndex(NSInteger index) {
    g_ejs_worker_apple_test_fail_script_index = index;
}
#endif

typedef NS_ENUM(NSInteger, EJSWorkerInstanceState) {
    EJSWorkerInstanceStateStarting = 0,
    EJSWorkerInstanceStateRunning = 1,
    EJSWorkerInstanceStateTerminating = 2,
    EJSWorkerInstanceStateTerminated = 3
};

@class EJSWorkerAppleProvider;

static NSError * EJSWorkerRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSWorkerProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"Worker provider failed");
}

static BOOL EJSWorkerStringIsNonEmpty(NSString *value) {
    return [value isKindOfClass:[NSString class]] && value.length > 0u;
}

static BOOL EJSWorkerBoolValue(id value, BOOL defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    return [value boolValue];
}

static unsigned long long EJSWorkerUnsignedLimit(id value, unsigned long long defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    long long number = [value longLongValue];
    if (number <= 0) {
        return defaultValue;
    }
    return (unsigned long long)number;
}

static BOOL EJSWorkerPathHasParentTraversal(NSString *path) {
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@".."]) {
            return YES;
        }
    }
    return NO;
}

static BOOL EJSWorkerPathIsInsideRoot(NSString *path, NSString *rootPath) {
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *standardRoot = [rootPath stringByStandardizingPath];
    if ([standardRoot isEqualToString:@"/"]) {
        return [standardPath hasPrefix:@"/"];
    }
    return [standardPath isEqualToString:standardRoot] ||
        [standardPath hasPrefix:[standardRoot stringByAppendingString:@"/"]];
}

static BOOL EJSWorkerSpecifierLooksLikeURLScheme(NSString *specifier) {
    if (!EJSWorkerStringIsNonEmpty(specifier)) {
        return NO;
    }
    NSRange colonRange = [specifier rangeOfString:@":"];
    if (colonRange.location == NSNotFound || colonRange.location == 0u) {
        return NO;
    }
    NSString *scheme = [specifier substringToIndex:colonRange.location];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-"];
    for (NSUInteger i = 0; i < scheme.length; i++) {
        unichar character = [scheme characterAtIndex:i];
        if (![allowed characterIsMember:character]) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary * EJSWorkerJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"worker payload is required");
        }
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"worker payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData * EJSWorkerJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSWorkerProviderError(EJSProviderErrorCodeInternal, @"Failed to encode worker JSON response");
    }
    return data;
}

static NSData * EJSWorkerMessageFrameData(NSDictionary *envelope, NSData *sidecar, NSError **error) {
    NSData *headerData = [NSJSONSerialization dataWithJSONObject:@{
        @"envelope": envelope ?: @{}
    } options:0 error:error];
    if (headerData == nil) {
        if (error != NULL && *error == nil) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInternal, @"Failed to encode worker message envelope");
        }
        return nil;
    }

    if (headerData.length > UINT32_MAX) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInternal, @"Worker envelope exceeds maximum size");
        }
        return nil;
    }

    uint32_t headerLength = (uint32_t)headerData.length;
    NSMutableData *frame = [NSMutableData dataWithCapacity:4u + headerData.length + sidecar.length];
    uint8_t headerPrefix[4] = {
        (uint8_t)(headerLength & 0xffu),
        (uint8_t)((headerLength >> 8u) & 0xffu),
        (uint8_t)((headerLength >> 16u) & 0xffu),
        (uint8_t)((headerLength >> 24u) & 0xffu)
    };
    [frame appendBytes:headerPrefix length:4u];
    [frame appendData:headerData];
    if (sidecar.length > 0u) {
        [frame appendData:sidecar];
    }
    return frame;
}

static NSDictionary * EJSWorkerDefaultLimitsDictionary(void) {
    return @{
        @"maxWorkers": @(EJSWorkerDefaultMaxWorkers),
        @"maxQueuedMessages": @(EJSWorkerDefaultMaxQueuedMessages),
        @"maxMessageBytes": @(EJSWorkerDefaultMaxMessageBytes),
        @"maxSourceBytes": @(EJSWorkerDefaultMaxSourceBytes),
        @"startupTimeoutMs": @(EJSWorkerDefaultStartupTimeoutMs),
        @"terminationTimeoutMs": @(EJSWorkerDefaultTerminationTimeoutMs)
    };
}

@interface EJSWorkerInstallOptions ()
- (instancetype)initWithInstallWorkerContext:(BOOL (^_Nullable)(EJSContext *workerContext, NSError **error))installWorkerContext;
@end

@implementation EJSWorkerInstallOptions

- (instancetype)init {
    return [self initWithInstallWorkerContext:nil];
}

- (instancetype)initWithInstallWorkerContext:(BOOL (^_Nullable)(EJSContext *, NSError **))installWorkerContext {
    self = [super init];
    if (self != nil) {
        _installWorkerContext = [installWorkerContext copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithInstallWorkerContext:self.installWorkerContext];
}

@end

@interface EJSWorkerRootPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, assign, readonly) BOOL canRead;
- (instancetype)initWithName:(NSString *)name path:(NSString *)path canRead:(BOOL)canRead;
@end

@implementation EJSWorkerRootPolicy
- (instancetype)initWithName:(NSString *)name path:(NSString *)path canRead:(BOOL)canRead {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _path = [[path stringByStandardizingPath] copy];
        _canRead = canRead;
    }
    return self;
}
@end

@interface EJSWorkerScriptPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *root;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, copy, readonly) NSString *type;
- (instancetype)initWithName:(NSString *)name root:(NSString *)root path:(NSString *)path type:(NSString *)type;
@end

@implementation EJSWorkerScriptPolicy
- (instancetype)initWithName:(NSString *)name root:(NSString *)root path:(NSString *)path type:(NSString *)type {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _root = [root copy];
        _path = [path copy];
        _type = [type copy];
    }
    return self;
}
@end

@interface EJSWorkerInlineScriptPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *source;
@property (nonatomic, copy, readonly) NSString *type;
- (instancetype)initWithName:(NSString *)name source:(NSString *)source type:(NSString *)type;
@end

@implementation EJSWorkerInlineScriptPolicy
- (instancetype)initWithName:(NSString *)name source:(NSString *)source type:(NSString *)type {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _source = [source copy];
        _type = [type copy];
    }
    return self;
}
@end

@interface EJSWorkerLimits : NSObject
@property (nonatomic, assign, readonly) unsigned long long maxWorkers;
@property (nonatomic, assign, readonly) unsigned long long maxQueuedMessages;
@property (nonatomic, assign, readonly) unsigned long long maxMessageBytes;
@property (nonatomic, assign, readonly) unsigned long long maxSourceBytes;
@property (nonatomic, assign, readonly) unsigned long long startupTimeoutMs;
@property (nonatomic, assign, readonly) unsigned long long terminationTimeoutMs;
- (instancetype)initWithMaxWorkers:(unsigned long long)maxWorkers
                 maxQueuedMessages:(unsigned long long)maxQueuedMessages
                   maxMessageBytes:(unsigned long long)maxMessageBytes
                    maxSourceBytes:(unsigned long long)maxSourceBytes
                  startupTimeoutMs:(unsigned long long)startupTimeoutMs
              terminationTimeoutMs:(unsigned long long)terminationTimeoutMs;
@end

@implementation EJSWorkerLimits
- (instancetype)initWithMaxWorkers:(unsigned long long)maxWorkers
                 maxQueuedMessages:(unsigned long long)maxQueuedMessages
                   maxMessageBytes:(unsigned long long)maxMessageBytes
                    maxSourceBytes:(unsigned long long)maxSourceBytes
                  startupTimeoutMs:(unsigned long long)startupTimeoutMs
              terminationTimeoutMs:(unsigned long long)terminationTimeoutMs {
    self = [super init];
    if (self != nil) {
        _maxWorkers = maxWorkers;
        _maxQueuedMessages = maxQueuedMessages;
        _maxMessageBytes = maxMessageBytes;
        _maxSourceBytes = maxSourceBytes;
        _startupTimeoutMs = startupTimeoutMs;
        _terminationTimeoutMs = terminationTimeoutMs;
    }
    return self;
}
@end

@interface EJSWorkerSourcePolicy : NSObject
@property (nonatomic, copy, readonly) NSString *defaultRoot;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSWorkerRootPolicy *> *roots;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSWorkerScriptPolicy *> *scripts;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSWorkerInlineScriptPolicy *> *inlineScripts;
@property (nonatomic, assign, readonly) BOOL allowAbsolutePath;
@property (nonatomic, assign, readonly) BOOL allowParentTraversal;
@property (nonatomic, assign, readonly) BOOL allowSymlinkEscape;
@property (nonatomic, strong, readonly) EJSWorkerLimits *limits;
- (instancetype)initWithDefaultRoot:(NSString *)defaultRoot
                              roots:(NSDictionary<NSString *, EJSWorkerRootPolicy *> *)roots
                            scripts:(NSDictionary<NSString *, EJSWorkerScriptPolicy *> *)scripts
                       inlineScripts:(NSDictionary<NSString *, EJSWorkerInlineScriptPolicy *> *)inlineScripts
                  allowAbsolutePath:(BOOL)allowAbsolutePath
               allowParentTraversal:(BOOL)allowParentTraversal
                 allowSymlinkEscape:(BOOL)allowSymlinkEscape
                             limits:(EJSWorkerLimits *)limits;
@end

@implementation EJSWorkerSourcePolicy
- (instancetype)initWithDefaultRoot:(NSString *)defaultRoot
                              roots:(NSDictionary<NSString *,EJSWorkerRootPolicy *> *)roots
                            scripts:(NSDictionary<NSString *,EJSWorkerScriptPolicy *> *)scripts
                       inlineScripts:(NSDictionary<NSString *,EJSWorkerInlineScriptPolicy *> *)inlineScripts
                  allowAbsolutePath:(BOOL)allowAbsolutePath
               allowParentTraversal:(BOOL)allowParentTraversal
                 allowSymlinkEscape:(BOOL)allowSymlinkEscape
                             limits:(EJSWorkerLimits *)limits {
    self = [super init];
    if (self != nil) {
        _defaultRoot = [defaultRoot copy];
        _roots = [roots copy];
        _scripts = [scripts copy];
        _inlineScripts = [inlineScripts copy];
        _allowAbsolutePath = allowAbsolutePath;
        _allowParentTraversal = allowParentTraversal;
        _allowSymlinkEscape = allowSymlinkEscape;
        _limits = limits;
    }
    return self;
}
@end

@interface EJSWorkerInstance : NSObject
@property (nonatomic, copy, readonly) NSString *workerID;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *specifier;
@property (nonatomic, strong, readonly) EJSRuntime *runtime;
@property (nonatomic, strong, readonly) EJSContext *context;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSData *> *parentInbox;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, NSData *> *childInbox;
@property (nonatomic, strong, readonly) dispatch_queue_t dispatchQueue;
@property (nonatomic, assign) EJSWorkerInstanceState state;
@property (nonatomic, assign) unsigned long long nextMessageID;
@property (nonatomic, copy) NSString *terminationNotificationMessageID;
@property (nonatomic, copy) NSString *startupSource;
@property (nonatomic, copy) NSString *startupType;
@property (nonatomic, copy) NSString *startupFilename;
@property (nonatomic, assign) BOOL startupStarted;
@property (nonatomic, weak) EJSWorkerAppleProvider *ownerProvider;
- (instancetype)initWithWorkerID:(NSString *)workerID
                            name:(NSString *)name
                       specifier:(NSString *)specifier
                         runtime:(EJSRuntime *)runtime
                         context:(EJSContext *)context;
@end

@implementation EJSWorkerInstance
- (instancetype)initWithWorkerID:(NSString *)workerID
                            name:(NSString *)name
                       specifier:(NSString *)specifier
                         runtime:(EJSRuntime *)runtime
                         context:(EJSContext *)context {
    self = [super init];
    if (self != nil) {
        _workerID = [workerID copy];
        _name = [name copy];
        _specifier = [specifier copy];
        _runtime = runtime;
        _context = context;
        _parentInbox = [[NSMutableDictionary alloc] init];
        _childInbox = [[NSMutableDictionary alloc] init];
        NSString *queueLabel = [NSString stringWithFormat:@"dev.ejs.worker.%@", workerID ?: @"unknown"];
        _dispatchQueue = dispatch_queue_create(queueLabel.UTF8String, DISPATCH_QUEUE_SERIAL);
        _state = EJSWorkerInstanceStateStarting;
        _nextMessageID = 1ull;
        _terminationNotificationMessageID = @"";
        _startupSource = @"";
        _startupType = @"classic";
        _startupFilename = @"ejs-worker://unknown";
        _startupStarted = NO;
    }
    return self;
}
@end

@interface EJSWorkerChildProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@property (nonatomic, weak, readonly) EJSWorkerAppleProvider *ownerProvider;
@property (nonatomic, weak, readonly) EJSWorkerInstance *instance;
- (instancetype)initWithOwnerProvider:(EJSWorkerAppleProvider *)ownerProvider instance:(EJSWorkerInstance *)instance;
@end

@interface EJSWorkerAppleProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithContext:(EJSContext *)context
                         policy:(EJSWorkerSourcePolicy *)policy
                 installOptions:(EJSWorkerInstallOptions *_Nullable)installOptions;
- (EJSWorkerInstance *_Nullable)workerForID:(NSString *)workerID;
#ifdef EJS_TEST
- (BOOL)dispatchMessageToContext:(EJSContext *)targetContext
                           queue:(dispatch_queue_t)queue
                        workerID:(NSString *)workerID
                       messageID:(NSString *)messageID
                 cleanupOnFailure:(dispatch_block_t)cleanupOnFailure
                           error:(NSError **)error;
- (NSDictionary *_Nullable)resolvedSourceForSpecifier:(NSString *)specifier
                                             options:(NSDictionary *)options
                                               error:(NSError **)error;
- (EJSWorkerInstance *_Nullable)testInstanceWithWorkerID:(NSString *)workerID
                                                    name:(NSString *)name
                                               specifier:(NSString *)specifier
                                                  source:(NSString *)source
                                                    type:(NSString *)type
                                                   error:(NSError **)error;
- (void)testStoreInstance:(EJSWorkerInstance *)instance;
- (void)testRemoveInstance:(EJSWorkerInstance *)instance;
- (BOOL)runInternalStateCoverageWithRootPath:(NSString *)rootPath error:(NSError **)error;
#endif
- (id<EJSProviderOperation>)startWorkerWithRequest:(NSDictionary *)request
                                         responder:(EJSProviderResponder *)responder;
- (NSData *_Nullable)enqueueMessageFromChildForInstance:(EJSWorkerInstance *)instance
                                                envelope:(NSDictionary *)envelope
                                          transferBuffer:(NSData *)transferBuffer
                                                   error:(NSError **)error;
- (NSData *_Nullable)takeMessageForChildInstance:(EJSWorkerInstance *)instance
                                       request:(NSDictionary *)request
                                         error:(NSError **)error;
- (NSData *_Nullable)closeFromChildForInstance:(EJSWorkerInstance *)instance error:(NSError **)error;
- (NSData *_Nullable)reportErrorFromChildForInstance:(EJSWorkerInstance *)instance
                                             payload:(NSDictionary *)request
                                               error:(NSError **)error;
@end

#ifdef EJS_TEST
static BOOL EJSWorkerTestFail(NSError **error, NSString *message);
#endif

static EJSWorkerSourcePolicy * EJSWorkerSourcePolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0u) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Missing ejs.worker configuration");
        }
        return nil;
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.worker configuration must be valid UTF-8");
        }
        return nil;
    }

    NSError *jsonError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                           jsonError.localizedDescription ?: @"ejs.worker configuration must be a JSON object");
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    NSNumber *version = [object[@"version"] isKindOfClass:[NSNumber class]] ? object[@"version"] : nil;
    if (version == nil || version.integerValue != 1) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Unsupported ejs.worker configuration version");
        }
        return nil;
    }

    NSString *defaultRoot = [object[@"defaultRoot"] isKindOfClass:[NSString class]] ? object[@"defaultRoot"] : nil;
    NSDictionary *rootsObject = [object[@"roots"] isKindOfClass:[NSDictionary class]] ? object[@"roots"] : nil;
    if (!EJSWorkerStringIsNonEmpty(defaultRoot) || rootsObject.count == 0u) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.worker requires defaultRoot and roots");
        }
        return nil;
    }

    NSMutableDictionary<NSString *, EJSWorkerRootPolicy *> *roots = [[NSMutableDictionary alloc] init];
    for (NSString *rootName in rootsObject) {
        NSDictionary *rootObject = [rootsObject[rootName] isKindOfClass:[NSDictionary class]] ? rootsObject[rootName] : nil;
        NSString *path = [rootObject[@"path"] isKindOfClass:[NSString class]] ? rootObject[@"path"] : nil;
        NSArray *permissions = [rootObject[@"permissions"] isKindOfClass:[NSArray class]] ? rootObject[@"permissions"] : nil;
        BOOL canRead = NO;
        for (id permission in permissions) {
            if ([permission isKindOfClass:[NSString class]] && [permission isEqualToString:@"read"]) {
                canRead = YES;
            }
        }

        if (!EJSWorkerStringIsNonEmpty(rootName) ||
            !EJSWorkerStringIsNonEmpty(path) ||
            !path.isAbsolutePath ||
            !canRead) {
            if (error != NULL) {
                *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                               @"ejs.worker roots require non-empty names, absolute paths, and read permission");
            }
            return nil;
        }

        roots[rootName] = [[EJSWorkerRootPolicy alloc] initWithName:rootName path:path canRead:canRead];
    }

    if (roots[defaultRoot] == nil) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.worker defaultRoot must exist in roots");
        }
        return nil;
    }

    NSMutableDictionary<NSString *, EJSWorkerScriptPolicy *> *scripts = [[NSMutableDictionary alloc] init];
    NSDictionary *scriptsObject = [object[@"scripts"] isKindOfClass:[NSDictionary class]] ? object[@"scripts"] : @{};
    for (NSString *scriptName in scriptsObject) {
        NSDictionary *scriptObject = [scriptsObject[scriptName] isKindOfClass:[NSDictionary class]] ? scriptsObject[scriptName] : nil;
        NSString *root = [scriptObject[@"root"] isKindOfClass:[NSString class]] ? scriptObject[@"root"] : nil;
        NSString *path = [scriptObject[@"path"] isKindOfClass:[NSString class]] ? scriptObject[@"path"] : nil;
        NSString *type = [scriptObject[@"type"] isKindOfClass:[NSString class]] ? scriptObject[@"type"] : @"classic";
        if (!EJSWorkerStringIsNonEmpty(scriptName) ||
            !EJSWorkerStringIsNonEmpty(root) ||
            !EJSWorkerStringIsNonEmpty(path) ||
            (![type isEqualToString:@"classic"] && ![type isEqualToString:@"module"])) {
            if (error != NULL) {
                *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.worker scripts entries are invalid");
            }
            return nil;
        }
        scripts[scriptName] = [[EJSWorkerScriptPolicy alloc] initWithName:scriptName root:root path:path type:type];
    }

    NSMutableDictionary<NSString *, EJSWorkerInlineScriptPolicy *> *inlineScripts = [[NSMutableDictionary alloc] init];
    NSDictionary *inlineScriptsObject = [object[@"inlineScripts"] isKindOfClass:[NSDictionary class]] ? object[@"inlineScripts"] : @{};
    for (NSString *scriptName in inlineScriptsObject) {
        NSDictionary *scriptObject = [inlineScriptsObject[scriptName] isKindOfClass:[NSDictionary class]] ? inlineScriptsObject[scriptName] : nil;
        NSString *source = [scriptObject[@"source"] isKindOfClass:[NSString class]] ? scriptObject[@"source"] : nil;
        NSString *type = [scriptObject[@"type"] isKindOfClass:[NSString class]] ? scriptObject[@"type"] : @"classic";
        if (!EJSWorkerStringIsNonEmpty(scriptName) ||
            source == nil ||
            (![type isEqualToString:@"classic"] && ![type isEqualToString:@"module"])) {
            if (error != NULL) {
                *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.worker inlineScripts entries are invalid");
            }
            return nil;
        }
        inlineScripts[scriptName] = [[EJSWorkerInlineScriptPolicy alloc] initWithName:scriptName source:source type:type];
    }

    NSDictionary *pathPolicy = [object[@"pathPolicy"] isKindOfClass:[NSDictionary class]] ? object[@"pathPolicy"] : @{};
    NSDictionary *limits = [object[@"limits"] isKindOfClass:[NSDictionary class]] ? object[@"limits"] : @{};
    EJSWorkerLimits *resolvedLimits = [[EJSWorkerLimits alloc] initWithMaxWorkers:EJSWorkerUnsignedLimit(limits[@"maxWorkers"], EJSWorkerDefaultMaxWorkers)
                                                                 maxQueuedMessages:EJSWorkerUnsignedLimit(limits[@"maxQueuedMessages"], EJSWorkerDefaultMaxQueuedMessages)
                                                                   maxMessageBytes:EJSWorkerUnsignedLimit(limits[@"maxMessageBytes"], EJSWorkerDefaultMaxMessageBytes)
                                                                    maxSourceBytes:EJSWorkerUnsignedLimit(limits[@"maxSourceBytes"], EJSWorkerDefaultMaxSourceBytes)
                                                                  startupTimeoutMs:EJSWorkerUnsignedLimit(limits[@"startupTimeoutMs"], EJSWorkerDefaultStartupTimeoutMs)
                                                              terminationTimeoutMs:EJSWorkerUnsignedLimit(limits[@"terminationTimeoutMs"], EJSWorkerDefaultTerminationTimeoutMs)];

    return [[EJSWorkerSourcePolicy alloc] initWithDefaultRoot:defaultRoot
                                                        roots:roots
                                                      scripts:scripts
                                                 inlineScripts:inlineScripts
                                            allowAbsolutePath:EJSWorkerBoolValue(pathPolicy[@"allowAbsolutePath"], NO)
                                         allowParentTraversal:EJSWorkerBoolValue(pathPolicy[@"allowParentTraversal"], NO)
                                           allowSymlinkEscape:EJSWorkerBoolValue(pathPolicy[@"allowSymlinkEscape"], NO)
                                                       limits:resolvedLimits];
}

static NSString * EJSWorkerScopeDescription(NSString *workerID, NSString *name, NSString *specifier) {
    NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] init];
    if (workerID.length > 0u) {
        [parts addObject:[NSString stringWithFormat:@"workerID=%@", workerID]];
    }
    if (name.length > 0u) {
        [parts addObject:[NSString stringWithFormat:@"name=%@", name]];
    }
    if (specifier.length > 0u) {
        [parts addObject:[NSString stringWithFormat:@"specifier=%@", specifier]];
    }
    return parts.count > 0u ? [NSString stringWithFormat:@" [%@]", [parts componentsJoinedByString:@", "]] : @"";
}

static NSError * EJSWorkerScopedError(EJSProviderErrorCode code,
                                      NSString *message,
                                      NSString *workerID,
                                      NSString *name,
                                      NSString *specifier) {
    NSString *scoped = [NSString stringWithFormat:@"%@%@",
                        message.length > 0u ? message : @"Worker provider failed",
                        EJSWorkerScopeDescription(workerID, name, specifier)];
    return EJSWorkerProviderError(code, scoped);
}

static NSString * EJSWorkerBundledSourceByName(NSString *name, NSError **error) {
    for (size_t i = 0u; i < ejs_worker_scripts_count; ++i) {
        const EJSWorkerBundledScript *script = &ejs_worker_scripts[i];
        NSString *scriptName = [NSString stringWithUTF8String:script->name];
        if (![scriptName isEqualToString:name]) {
            continue;
        }
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        if (source == nil) {
            if (error != NULL) {
                *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Worker bundled script must be valid UTF-8");
            }
            return nil;
        }
        return source;
    }

    if (error != NULL) {
        *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInternal,
                                       [NSString stringWithFormat:@"Missing bundled worker script '%@'", name]);
    }
    return nil;
}

@implementation EJSWorkerChildProvider

- (instancetype)initWithOwnerProvider:(EJSWorkerAppleProvider *)ownerProvider instance:(EJSWorkerInstance *)instance {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.worker";
        _ownerProvider = ownerProvider;
        _instance = instance;
    }
    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;

    EJSWorkerAppleProvider *ownerProvider = self.ownerProvider;
    EJSWorkerInstance *instance = self.instance;
    if (ownerProvider == nil || instance == nil) {
        [responder finishWithData:nil
                            error:EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"worker parent provider is unavailable")];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"postMessage"]) {
        NSError *parseError = nil;
        NSDictionary *request = EJSWorkerJSONObjectFromData(payload, &parseError);
        if (request == nil) {
            [responder finishWithData:nil error:parseError];
            return [[EJSImmediateOperation alloc] init];
        }
        NSDictionary *envelope = [request[@"envelope"] isKindOfClass:[NSDictionary class]] ? request[@"envelope"] : nil;
        if (envelope == nil) {
            [responder finishWithData:nil error:EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"worker envelope is required")];
            return [[EJSImmediateOperation alloc] init];
        }
        NSError *error = nil;
        NSData *result = [ownerProvider enqueueMessageFromChildForInstance:instance
                                                                   envelope:envelope
                                                             transferBuffer:transferBuffer
                                                                      error:&error];
        [responder finishWithData:result error:error];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"takeMessage"]) {
        NSError *parseError = nil;
        NSDictionary *request = EJSWorkerJSONObjectFromData(payload, &parseError);
        if (request == nil) {
            [responder finishWithData:nil error:parseError];
            return [[EJSImmediateOperation alloc] init];
        }
        NSError *error = nil;
        NSData *result = [ownerProvider takeMessageForChildInstance:instance request:request error:&error];
        [responder finishWithData:result error:error];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"close"]) {
        NSError *error = nil;
        NSData *result = [ownerProvider closeFromChildForInstance:instance error:&error];
        [responder finishWithData:result error:error];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"reportError"]) {
        NSError *parseError = nil;
        NSDictionary *request = EJSWorkerJSONObjectFromData(payload, &parseError);
        if (request == nil) {
            [responder finishWithData:nil error:parseError];
            return [[EJSImmediateOperation alloc] init];
        }
        NSError *error = nil;
        NSData *result = [ownerProvider reportErrorFromChildForInstance:instance payload:request error:&error];
        [responder finishWithData:result error:error];
        return [[EJSImmediateOperation alloc] init];
    }

    [responder finishWithData:nil error:EJSWorkerProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.worker child method")];
    return [[EJSImmediateOperation alloc] init];
}

@end

@implementation EJSWorkerAppleProvider {
    __weak EJSContext *_context;
    EJSWorkerSourcePolicy *_policy;
    EJSWorkerInstallOptions *_installOptions;
    NSMutableDictionary<NSString *, EJSWorkerInstance *> *_workers;
    unsigned long long _nextWorkerID;
    NSLock *_stateLock;
    dispatch_queue_t _parentDispatchQueue;
}

- (instancetype)initWithContext:(EJSContext *)context
                         policy:(EJSWorkerSourcePolicy *)policy
                 installOptions:(EJSWorkerInstallOptions *)installOptions {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.worker";
        _context = context;
        _policy = policy;
        _installOptions = [installOptions copy];
        _workers = [[NSMutableDictionary alloc] init];
        _nextWorkerID = 1ull;
        _stateLock = [[NSLock alloc] init];
        _parentDispatchQueue = dispatch_queue_create("dev.ejs.worker.parent.dispatch", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [_stateLock lock];
    NSArray<EJSWorkerInstance *> *instances = _workers.allValues;
    [_workers removeAllObjects];
    [_stateLock unlock];

    for (EJSWorkerInstance *instance in instances) {
        [instance.context invalidate];
        [instance.runtime invalidate];
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    if (![methodID isEqualToString:@"create"] &&
        ![methodID isEqualToString:@"start"] &&
        ![methodID isEqualToString:@"postMessage"] &&
        ![methodID isEqualToString:@"takeMessage"] &&
        ![methodID isEqualToString:@"terminate"]) {
        [responder finishWithData:nil error:EJSWorkerProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.worker method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSWorkerJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *error = nil;
    NSData *result = nil;
    if ([methodID isEqualToString:@"create"]) {
        result = [self createWorkerWithRequest:request parentContext:context error:&error];
    } else if ([methodID isEqualToString:@"start"]) {
        return [self startWorkerWithRequest:request responder:responder];
    } else if ([methodID isEqualToString:@"postMessage"]) {
        result = [self postMessageWithRequest:request transferBuffer:transferBuffer error:&error];
    } else if ([methodID isEqualToString:@"takeMessage"]) {
        result = [self takeMessageForParentWithRequest:request error:&error];
    } else {
        result = [self terminateWorkerWithRequest:request error:&error];
    }
    [responder finishWithData:result error:error];
    return [[EJSImmediateOperation alloc] init];
}

- (NSString *)nextWorkerID {
    return [NSString stringWithFormat:@"%llu", _nextWorkerID++];
}

- (NSString *)nextMessageIDForInstance:(EJSWorkerInstance *)instance {
    NSString *messageID = [NSString stringWithFormat:@"%llu", instance.nextMessageID];
    instance.nextMessageID += 1ull;
    return messageID;
}

- (BOOL)dispatchMessageToContext:(EJSContext *)targetContext
                           queue:(dispatch_queue_t)queue
                        workerID:(NSString *)workerID
                       messageID:(NSString *)messageID
                 cleanupOnFailure:(dispatch_block_t)cleanupOnFailure
                           error:(NSError **)error {
    if (targetContext == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"Worker target context is unavailable");
        }
        return NO;
    }
    if (queue == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"Worker target queue is unavailable");
        }
        return NO;
    }

    NSArray *args = @[ workerID ?: @"", messageID ?: @"" ];
    NSData *json = [NSJSONSerialization dataWithJSONObject:args options:0 error:error];
    if (json == nil) {
        if (error != NULL && *error == nil) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInternal, @"Failed to encode worker dispatch arguments");
        }
        return NO;
    }

    NSString *jsonArgs = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (jsonArgs.length == 0u) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInternal, @"Failed to decode worker dispatch arguments");
        }
        return NO;
    }

    NSString *script = [NSString stringWithFormat:@"globalThis.__EJSWorkerDispatch && globalThis.__EJSWorkerDispatch.apply(null, %@);", jsonArgs];
    EJSContext *context = targetContext;
    NSString *dispatchScript = [script copy];
    dispatch_block_t cleanup = [cleanupOnFailure copy];
    dispatch_async(queue, ^{
        NSError *dispatchError = nil;
        if (![context evaluateScript:dispatchScript filename:@"ejs_worker_dispatch.js" error:&dispatchError]) {
            if (cleanup != nil) {
                cleanup();
            }
        }
    });
    return YES;
}

- (void)invalidateInstanceWhenIdle:(EJSWorkerInstance *)instance {
    if (instance == nil) {
        return;
    }
    dispatch_async(instance.dispatchQueue, ^{
        [instance.context invalidate];
        [instance.runtime invalidate];
    });
}

- (NSDictionary *)resolvedSourceForSpecifier:(NSString *)specifier
                                     options:(NSDictionary *)options
                                       error:(NSError **)error {
    NSString *requestedRoot = [options[@"root"] isKindOfClass:[NSString class]] ? options[@"root"] : nil;
    NSString *requestedType = [options[@"type"] isKindOfClass:[NSString class]] ? options[@"type"] : nil;
    if (requestedType != nil && ![requestedType isEqualToString:@"classic"] && ![requestedType isEqualToString:@"module"]) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported worker type");
        }
        return nil;
    }

    EJSWorkerScriptPolicy *scriptPolicy = _policy.scripts[specifier];
    EJSWorkerInlineScriptPolicy *inlinePolicy = _policy.inlineScripts[specifier];
    NSString *resolvedType = requestedType ?: @"classic";
    NSString *resolvedRootName = requestedRoot ?: _policy.defaultRoot;
    NSString *resolvedPath = specifier;
    NSString *source = nil;
    NSString *filename = nil;

    if (scriptPolicy != nil) {
        resolvedRootName = scriptPolicy.root;
        resolvedPath = scriptPolicy.path;
        resolvedType = scriptPolicy.type;
    } else if (inlinePolicy != nil) {
        resolvedType = inlinePolicy.type;
        source = inlinePolicy.source;
        filename = [NSString stringWithFormat:@"ejs-worker:inline/%@", inlinePolicy.name];
    }

    if (![resolvedType isEqualToString:@"classic"] && ![resolvedType isEqualToString:@"module"]) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported worker type");
        }
        return nil;
    }

    if (source == nil) {
        if (EJSWorkerSpecifierLooksLikeURLScheme(resolvedPath)) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeUnsupported, @"Worker URL scheme is not supported");
            }
            return nil;
        }

        EJSWorkerRootPolicy *rootPolicy = _policy.roots[resolvedRootName];
        if (rootPolicy == nil || !rootPolicy.canRead) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeSecurity, @"Worker root is not allowed");
            }
            return nil;
        }

        if (resolvedPath.isAbsolutePath && !_policy.allowAbsolutePath) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeSecurity, @"Absolute worker paths are not allowed");
            }
            return nil;
        }

        if (!_policy.allowParentTraversal && EJSWorkerPathHasParentTraversal(resolvedPath)) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeSecurity, @"Parent traversal is not allowed");
            }
            return nil;
        }

        NSString *targetPath = resolvedPath.isAbsolutePath ? resolvedPath : [rootPolicy.path stringByAppendingPathComponent:resolvedPath];
        targetPath = [targetPath stringByStandardizingPath];

        NSString *rootCheckPath = _policy.allowSymlinkEscape ? rootPolicy.path.stringByStandardizingPath : rootPolicy.path.stringByResolvingSymlinksInPath;
        NSString *targetCheckPath = nil;
        if (_policy.allowSymlinkEscape) {
            targetCheckPath = targetPath;
        } else {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            BOOL targetExists = [fileManager fileExistsAtPath:targetPath];
            BOOL targetIsSymlink = [fileManager destinationOfSymbolicLinkAtPath:targetPath error:nil] != nil;
            if (targetExists || targetIsSymlink) {
                targetCheckPath = [targetPath stringByResolvingSymlinksInPath];
            } else {
                NSString *parentPath = [targetPath stringByDeletingLastPathComponent];
                NSString *resolvedParent = [parentPath stringByResolvingSymlinksInPath];
                targetCheckPath = [resolvedParent stringByAppendingPathComponent:targetPath.lastPathComponent];
            }
        }

        if (!EJSWorkerPathIsInsideRoot(targetCheckPath, rootCheckPath)) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeSecurity, @"Resolved worker path escapes its root");
            }
            return nil;
        }

        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:targetPath options:0 error:&readError];
        if (data == nil) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument,
                                                readError.localizedDescription ?: @"Failed to read worker source");
            }
            return nil;
        }

        if (data.length > _policy.limits.maxSourceBytes) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeSecurity, @"Worker source exceeds maxSourceBytes");
            }
            return nil;
        }

        source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (source == nil) {
            if (error != NULL) {
                *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker source must be valid UTF-8");
            }
            return nil;
        }

        filename = [NSString stringWithFormat:@"ejs-worker://%@/%@", resolvedRootName, resolvedPath];
    }

    NSUInteger sourceLength = [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (sourceLength > _policy.limits.maxSourceBytes) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeSecurity, @"Worker source exceeds maxSourceBytes");
        }
        return nil;
    }

    return @{
        @"source": source,
        @"type": resolvedType,
        @"filename": filename ?: @"ejs-worker://unknown"
    };
}

- (NSData *)createWorkerWithRequest:(NSDictionary *)request
                      parentContext:(EJSContext *)parentContext
                              error:(NSError **)error {
    NSString *specifier = [request[@"specifier"] isKindOfClass:[NSString class]] ? request[@"specifier"] : nil;
    NSDictionary *options = [request[@"options"] isKindOfClass:[NSDictionary class]] ? request[@"options"] : @{};
    NSString *name = [options[@"name"] isKindOfClass:[NSString class]] ? options[@"name"] : @"";
    if (!EJSWorkerStringIsNonEmpty(specifier)) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker specifier must be a non-empty string");
        }
        return nil;
    }

    NSDictionary *resolved = [self resolvedSourceForSpecifier:specifier options:options error:error];
    if (resolved == nil) {
        return nil;
    }

    [_stateLock lock];
    if (_workers.count >= _policy.limits.maxWorkers) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeSecurity,
                                          @"Worker count exceeds maxWorkers",
                                          @"",
                                          name,
                                          specifier);
        }
        return nil;
    }
    NSString *workerID = [self nextWorkerID];
    [_stateLock unlock];

    EJSRuntimeConfiguration *runtimeConfiguration = [[EJSRuntimeConfiguration alloc] init];
    NSString *workerConfig = [parentContext configurationValueForKey:EJSWorkerConfigurationKey];
    if (workerConfig.length > 0u) {
        runtimeConfiguration.contextDefaults = @{ EJSWorkerConfigurationKey: workerConfig };
    }
    EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:runtimeConfiguration];
    EJSContextConfiguration *contextConfiguration = [[EJSContextConfiguration alloc] init];
    if (workerConfig.length > 0u) {
        contextConfiguration.values = @{ EJSWorkerConfigurationKey: workerConfig };
    }
    EJSContext *childContext = [runtime createContextWithID:[NSString stringWithFormat:@"ejs://worker/%@", workerID]
                                               configuration:contextConfiguration
                                                       error:error];
    if (childContext == nil) {
        [runtime invalidate];
        return nil;
    }

    EJSWorkerInstance *instance = [[EJSWorkerInstance alloc] initWithWorkerID:workerID
                                                                          name:name ?: @""
                                                                     specifier:specifier
                                                                       runtime:runtime
                                                                       context:childContext];
    instance.ownerProvider = self;

    EJSWorkerChildProvider *childProvider = [[EJSWorkerChildProvider alloc] initWithOwnerProvider:self instance:instance];
    if (![childContext registerProvider:childProvider error:error]) {
        [childContext invalidate];
        [runtime invalidate];
        return nil;
    }

    if (_installOptions.installWorkerContext != nil) {
        NSError *installError = nil;
        if (!_installOptions.installWorkerContext(childContext, &installError)) {
            if (error != NULL) {
                *error = installError ?: EJSWorkerScopedError(EJSProviderErrorCodeInternal,
                                                              @"installWorkerContext callback failed",
                                                              workerID,
                                                              name,
                                                              specifier);
            }
            [childContext invalidate];
            [runtime invalidate];
            return nil;
        }
    }

    NSString *childWrapperSource = EJSWorkerBundledSourceByName(@"js/worker_child.js", error);
    if (childWrapperSource == nil ||
        ![childContext evaluateScript:childWrapperSource filename:@"js/worker_child.js" error:error]) {
        [childContext invalidate];
        [runtime invalidate];
        return nil;
    }

    NSDictionary *bootstrapPayload = @{
        @"workerID": workerID,
        @"specifier": specifier,
        @"name": name ?: @"",
        @"maxQueuedMessages": @(_policy.limits.maxQueuedMessages),
        @"maxMessageBytes": @(_policy.limits.maxMessageBytes)
    };
    NSData *bootstrapJSON = [NSJSONSerialization dataWithJSONObject:bootstrapPayload options:0 error:error];
    if (bootstrapJSON == nil) {
        [childContext invalidate];
        [runtime invalidate];
        return nil;
    }

    NSString *bootstrapString = [[NSString alloc] initWithData:bootstrapJSON encoding:NSUTF8StringEncoding];
    NSString *bootstrapScript =
        [NSString stringWithFormat:@"globalThis.__EJSWorkerBootstrap && globalThis.__EJSWorkerBootstrap(%@);",
                                   bootstrapString ?: @"{}"];
    if (![childContext evaluateScript:bootstrapScript filename:@"ejs_worker_bootstrap.js" error:error]) {
        [childContext invalidate];
        [runtime invalidate];
        return nil;
    }

    NSString *source = resolved[@"source"];
    NSString *type = resolved[@"type"];
    NSString *filename = resolved[@"filename"];
    instance.startupSource = source ?: @"";
    instance.startupType = type ?: @"classic";
    instance.startupFilename = filename ?: @"ejs-worker://unknown";

    [_stateLock lock];
    _workers[workerID] = instance;
    [_stateLock unlock];

    return EJSWorkerJSONData(@{
        @"workerID": workerID,
        @"name": name ?: @"",
        @"specifier": specifier,
        @"maxQueuedMessages": @(_policy.limits.maxQueuedMessages)
    }, error);
}

- (id<EJSProviderOperation>)startWorkerWithRequest:(NSDictionary *)request
                                         responder:(EJSProviderResponder *)responder {
    NSString *workerID = [request[@"workerID"] isKindOfClass:[NSString class]] ? request[@"workerID"] : nil;
    if (!EJSWorkerStringIsNonEmpty(workerID)) {
        [responder finishWithData:nil error:EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker start requires workerID")];
        return [[EJSImmediateOperation alloc] init];
    }

    [_stateLock lock];
    EJSWorkerInstance *instance = [self workerForID:workerID];
    if (instance == nil) {
        [_stateLock unlock];
        [responder finishWithData:nil
                            error:EJSWorkerScopedError(EJSProviderErrorCodeAborted,
                                                       @"Worker is not running",
                                                       workerID,
                                                       @"",
                                                       @"")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *name = instance.name;
    NSString *specifier = instance.specifier;
    if (instance.state == EJSWorkerInstanceStateTerminating ||
        instance.state == EJSWorkerInstanceStateTerminated) {
        [_stateLock unlock];
        [responder finishWithData:EJSWorkerJSONData(@{ @"started": @NO, @"workerID": workerID }, nil) error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    if (instance.startupStarted) {
        [_stateLock unlock];
        [responder finishWithData:EJSWorkerJSONData(@{ @"started": @YES, @"workerID": workerID }, nil) error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    instance.startupStarted = YES;
    instance.state = EJSWorkerInstanceStateRunning;
    NSString *source = [instance.startupSource copy];
    NSString *type = [instance.startupType copy];
    NSString *filename = [instance.startupFilename copy];
    EJSContext *childContext = instance.context;
    dispatch_queue_t workerQueue = instance.dispatchQueue;
    [_stateLock unlock];

    if (source.length == 0u) {
        [_stateLock lock];
        EJSWorkerInstance *current = [self workerForID:workerID];
        if (current == instance) {
            instance.state = EJSWorkerInstanceStateTerminated;
            [instance.parentInbox removeAllObjects];
            [instance.childInbox removeAllObjects];
            [_workers removeObjectForKey:workerID];
        }
        [_stateLock unlock];
        [self invalidateInstanceWhenIdle:instance];
        [responder finishWithData:nil
                            error:EJSWorkerScopedError(EJSProviderErrorCodeInternal,
                                                       @"Worker source is missing",
                                                       workerID,
                                                       name,
                                                       specifier)];
        return [[EJSImmediateOperation alloc] init];
    }

    __block BOOL cancelled = NO;
    EJSProviderResponder *heldResponder = responder;
    EJSBlockOperation *operation = [[EJSBlockOperation alloc] initWithCancelBlock:^{
        cancelled = YES;
        [_stateLock lock];
        EJSWorkerInstance *current = [self workerForID:workerID];
        if (current == instance) {
            instance.state = EJSWorkerInstanceStateTerminated;
            [instance.parentInbox removeAllObjects];
            [instance.childInbox removeAllObjects];
            [_workers removeObjectForKey:workerID];
        }
        [_stateLock unlock];
        [instance.runtime requestInterrupt];
        [self invalidateInstanceWhenIdle:instance];
        [heldResponder finishWithData:nil
                                error:EJSWorkerScopedError(EJSProviderErrorCodeAborted,
                                                           @"Worker start was cancelled",
                                                           workerID,
                                                           name,
                                                           specifier)];
    }];

    dispatch_async(workerQueue, ^{
        if (cancelled) {
            return;
        }

        NSError *evalError = nil;
        BOOL didEvaluate = NO;
        if ([type isEqualToString:@"module"]) {
            didEvaluate = [childContext evaluateModule:source
                                             specifier:specifier
                                             sourceURL:filename
                                                 error:&evalError];
        } else {
            didEvaluate = [childContext evaluateScript:source filename:filename error:&evalError];
        }

        if (!didEvaluate) {
            [_stateLock lock];
            EJSWorkerInstance *current = [self workerForID:workerID];
            if (current == instance) {
                instance.state = EJSWorkerInstanceStateTerminated;
                [instance.parentInbox removeAllObjects];
                [instance.childInbox removeAllObjects];
                [_workers removeObjectForKey:workerID];
            }
            [_stateLock unlock];

            [self invalidateInstanceWhenIdle:instance];
            [heldResponder finishWithData:nil
                                    error:evalError ?: EJSWorkerScopedError(EJSProviderErrorCodeInternal,
                                                                            @"Worker startup failed",
                                                                            workerID,
                                                                            name,
                                                                            specifier)];
            return;
        }

        NSError *jsonError = nil;
        NSData *data = EJSWorkerJSONData(@{ @"started": @YES, @"workerID": workerID }, &jsonError);
        [heldResponder finishWithData:data error:jsonError];
    });

    return operation;
}

- (EJSWorkerInstance *)workerForID:(NSString *)workerID {
    if (!EJSWorkerStringIsNonEmpty(workerID)) {
        return nil;
    }
    return _workers[workerID];
}

- (NSData *)postMessageWithRequest:(NSDictionary *)request
                    transferBuffer:(NSData *)transferBuffer
                             error:(NSError **)error {
    NSString *direction = [request[@"direction"] isKindOfClass:[NSString class]] ? request[@"direction"] : nil;
    if (![direction isEqualToString:@"toChild"]) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker postMessage requires direction=toChild");
        }
        return nil;
    }

    NSString *workerID = [request[@"workerID"] isKindOfClass:[NSString class]] ? request[@"workerID"] : nil;
    NSDictionary *envelope = [request[@"envelope"] isKindOfClass:[NSDictionary class]] ? request[@"envelope"] : nil;
    if (!EJSWorkerStringIsNonEmpty(workerID) || envelope == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker postMessage requires workerID and envelope");
        }
        return nil;
    }

    [_stateLock lock];
    EJSWorkerInstance *instance = [self workerForID:workerID];
    if (instance == nil) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeAborted,
                                          @"Worker is not running",
                                          workerID,
                                          @"",
                                          @"");
        }
        return nil;
    }
    NSString *name = instance.name;
    NSString *specifier = instance.specifier;
    if (instance.state != EJSWorkerInstanceStateRunning) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeAborted,
                                          @"Worker is not running",
                                          workerID,
                                          name,
                                          specifier);
        }
        return nil;
    }

    NSData *frame = EJSWorkerMessageFrameData(envelope, transferBuffer ?: [NSData data], error);
    if (frame == nil) {
        [_stateLock unlock];
        return nil;
    }
    if (frame.length > _policy.limits.maxMessageBytes) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeSecurity,
                                          @"Worker message exceeds maxMessageBytes",
                                          workerID,
                                          name,
                                          specifier);
        }
        return nil;
    }
    if (instance.childInbox.count >= _policy.limits.maxQueuedMessages) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeSecurity,
                                          @"Worker child queue exceeds maxQueuedMessages",
                                          workerID,
                                          name,
                                          specifier);
        }
        return nil;
    }

    NSString *messageID = [self nextMessageIDForInstance:instance];
    instance.childInbox[messageID] = frame;
    EJSContext *childContext = instance.context;
    [_stateLock unlock];

    dispatch_block_t cleanup = ^{
        [_stateLock lock];
        [instance.childInbox removeObjectForKey:messageID];
        [_stateLock unlock];
    };
    if (![self dispatchMessageToContext:childContext
                                  queue:instance.dispatchQueue
                               workerID:workerID
                              messageID:messageID
                       cleanupOnFailure:cleanup
                                  error:error]) {
        cleanup();
        return nil;
    }

    return EJSWorkerJSONData(@{ @"messageID": messageID }, error);
}

- (NSData *)takeMessageForParentWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *direction = [request[@"direction"] isKindOfClass:[NSString class]] ? request[@"direction"] : nil;
    if (![direction isEqualToString:@"toParent"]) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker takeMessage requires direction=toParent");
        }
        return nil;
    }
    NSString *workerID = [request[@"workerID"] isKindOfClass:[NSString class]] ? request[@"workerID"] : nil;
    NSString *messageID = [request[@"messageID"] isKindOfClass:[NSString class]] ? request[@"messageID"] : nil;
    if (!EJSWorkerStringIsNonEmpty(workerID) || !EJSWorkerStringIsNonEmpty(messageID)) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker takeMessage requires workerID and messageID");
        }
        return nil;
    }

    [_stateLock lock];
    EJSWorkerInstance *instance = [self workerForID:workerID];
    if (instance == nil) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeInvalidArgument,
                                          @"Worker message is missing",
                                          workerID,
                                          @"",
                                          @"");
        }
        return nil;
    }
    NSString *name = instance.name;
    NSString *specifier = instance.specifier;
    NSData *frame = instance.parentInbox[messageID];
    BOOL shouldInvalidate = NO;
    if (frame != nil) {
        [instance.parentInbox removeObjectForKey:messageID];
        if ([messageID isEqualToString:instance.terminationNotificationMessageID]) {
            instance.state = EJSWorkerInstanceStateTerminated;
            [instance.parentInbox removeAllObjects];
            [instance.childInbox removeAllObjects];
            [_workers removeObjectForKey:workerID];
            shouldInvalidate = YES;
        }
    }
    [_stateLock unlock];

    if (shouldInvalidate) {
        [self invalidateInstanceWhenIdle:instance];
    }

    if (frame == nil) {
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeInvalidArgument,
                                          @"Worker message is missing",
                                          workerID,
                                          name,
                                          specifier);
        }
        return nil;
    }
    return frame;
}

- (NSData *)terminateWorkerWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *workerID = [request[@"workerID"] isKindOfClass:[NSString class]] ? request[@"workerID"] : nil;
    if (!EJSWorkerStringIsNonEmpty(workerID)) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker terminate requires workerID");
        }
        return nil;
    }

    EJSWorkerInstance *instance = nil;
    [_stateLock lock];
    instance = [self workerForID:workerID];
    if (instance != nil) {
        instance.state = EJSWorkerInstanceStateTerminating;
        [instance.parentInbox removeAllObjects];
        [instance.childInbox removeAllObjects];
        [_workers removeObjectForKey:workerID];
    }
    [_stateLock unlock];

    if (instance != nil) {
        [instance.runtime requestInterrupt];
        [self invalidateInstanceWhenIdle:instance];
        instance.state = EJSWorkerInstanceStateTerminated;
    }

    return EJSWorkerJSONData(@{ @"terminated": @YES, @"workerID": workerID }, error);
}

- (NSData *)enqueueMessageFromChildForInstance:(EJSWorkerInstance *)instance
                                      envelope:(NSDictionary *)envelope
                                transferBuffer:(NSData *)transferBuffer
                                         error:(NSError **)error {
    if (instance == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"Worker instance is unavailable");
        }
        return nil;
    }

    NSData *frame = EJSWorkerMessageFrameData(envelope, transferBuffer ?: [NSData data], error);
    if (frame == nil) {
        return nil;
    }
    if (frame.length > _policy.limits.maxMessageBytes) {
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeSecurity,
                                          @"Worker message exceeds maxMessageBytes",
                                          instance.workerID,
                                          instance.name,
                                          instance.specifier);
        }
        return nil;
    }

    NSString *messageID = nil;
    EJSContext *parentContext = _context;
    [_stateLock lock];
    if (instance.state != EJSWorkerInstanceStateRunning) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeAborted,
                                          @"Worker is not running",
                                          instance.workerID,
                                          instance.name,
                                          instance.specifier);
        }
        return nil;
    }
    if (instance.parentInbox.count >= _policy.limits.maxQueuedMessages) {
        [_stateLock unlock];
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeSecurity,
                                          @"Worker parent queue exceeds maxQueuedMessages",
                                          instance.workerID,
                                          instance.name,
                                          instance.specifier);
        }
        return nil;
    }
    messageID = [self nextMessageIDForInstance:instance];
    instance.parentInbox[messageID] = frame;
    [_stateLock unlock];

    dispatch_block_t cleanup = ^{
        [_stateLock lock];
        [instance.parentInbox removeObjectForKey:messageID];
        [_stateLock unlock];
    };
    if (![self dispatchMessageToContext:parentContext
                                  queue:_parentDispatchQueue
                               workerID:instance.workerID
                              messageID:messageID
                       cleanupOnFailure:cleanup
                                  error:error]) {
        cleanup();
        return nil;
    }

    return EJSWorkerJSONData(@{ @"messageID": messageID }, error);
}

- (NSData *)takeMessageForChildInstance:(EJSWorkerInstance *)instance
                                request:(NSDictionary *)request
                                  error:(NSError **)error {
    if (instance == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"Worker instance is unavailable");
        }
        return nil;
    }
    NSString *messageID = [request[@"messageID"] isKindOfClass:[NSString class]] ? request[@"messageID"] : nil;
    if (!EJSWorkerStringIsNonEmpty(messageID)) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeInvalidArgument, @"Worker takeMessage requires messageID");
        }
        return nil;
    }

    [_stateLock lock];
    NSData *frame = instance.childInbox[messageID];
    if (frame != nil) {
        [instance.childInbox removeObjectForKey:messageID];
    }
    [_stateLock unlock];

    if (frame == nil) {
        if (error != NULL) {
            *error = EJSWorkerScopedError(EJSProviderErrorCodeInvalidArgument,
                                          @"Worker child message is missing",
                                          instance.workerID,
                                          instance.name,
                                          instance.specifier);
        }
        return nil;
    }
    return frame;
}

- (NSData *)closeFromChildForInstance:(EJSWorkerInstance *)instance error:(NSError **)error {
    if (instance == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"Worker instance is unavailable");
        }
        return nil;
    }

    NSDictionary *envelope = @{ @"kind": @"close" };
    NSData *frame = EJSWorkerMessageFrameData(envelope, nil, error);
    if (frame == nil) {
        return nil;
    }

    NSString *workerID = instance.workerID;
    NSString *messageID = nil;
    EJSContext *parentContext = _context;

    [_stateLock lock];
    if (instance.state == EJSWorkerInstanceStateTerminated) {
        [_stateLock unlock];
        return EJSWorkerJSONData(@{ @"closed": @YES, @"workerID": workerID ?: @"" }, error);
    }
    if (instance.state == EJSWorkerInstanceStateTerminating &&
        instance.terminationNotificationMessageID.length > 0u) {
        [_stateLock unlock];
        return EJSWorkerJSONData(@{ @"closed": @YES, @"workerID": workerID ?: @"" }, error);
    }
    instance.state = EJSWorkerInstanceStateTerminating;
    [instance.childInbox removeAllObjects];
    messageID = [self nextMessageIDForInstance:instance];
    instance.terminationNotificationMessageID = messageID;
    instance.parentInbox[messageID] = frame;
    [_stateLock unlock];

    dispatch_block_t cleanup = ^{
        [_stateLock lock];
        [instance.parentInbox removeObjectForKey:messageID];
        [_workers removeObjectForKey:workerID];
        instance.state = EJSWorkerInstanceStateTerminated;
        [_stateLock unlock];
        [self invalidateInstanceWhenIdle:instance];
    };
    NSError *dispatchError = nil;
    if (![self dispatchMessageToContext:parentContext
                                  queue:_parentDispatchQueue
                               workerID:workerID
                              messageID:messageID
                       cleanupOnFailure:cleanup
                                  error:&dispatchError]) {
        cleanup();
    }

    return EJSWorkerJSONData(@{ @"closed": @YES, @"workerID": workerID ?: @"" }, error);
}

- (NSData *)reportErrorFromChildForInstance:(EJSWorkerInstance *)instance
                                     payload:(NSDictionary *)request
                                       error:(NSError **)error {
    if (instance == nil) {
        if (error != NULL) {
            *error = EJSWorkerProviderError(EJSProviderErrorCodeAborted, @"Worker instance is unavailable");
        }
        return nil;
    }
    NSString *message = [request[@"message"] isKindOfClass:[NSString class]] ? request[@"message"] : @"Worker error";
    NSString *filename = [request[@"filename"] isKindOfClass:[NSString class]] ? request[@"filename"] : @"";
    NSString *stack = [request[@"stack"] isKindOfClass:[NSString class]] ? request[@"stack"] : @"";
    NSString *errorString = [request[@"error"] isKindOfClass:[NSString class]] ? request[@"error"] : @"";

    NSDictionary *envelope = @{
        @"kind": @"error",
        @"error": @{
            @"message": message ?: @"Worker error",
            @"filename": filename ?: @"",
            @"stack": stack ?: @"",
            @"error": errorString ?: @""
        }
    };
    return [self enqueueMessageFromChildForInstance:instance envelope:envelope transferBuffer:nil error:error];
}

#ifdef EJS_TEST

static BOOL EJSWorkerTestFail(NSError **error, NSString *message);

- (EJSWorkerInstance *)testInstanceWithWorkerID:(NSString *)workerID
                                           name:(NSString *)name
                                      specifier:(NSString *)specifier
                                         source:(NSString *)source
                                           type:(NSString *)type
                                          error:(NSError **)error {
    EJSRuntime *runtime = [[EJSRuntime alloc] init];
    EJSContext *context = [runtime createContextWithID:[NSString stringWithFormat:@"ejs://worker-test/%@", workerID ?: @"unknown"]
                                                 error:error];
    if (context == nil) {
        [runtime invalidate];
        return nil;
    }

    EJSWorkerInstance *instance = [[EJSWorkerInstance alloc] initWithWorkerID:workerID
                                                                          name:name ?: @""
                                                                     specifier:specifier ?: @"test"
                                                                       runtime:runtime
                                                                       context:context];
    instance.ownerProvider = self;
    instance.startupSource = source ?: @"";
    instance.startupType = type ?: @"classic";
    instance.startupFilename = [NSString stringWithFormat:@"ejs-worker://test/%@", workerID ?: @"unknown"];
    return instance;
}

- (void)testStoreInstance:(EJSWorkerInstance *)instance {
    [_stateLock lock];
    _workers[instance.workerID] = instance;
    [_stateLock unlock];
}

- (void)testRemoveInstance:(EJSWorkerInstance *)instance {
    [_stateLock lock];
    [_workers removeObjectForKey:instance.workerID];
    [_stateLock unlock];
}

- (BOOL)runInternalStateCoverageWithRootPath:(NSString *)rootPath error:(NSError **)error {
    (void)rootPath;

    NSError *localError = nil;
    (void)EJSWorkerRuntimeError(EJSRuntimeErrorCodeInternal, @"");
    (void)EJSWorkerProviderError(EJSProviderErrorCodeInternal, nil);
    (void)EJSWorkerScopedError(EJSProviderErrorCodeInternal, @"scoped", @"worker", @"named", @"specifier");
    (void)EJSWorkerBundledSourceByName(@"js/missing_worker_bundle.js", &localError);
    (void)[self workerForID:nil];
    [self invalidateInstanceWhenIdle:nil];

    EJSWorkerInlineScriptPolicy *inlinePolicy = [[EJSWorkerInlineScriptPolicy alloc] initWithName:@"inline"
                                                                                           source:@"postMessage('too large');"
                                                                                             type:@"classic"];
    EJSWorkerScriptPolicy *badTypeScript = [[EJSWorkerScriptPolicy alloc] initWithName:@"bad-type"
                                                                                  root:@"app"
                                                                                  path:@"workers/internal_ok.js"
                                                                                  type:@"shared"];
    EJSWorkerRootPolicy *rootPolicy = [[EJSWorkerRootPolicy alloc] initWithName:@"app"
                                                                           path:NSTemporaryDirectory()
                                                                        canRead:YES];
    EJSWorkerLimits *tinyLimits = [[EJSWorkerLimits alloc] initWithMaxWorkers:4
                                                            maxQueuedMessages:1
                                                              maxMessageBytes:8
                                                               maxSourceBytes:4
                                                             startupTimeoutMs:EJSWorkerDefaultStartupTimeoutMs
                                                         terminationTimeoutMs:EJSWorkerDefaultTerminationTimeoutMs];
    EJSWorkerSourcePolicy *tinyPolicy = [[EJSWorkerSourcePolicy alloc] initWithDefaultRoot:@"app"
                                                                                     roots:@{ @"app": rootPolicy }
                                                                                   scripts:@{ @"bad-type": badTypeScript }
                                                                             inlineScripts:@{ @"inline": inlinePolicy }
                                                                        allowAbsolutePath:NO
                                                                     allowParentTraversal:NO
                                                                       allowSymlinkEscape:NO
                                                                                    limits:tinyLimits];
    EJSWorkerAppleProvider *tinyProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                    policy:tinyPolicy
                                                                            installOptions:nil];
    if ([tinyProvider resolvedSourceForSpecifier:@"bad-type" options:@{} error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"bad script type unexpectedly resolved");
    }
    if ([tinyProvider resolvedSourceForSpecifier:@"inline" options:@{} error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"oversized inline source unexpectedly resolved");
    }

    EJSWorkerLimits *maxWorkerLimits = [[EJSWorkerLimits alloc] initWithMaxWorkers:0
                                                                maxQueuedMessages:4
                                                                  maxMessageBytes:4096
                                                                   maxSourceBytes:4096
                                                                 startupTimeoutMs:EJSWorkerDefaultStartupTimeoutMs
                                                             terminationTimeoutMs:EJSWorkerDefaultTerminationTimeoutMs];
    EJSWorkerSourcePolicy *maxWorkerPolicy = [[EJSWorkerSourcePolicy alloc] initWithDefaultRoot:@"app"
                                                                                          roots:@{ @"app": rootPolicy }
                                                                                        scripts:@{}
                                                                                  inlineScripts:@{ @"inline": inlinePolicy }
                                                                             allowAbsolutePath:NO
                                                                          allowParentTraversal:NO
                                                                            allowSymlinkEscape:NO
                                                                                         limits:maxWorkerLimits];
    EJSWorkerAppleProvider *maxWorkerProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                         policy:maxWorkerPolicy
                                                                                 installOptions:nil];
    if ([maxWorkerProvider createWorkerWithRequest:@{ @"specifier": @"inline", @"options": @{ @"name": @"cap" } }
                                     parentContext:nil
                                             error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"maxWorkers branch unexpectedly created worker");
    }

    EJSWorkerInstallOptions *failingInstallOptions =
        [[EJSWorkerInstallOptions alloc] initWithInstallWorkerContext:^BOOL(EJSContext *workerContext, NSError **installError) {
            (void)workerContext;
            if (installError != NULL) {
                *installError = EJSWorkerProviderError(EJSProviderErrorCodeInternal, @"test install callback failed");
            }
            return NO;
        }];
    EJSWorkerLimits *roomyLimits = [[EJSWorkerLimits alloc] initWithMaxWorkers:4
                                                            maxQueuedMessages:4
                                                              maxMessageBytes:4096
                                                               maxSourceBytes:4096
                                                             startupTimeoutMs:EJSWorkerDefaultStartupTimeoutMs
                                                         terminationTimeoutMs:EJSWorkerDefaultTerminationTimeoutMs];
    EJSWorkerSourcePolicy *inlineCreatePolicy = [[EJSWorkerSourcePolicy alloc] initWithDefaultRoot:@"app"
                                                                                            roots:@{ @"app": rootPolicy }
                                                                                          scripts:@{}
                                                                                    inlineScripts:@{ @"inline": inlinePolicy }
                                                                               allowAbsolutePath:NO
                                                                            allowParentTraversal:NO
                                                                              allowSymlinkEscape:NO
                                                                                           limits:roomyLimits];
    EJSWorkerAppleProvider *installFailProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                           policy:inlineCreatePolicy
                                                                                   installOptions:failingInstallOptions];
    if ([installFailProvider createWorkerWithRequest:@{ @"specifier": @"inline" }
                                       parentContext:nil
                                               error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"install callback failure unexpectedly created worker");
    }
    EJSWorkerInstallOptions *bareFailingInstallOptions =
        [[EJSWorkerInstallOptions alloc] initWithInstallWorkerContext:^BOOL(EJSContext *workerContext, NSError **installError) {
            (void)workerContext;
            (void)installError;
            return NO;
        }];
    EJSWorkerAppleProvider *bareInstallFailProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                               policy:inlineCreatePolicy
                                                                                       installOptions:bareFailingInstallOptions];
    (void)[bareInstallFailProvider createWorkerWithRequest:@{ @"specifier": @"inline", @"options": @{ @"name": @"bare" } }
                                             parentContext:nil
                                                     error:&localError];

    EJSRuntime *dispatchRuntime = [[EJSRuntime alloc] init];
    EJSContext *dispatchContext = [dispatchRuntime createContextWithID:@"ejs://worker-test/dispatch-cleanup"
                                                                 error:&localError];
    if (dispatchContext == nil ||
        ![dispatchContext evaluateScript:@"globalThis.__EJSWorkerDispatch = {};"
                                filename:@"worker_dispatch_cleanup_setup.js"
                                   error:&localError]) {
        [dispatchRuntime invalidate];
        return EJSWorkerTestFail(error, localError.localizedDescription ?: @"failed to setup dispatch cleanup context");
    }
    dispatch_queue_t failingDispatchQueue = dispatch_queue_create("dev.ejs.worker.test.dispatch.cleanup", DISPATCH_QUEUE_SERIAL);
    __block BOOL dispatchCleanupRan = NO;
    if (![self dispatchMessageToContext:dispatchContext
                                  queue:failingDispatchQueue
                               workerID:@"cleanup"
                              messageID:@"message"
                       cleanupOnFailure:^{
                           dispatchCleanupRan = YES;
                       }
                                  error:&localError]) {
        [dispatchRuntime invalidate];
        return EJSWorkerTestFail(error, @"dispatch cleanup setup unexpectedly failed");
    }
    dispatch_sync(failingDispatchQueue, ^{});
    [dispatchContext invalidate];
    [dispatchRuntime invalidate];
    if (!dispatchCleanupRan) {
        return EJSWorkerTestFail(error, @"dispatch cleanup did not run");
    }

    EJSWorkerInstance *startingInstance = [self testInstanceWithWorkerID:@"synthetic-starting"
                                                                    name:@"state"
                                                               specifier:@"state"
                                                                  source:@""
                                                                    type:@"classic"
                                                                   error:&localError];
    EJSWorkerInstance *runningInstance = [self testInstanceWithWorkerID:@"synthetic-running"
                                                                   name:@"state"
                                                              specifier:@"state"
                                                                 source:@""
                                                                   type:@"classic"
                                                                  error:&localError];
    EJSWorkerInstance *moduleInstance = [self testInstanceWithWorkerID:@"synthetic-module"
                                                                  name:@"state"
                                                             specifier:@"state"
                                                                source:@"export const ok = true;"
                                                                  type:@"module"
                                                                 error:&localError];
    EJSWorkerInstance *syntaxErrorInstance = [self testInstanceWithWorkerID:@"synthetic-syntax"
                                                                       name:@"state"
                                                                  specifier:@"state"
                                                                     source:@"function ("
                                                                       type:@"classic"
                                                                      error:&localError];
    EJSWorkerInstance *cancelInstance = [self testInstanceWithWorkerID:@"synthetic-cancel"
                                                                  name:@"state"
                                                             specifier:@"state"
                                                                source:@"while (false) {}"
                                                                  type:@"classic"
                                                                 error:&localError];
    if (startingInstance == nil || runningInstance == nil || moduleInstance == nil ||
        syntaxErrorInstance == nil || cancelInstance == nil) {
        return EJSWorkerTestFail(error, localError.localizedDescription ?: @"failed to create synthetic worker context");
    }

    startingInstance.state = EJSWorkerInstanceStateStarting;
    [self testStoreInstance:startingInstance];
    if ([self postMessageWithRequest:@{
            @"direction": @"toChild",
            @"workerID": startingInstance.workerID,
            @"envelope": @{ @"kind": @"message" }
        } transferBuffer:nil error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"postMessage unexpectedly accepted a non-running worker");
    }

    if ([self takeMessageForParentWithRequest:@{
            @"direction": @"toParent",
            @"workerID": startingInstance.workerID,
            @"messageID": @"missing"
        } error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"takeMessage unexpectedly found a missing parent message");
    }

    if ([self startWorkerWithRequest:@{ @"workerID": startingInstance.workerID } responder:nil] == nil) {
        return EJSWorkerTestFail(error, @"missing-source start did not return an operation");
    }

    EJSWorkerInstance *startupStartedInstance = [self testInstanceWithWorkerID:@"synthetic-started"
                                                                          name:@"state"
                                                                     specifier:@"state"
                                                                        source:@""
                                                                          type:@"classic"
                                                                         error:&localError];
    EJSWorkerInstance *terminatingInstance = [self testInstanceWithWorkerID:@"synthetic-terminating"
                                                                       name:@"state"
                                                                  specifier:@"state"
                                                                     source:@""
                                                                       type:@"classic"
                                                                      error:&localError];
    if (startupStartedInstance == nil || terminatingInstance == nil) {
        return EJSWorkerTestFail(error, @"failed to create synthetic started states");
    }
    startupStartedInstance.startupStarted = YES;
    [self testStoreInstance:startupStartedInstance];
    (void)[self startWorkerWithRequest:@{ @"workerID": startupStartedInstance.workerID } responder:nil];
    terminatingInstance.state = EJSWorkerInstanceStateTerminated;
    [self testStoreInstance:terminatingInstance];
    (void)[self startWorkerWithRequest:@{ @"workerID": terminatingInstance.workerID } responder:nil];

    runningInstance.state = EJSWorkerInstanceStateRunning;
    NSData *largeTransfer = [@"0123456789abcdef" dataUsingEncoding:NSUTF8StringEncoding];
    if ([tinyProvider enqueueMessageFromChildForInstance:runningInstance
                                                envelope:@{ @"kind": @"message" }
                                          transferBuffer:largeTransfer
                                                   error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"oversized child message unexpectedly enqueued");
    }
    EJSWorkerInstance *fullParentCloseInstance = [[EJSWorkerInstance alloc] initWithWorkerID:@"synthetic-close-full-parent"
                                                                                       name:@"state"
                                                                                  specifier:@"state"
                                                                                    runtime:nil
                                                                                    context:nil];
    fullParentCloseInstance.state = EJSWorkerInstanceStateRunning;
    fullParentCloseInstance.parentInbox[@"existing"] = [NSData data];
    localError = nil;
    NSData *fullParentCloseData = [tinyProvider closeFromChildForInstance:fullParentCloseInstance error:&localError];
    NSDictionary *fullParentCloseResult = EJSWorkerJSONObjectFromData(fullParentCloseData, &localError);
    if (fullParentCloseResult == nil ||
        [fullParentCloseResult[@"closed"] boolValue] != YES ||
        localError != nil) {
        return EJSWorkerTestFail(error, @"full parent queue close did not reserve terminal notification");
    }
    localError = nil;
    [tinyProvider testStoreInstance:runningInstance];
    if ([tinyProvider postMessageWithRequest:@{
            @"direction": @"toChild",
            @"workerID": runningInstance.workerID,
            @"envelope": @{ @"kind": @"message" }
        } transferBuffer:largeTransfer error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"oversized parent message unexpectedly enqueued");
    }
    [tinyProvider testRemoveInstance:runningInstance];

    EJSWorkerInstance *nilContextInstance = [[EJSWorkerInstance alloc] initWithWorkerID:@"synthetic-nil-context"
                                                                                  name:@"state"
                                                                             specifier:@"state"
                                                                               runtime:nil
                                                                               context:nil];
    nilContextInstance.state = EJSWorkerInstanceStateRunning;
    [self testStoreInstance:nilContextInstance];
    if ([self postMessageWithRequest:@{
            @"direction": @"toChild",
            @"workerID": nilContextInstance.workerID,
            @"envelope": @{ @"kind": @"message" }
        } transferBuffer:nil error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"nil-context postMessage unexpectedly dispatched");
    }
    [self testRemoveInstance:nilContextInstance];

    if ([self enqueueMessageFromChildForInstance:nil envelope:@{} transferBuffer:nil error:&localError] != nil ||
        [self takeMessageForChildInstance:nil request:@{} error:&localError] != nil ||
        [self closeFromChildForInstance:nil error:&localError] != nil ||
        [self reportErrorFromChildForInstance:nil payload:@{} error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"nil instance branch unexpectedly succeeded");
    }

    runningInstance.state = EJSWorkerInstanceStateStarting;
    if ([self enqueueMessageFromChildForInstance:runningInstance
                                        envelope:@{ @"kind": @"message" }
                                  transferBuffer:nil
                                           error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"non-running child message unexpectedly enqueued");
    }
    if ([self takeMessageForChildInstance:runningInstance request:@{} error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"missing child messageID unexpectedly succeeded");
    }
    runningInstance.state = EJSWorkerInstanceStateRunning;
    if ([self takeMessageForChildInstance:runningInstance
                                  request:@{ @"messageID": @"missing-child-message" }
                                    error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"missing child frame unexpectedly succeeded");
    }
    if ([self enqueueMessageFromChildForInstance:runningInstance
                                        envelope:@{ @"kind": @"message" }
                                  transferBuffer:nil
                                           error:&localError] != nil) {
        return EJSWorkerTestFail(error, @"nil-parent child message unexpectedly dispatched");
    }
    (void)[self reportErrorFromChildForInstance:runningInstance payload:@{} error:&localError];

    EJSWorkerInstance *terminatedCloseInstance = [[EJSWorkerInstance alloc] initWithWorkerID:@"synthetic-close-terminated"
                                                                                       name:@"state"
                                                                                  specifier:@"state"
                                                                                    runtime:nil
                                                                                    context:nil];
    terminatedCloseInstance.state = EJSWorkerInstanceStateTerminated;
    (void)[self closeFromChildForInstance:terminatedCloseInstance error:&localError];

    EJSWorkerInstance *terminatingCloseInstance = [[EJSWorkerInstance alloc] initWithWorkerID:@"synthetic-close-terminating"
                                                                                        name:@"state"
                                                                                   specifier:@"state"
                                                                                     runtime:nil
                                                                                     context:nil];
    terminatingCloseInstance.state = EJSWorkerInstanceStateTerminating;
    terminatingCloseInstance.terminationNotificationMessageID = @"pending";
    (void)[self closeFromChildForInstance:terminatingCloseInstance error:&localError];

    EJSWorkerInstance *cleanupCloseInstance = [[EJSWorkerInstance alloc] initWithWorkerID:@"synthetic-close-cleanup"
                                                                                    name:@"state"
                                                                               specifier:@"state"
                                                                                 runtime:nil
                                                                                 context:nil];
    cleanupCloseInstance.state = EJSWorkerInstanceStateRunning;
    (void)[self closeFromChildForInstance:cleanupCloseInstance error:&localError];

    EJSWorkerChildProvider *childProvider = [[EJSWorkerChildProvider alloc] initWithOwnerProvider:self instance:runningInstance];
    EJSContext *nilContext = nil;
    EJSProviderResponder *nilResponder = nil;
    EJSWorkerChildProvider *unavailableChildProvider = [[EJSWorkerChildProvider alloc] initWithOwnerProvider:nil instance:nil];
    (void)[unavailableChildProvider invokeMethod:@"postMessage"
                                         payload:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
                                  transferBuffer:nil
                                         context:nilContext
                                       responder:nilResponder];
    (void)[childProvider invokeMethod:@"postMessage" payload:[NSData data] transferBuffer:nil context:nilContext responder:nilResponder];
    (void)[childProvider invokeMethod:@"postMessage"
                              payload:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
                       transferBuffer:nil
                              context:nilContext
                            responder:nilResponder];
    (void)[childProvider invokeMethod:@"takeMessage" payload:[NSData data] transferBuffer:nil context:nilContext responder:nilResponder];
    (void)[childProvider invokeMethod:@"reportError" payload:[NSData data] transferBuffer:nil context:nilContext responder:nilResponder];
    (void)[childProvider invokeMethod:@"unsupported" payload:[@"{}" dataUsingEncoding:NSUTF8StringEncoding] transferBuffer:nil context:nilContext responder:nilResponder];

    [self testStoreInstance:moduleInstance];
    (void)[self startWorkerWithRequest:@{ @"workerID": moduleInstance.workerID } responder:nil];
    dispatch_sync(moduleInstance.dispatchQueue, ^{});

    [self testStoreInstance:syntaxErrorInstance];
    (void)[self startWorkerWithRequest:@{ @"workerID": syntaxErrorInstance.workerID } responder:nil];
    dispatch_sync(syntaxErrorInstance.dispatchQueue, ^{});

    [self testStoreInstance:cancelInstance];
    id<EJSProviderOperation> operation = [self startWorkerWithRequest:@{ @"workerID": cancelInstance.workerID } responder:nil];
    if ([operation respondsToSelector:@selector(cancel)]) {
        [(id)operation cancel];
    }
    dispatch_sync(cancelInstance.dispatchQueue, ^{});

    [self testRemoveInstance:runningInstance];
    [self testRemoveInstance:moduleInstance];
    [self testRemoveInstance:syntaxErrorInstance];
    [self testRemoveInstance:cancelInstance];
    [self testRemoveInstance:startupStartedInstance];
    [self testRemoveInstance:terminatingInstance];
    [startupStartedInstance.context invalidate];
    [startupStartedInstance.runtime invalidate];
    [terminatingInstance.context invalidate];
    [terminatingInstance.runtime invalidate];
    [runningInstance.context invalidate];
    [runningInstance.runtime invalidate];
    [moduleInstance.context invalidate];
    [moduleInstance.runtime invalidate];
    [syntaxErrorInstance.context invalidate];
    [syntaxErrorInstance.runtime invalidate];
    [cancelInstance.context invalidate];
    [cancelInstance.runtime invalidate];

    return YES;
}

#endif

@end

#ifdef EJS_TEST

static BOOL EJSWorkerTestFail(NSError **error, NSString *message) {
    if (error != NULL) {
        *error = EJSWorkerProviderError(EJSProviderErrorCodeInternal,
                                        [NSString stringWithFormat:@"EJSWorker test helper failed: %@", message ?: @"unknown"]);
    }
    return NO;
}

static BOOL EJSWorkerTestExpect(BOOL condition, NSError **error, NSString *message) {
    return condition ? YES : EJSWorkerTestFail(error, message);
}

static NSString * EJSWorkerTestJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL EJSWorkerTestErrorContains(NSError *error, NSString *needle) {
    return needle.length == 0u || [error.localizedDescription rangeOfString:needle].location != NSNotFound;
}

static BOOL EJSWorkerTestExpectPolicyFailure(NSString *json, NSString *needle, NSError **error) {
    NSError *localError = nil;
    EJSWorkerSourcePolicy *policy = EJSWorkerSourcePolicyFromJSON(json, &localError);
    if (policy != nil) {
        return EJSWorkerTestFail(error, @"policy parse unexpectedly succeeded");
    }
    if (!EJSWorkerTestErrorContains(localError, needle)) {
        return EJSWorkerTestFail(error,
                                 [NSString stringWithFormat:@"policy error mismatch: expected '%@' got '%@'",
                                                            needle ?: @"",
                                                            localError.localizedDescription ?: @""]);
    }
    return YES;
}

static BOOL EJSWorkerTestExpectResolveFailure(EJSWorkerAppleProvider *provider,
                                              NSString *specifier,
                                              NSDictionary *options,
                                              NSString *needle,
                                              NSError **error) {
    NSError *localError = nil;
    NSDictionary *resolved = [provider resolvedSourceForSpecifier:specifier options:options ?: @{} error:&localError];
    if (resolved != nil || localError == nil || !EJSWorkerTestErrorContains(localError, needle)) {
        return EJSWorkerTestFail(error,
                                 [NSString stringWithFormat:@"resolve error mismatch for %@: expected '%@' got '%@'",
                                                            specifier ?: @"",
                                                            needle ?: @"",
                                                            localError.localizedDescription ?: @""]);
    }
    return YES;
}

static BOOL EJSWorkerTestWriteString(NSString *value, NSString *path, NSError **error) {
    return [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static NSDictionary * EJSWorkerTestConfig(NSString *rootPath,
                                          BOOL allowAbsolutePath,
                                          BOOL allowParentTraversal,
                                          BOOL allowSymlinkEscape,
                                          NSNumber *maxSourceBytes) {
    return @{
        @"version": @1,
        @"defaultRoot": @"app",
        @"roots": @{
            @"app": @{
                @"path": rootPath,
                @"permissions": @[ @"read" ]
            }
        },
        @"scripts": @{
            @"ok": @{
                @"root": @"app",
                @"path": @"workers/internal_ok.js",
                @"type": @"classic"
            },
            @"module-ok": @{
                @"root": @"app",
                @"path": @"workers/internal_module.js",
                @"type": @"module"
            }
        },
        @"inlineScripts": @{
            @"inline-ok": @{
                @"source": @"postMessage({inline:true});",
                @"type": @"classic"
            }
        },
        @"pathPolicy": @{
            @"allowAbsolutePath": @(allowAbsolutePath),
            @"allowParentTraversal": @(allowParentTraversal),
            @"allowSymlinkEscape": @(allowSymlinkEscape)
        },
        @"limits": @{
            @"maxWorkers": @"bad",
            @"maxQueuedMessages": @0,
            @"maxMessageBytes": @(-1),
            @"maxSourceBytes": maxSourceBytes ?: @1024,
            @"startupTimeoutMs": [NSNull null],
            @"terminationTimeoutMs": @"bad"
        }
    };
}

BOOL EJSWorkerAppleTestRunInternalCoverage(NSString *rootPath, NSError **error) {
    if (!EJSWorkerStringIsNonEmpty(rootPath)) {
        return EJSWorkerTestFail(error, @"rootPath is required");
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *workersDir = [rootPath stringByAppendingPathComponent:@"workers"];
    if (![fileManager createDirectoryAtPath:workersDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    NSString *okPath = [workersDir stringByAppendingPathComponent:@"internal_ok.js"];
    NSString *modulePath = [workersDir stringByAppendingPathComponent:@"internal_module.js"];
    NSString *bigPath = [workersDir stringByAppendingPathComponent:@"internal_big.js"];
    NSString *outsidePath = [rootPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"worker_internal_outside.js"];
    NSString *linkPath = [workersDir stringByAppendingPathComponent:@"internal_link.js"];
    if (!EJSWorkerTestWriteString(@"onmessage = function() {};", okPath, error) ||
        !EJSWorkerTestWriteString(@"export const ok = true;", modulePath, error) ||
        !EJSWorkerTestWriteString(@"01234567890123456789012345678901234567890123456789012345678901234567890123456789", bigPath, error) ||
        !EJSWorkerTestWriteString(@"postMessage({outside:true});", outsidePath, error)) {
        return NO;
    }
    [fileManager removeItemAtPath:linkPath error:nil];
    if (![fileManager createSymbolicLinkAtPath:linkPath withDestinationPath:outsidePath error:error]) {
        return NO;
    }

    if (!EJSWorkerTestExpect(EJSWorkerBoolValue(@"bad", YES) == YES, error, @"bool default branch") ||
        !EJSWorkerTestExpect(EJSWorkerUnsignedLimit(@"bad", 123ull) == 123ull, error, @"non-number unsigned default") ||
        !EJSWorkerTestExpect(EJSWorkerUnsignedLimit(@0, 456ull) == 456ull, error, @"zero unsigned default") ||
        !EJSWorkerTestExpect(EJSWorkerUnsignedLimit(@(-1), 789ull) == 789ull, error, @"negative unsigned default") ||
        !EJSWorkerTestExpect(EJSWorkerPathHasParentTraversal(@"workers/../internal_ok.js"), error, @"parent traversal detector") ||
        !EJSWorkerTestExpect(EJSWorkerPathIsInsideRoot(@"/tmp/example.js", @"/"), error, @"root slash policy") ||
        !EJSWorkerTestExpect(!EJSWorkerSpecifierLooksLikeURLScheme(@""), error, @"empty URL scheme") ||
        !EJSWorkerTestExpect(!EJSWorkerSpecifierLooksLikeURLScheme(@"bad_scheme!:x"), error, @"invalid URL scheme") ||
        !EJSWorkerTestExpect(EJSWorkerSpecifierLooksLikeURLScheme(@"https://example.com/worker.js"), error, @"valid URL scheme") ||
        !EJSWorkerTestExpect(EJSWorkerDefaultLimitsDictionary().count == 6u, error, @"default limits dictionary")) {
        return NO;
    }

    NSError *localError = nil;
    if (!EJSWorkerTestExpect(EJSWorkerJSONObjectFromData([NSData data], &localError) == nil &&
                             EJSWorkerTestErrorContains(localError, @"payload is required"),
                             error,
                             @"empty worker JSON payload") ||
        !EJSWorkerTestExpect(EJSWorkerJSONObjectFromData([@"[]" dataUsingEncoding:NSUTF8StringEncoding], &localError) == nil,
                             error,
                             @"array worker JSON payload") ||
        !EJSWorkerTestExpect(EJSWorkerMessageFrameData(@{ @"kind": @"message" },
                                                       [@"sidecar" dataUsingEncoding:NSUTF8StringEncoding],
                                                       &localError).length > 4u,
                             error,
                             @"valid worker frame with sidecar")) {
        return NO;
    }

    EJSWorkerInstallOptions *emptyOptions = [[EJSWorkerInstallOptions alloc] init];
    EJSWorkerInstallOptions *copiedOptions = [emptyOptions copy];
    if (!EJSWorkerTestExpect(copiedOptions != nil && copiedOptions.installWorkerContext == nil,
                             error,
                             @"install options copy")) {
        return NO;
    }

    if (!EJSWorkerTestExpectPolicyFailure(nil, @"Missing ejs.worker configuration", error) ||
        !EJSWorkerTestExpectPolicyFailure(@"[", nil, error) ||
        !EJSWorkerTestExpectPolicyFailure(EJSWorkerTestJSONString(@{ @"version": @2 }), @"version", error) ||
        !EJSWorkerTestExpectPolicyFailure(EJSWorkerTestJSONString(@{ @"version": @1 }), @"defaultRoot", error) ||
        !EJSWorkerTestExpectPolicyFailure(EJSWorkerTestJSONString(@{
            @"version": @1,
            @"defaultRoot": @"app",
            @"roots": @{ @"app": @{ @"path": @"relative", @"permissions": @[] } }
        }), @"roots require", error) ||
        !EJSWorkerTestExpectPolicyFailure(EJSWorkerTestJSONString(@{
            @"version": @1,
            @"defaultRoot": @"missing",
            @"roots": @{ @"app": @{ @"path": rootPath, @"permissions": @[ @"read" ] } }
        }), @"defaultRoot", error) ||
        !EJSWorkerTestExpectPolicyFailure(EJSWorkerTestJSONString(@{
            @"version": @1,
            @"defaultRoot": @"app",
            @"roots": @{ @"app": @{ @"path": rootPath, @"permissions": @[ @"read" ] } },
            @"scripts": @{ @"bad": @{ @"root": @"app", @"path": @"workers/internal_ok.js", @"type": @"shared" } }
        }), @"scripts entries", error) ||
        !EJSWorkerTestExpectPolicyFailure(EJSWorkerTestJSONString(@{
            @"version": @1,
            @"defaultRoot": @"app",
            @"roots": @{ @"app": @{ @"path": rootPath, @"permissions": @[ @"read" ] } },
            @"inlineScripts": @{ @"bad": @{ @"source": [NSNull null], @"type": @"classic" } }
        }), @"inlineScripts", error)) {
        return NO;
    }

    localError = nil;
    EJSWorkerSourcePolicy *policy =
        EJSWorkerSourcePolicyFromJSON(EJSWorkerTestJSONString(EJSWorkerTestConfig(rootPath, NO, NO, NO, @64)), &localError);
    if (!EJSWorkerTestExpect(policy != nil &&
                             policy.limits.maxWorkers == EJSWorkerDefaultMaxWorkers &&
                             policy.limits.maxQueuedMessages == EJSWorkerDefaultMaxQueuedMessages &&
                             policy.limits.maxMessageBytes == EJSWorkerDefaultMaxMessageBytes &&
                             policy.limits.startupTimeoutMs == EJSWorkerDefaultStartupTimeoutMs &&
                             policy.limits.terminationTimeoutMs == EJSWorkerDefaultTerminationTimeoutMs,
                             error,
                             @"worker default limit parsing")) {
        return NO;
    }

    EJSWorkerAppleProvider *provider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                policy:policy
                                                                        installOptions:copiedOptions];
    NSDictionary *resolved = [provider resolvedSourceForSpecifier:@"inline-ok" options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"filename"] hasPrefix:@"ejs-worker:inline/"], error, @"inline source resolve")) {
        return NO;
    }
    resolved = [provider resolvedSourceForSpecifier:@"ok" options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"source"] isKindOfClass:[NSString class]] &&
                             [resolved[@"type"] isEqualToString:@"classic"],
                             error,
                             @"script source resolve")) {
        return NO;
    }
    resolved = [provider resolvedSourceForSpecifier:@"module-ok" options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"type"] isEqualToString:@"module"], error, @"module source resolve")) {
        return NO;
    }
    resolved = [provider resolvedSourceForSpecifier:@"workers/internal_ok.js" options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"filename"] isKindOfClass:[NSString class]], error, @"direct path resolve")) {
        return NO;
    }

    if (!EJSWorkerTestExpectResolveFailure(provider, @"https://example.com/worker.js", @{}, @"URL scheme", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, @"../worker_internal_outside.js", @{}, @"Parent traversal", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, okPath, @{}, @"Absolute worker paths", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, @"workers/internal_missing.js", @{}, @"internal_missing", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, @"workers/internal_big.js", @{}, @"maxSourceBytes", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, @"workers/internal_link.js", @{}, @"escapes", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, @"workers/internal_ok.js", @{ @"root": @"missing" }, @"root is not allowed", error) ||
        !EJSWorkerTestExpectResolveFailure(provider, @"workers/internal_ok.js", @{ @"type": @"shared" }, @"Unsupported worker type", error)) {
        return NO;
    }

    EJSWorkerSourcePolicy *absolutePolicy =
        EJSWorkerSourcePolicyFromJSON(EJSWorkerTestJSONString(EJSWorkerTestConfig(rootPath, YES, NO, NO, @1024)), &localError);
    EJSWorkerAppleProvider *absoluteProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                        policy:absolutePolicy
                                                                                installOptions:nil];
    resolved = [absoluteProvider resolvedSourceForSpecifier:okPath options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"source"] isKindOfClass:[NSString class]], error, @"absolute path allowed")) {
        return NO;
    }

    EJSWorkerSourcePolicy *parentPolicy =
        EJSWorkerSourcePolicyFromJSON(EJSWorkerTestJSONString(EJSWorkerTestConfig(rootPath, NO, YES, NO, @1024)), &localError);
    EJSWorkerAppleProvider *parentProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                      policy:parentPolicy
                                                                              installOptions:nil];
    resolved = [parentProvider resolvedSourceForSpecifier:@"workers/nested/../internal_ok.js" options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"source"] isKindOfClass:[NSString class]], error, @"parent traversal allowed inside root")) {
        return NO;
    }

    EJSWorkerSourcePolicy *symlinkPolicy =
        EJSWorkerSourcePolicyFromJSON(EJSWorkerTestJSONString(EJSWorkerTestConfig(rootPath, NO, NO, YES, @1024)), &localError);
    EJSWorkerAppleProvider *symlinkProvider = [[EJSWorkerAppleProvider alloc] initWithContext:nil
                                                                                       policy:symlinkPolicy
                                                                               installOptions:nil];
    resolved = [symlinkProvider resolvedSourceForSpecifier:@"workers/internal_link.js" options:@{} error:&localError];
    if (!EJSWorkerTestExpect([resolved[@"source"] isKindOfClass:[NSString class]], error, @"symlink escape allowed")) {
        return NO;
    }

    if (!EJSWorkerTestExpect(![provider dispatchMessageToContext:nil
                                                           queue:dispatch_get_main_queue()
                                                        workerID:@"worker"
                                                       messageID:@"message"
                                                 cleanupOnFailure:nil
                                                           error:&localError],
                             error,
                             @"dispatch nil context failure") ||
        !EJSWorkerTestExpect(![provider dispatchMessageToContext:(EJSContext *)(id)[NSNull null]
                                                           queue:nil
                                                        workerID:@"worker"
                                                       messageID:@"message"
                                                 cleanupOnFailure:nil
                                                           error:&localError],
                             error,
                             @"dispatch nil queue failure")) {
        return NO;
    }

    if (![provider runInternalStateCoverageWithRootPath:rootPath error:error]) {
        return NO;
    }

    return YES;
}

#endif

BOOL EJSWorkerInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSWorkerInstallIntoContextWithOptions(context, nil, error);
}

BOOL EJSWorkerInstallIntoContextWithOptions(EJSContext *context,
                                            EJSWorkerInstallOptions *options,
                                            NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    EJSWorkerSourcePolicy *policy = EJSWorkerSourcePolicyFromJSON([context configurationValueForKey:EJSWorkerConfigurationKey], error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"Worker", @"EJSWorker", @"__EJSWorkerDispatch", @"__EJSWorkerLastError" ], error)) {
        return NO;
    }

    EJSWorkerAppleProvider *provider = [[EJSWorkerAppleProvider alloc] initWithContext:context
                                                                                  policy:policy
                                                                          installOptions:options];
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, provider, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    NSString *source = EJSWorkerBundledSourceByName(@"js/worker_parent.js", error);
    if (source == nil) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

#ifdef EJS_TEST
    if (g_ejs_worker_apple_test_fail_script_index == 0) {
        if (error != NULL) {
            *error = EJSWorkerRuntimeError(EJSRuntimeErrorCodeInternal, @"Worker test install sentinel");
        }
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
#endif

    if (![context evaluateScript:source filename:@"js/worker_parent.js" error:error]) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    if (!EJSAppleInstallTransactionCommit(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    return YES;
}
