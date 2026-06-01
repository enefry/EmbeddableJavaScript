#import "EJSApplePlatform.h"

#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

#import "ejs_runtime.h"

NSErrorDomain const EJSRuntimeErrorDomain = @"EJSRuntimeErrorDomain";
NSErrorDomain const EJSProviderErrorDomain = @"EJSProviderErrorDomain";

static const uint8_t EJSAppleEmptyByte = 0u;

typedef struct {
    char *message;
    char *platform_domain;
} EJSAppleThreadHostErrorStorage;

static pthread_key_t g_ejs_host_error_storage_key;
static pthread_once_t g_ejs_host_error_storage_once = PTHREAD_ONCE_INIT;
static int g_ejs_host_error_storage_key_result = -1;

static void ejs_apple_thread_host_error_storage_destroy(void *value) {
    EJSAppleThreadHostErrorStorage *storage = (EJSAppleThreadHostErrorStorage *)value;

    if (storage == NULL) {
        return;
    }

    free(storage->message);
    free(storage->platform_domain);
    free(storage);
}

static void ejs_apple_thread_host_error_storage_make_key(void) {
    g_ejs_host_error_storage_key_result =
        pthread_key_create(&g_ejs_host_error_storage_key, ejs_apple_thread_host_error_storage_destroy);
}

static EJSAppleThreadHostErrorStorage * ejs_apple_thread_host_error_storage(void) {
    pthread_once(&g_ejs_host_error_storage_once, ejs_apple_thread_host_error_storage_make_key);

    if (g_ejs_host_error_storage_key_result != 0) {
        return NULL;
    }

    EJSAppleThreadHostErrorStorage *storage =
        (EJSAppleThreadHostErrorStorage *)pthread_getspecific(g_ejs_host_error_storage_key);

    if (storage != NULL) {
        return storage;
    }

    storage = (EJSAppleThreadHostErrorStorage *)calloc(1u, sizeof(*storage));

    if (storage == NULL) {
        return NULL;
    }

    if (pthread_setspecific(g_ejs_host_error_storage_key, storage) != 0) {
        ejs_apple_thread_host_error_storage_destroy(storage);
        return NULL;
    }

    return storage;
}

static const char * ejs_apple_copy_thread_string(NSString *value, char **slot) {
    if (slot == NULL) {
        return NULL;
    }

    free(*slot);
    *slot = NULL;

    const char *utf8 = value.UTF8String;

    if (utf8 == NULL) {
        return NULL;
    }

    size_t size = strlen(utf8) + 1u;
    char *copy = (char *)malloc(size);

    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, utf8, size);
    *slot = copy;
    return copy;
}

static NSDictionary<NSString *, id> * ejs_apple_copy_configuration_values(NSDictionary<NSString *, id> *values) {
    if (![values isKindOfClass:[NSDictionary class]] || values.count == 0u) {
        return @{};
    }

    NSMutableDictionary<NSString *, id> *copied = [[NSMutableDictionary alloc] initWithCapacity:values.count];
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:[NSString class]]) {
            return;
        }

        NSString *copiedKey = [key copy];
        id copiedValue = value;
        if ([value conformsToProtocol:@protocol(NSCopying)]) {
            copiedValue = [value copy];
        }
        if (copiedValue != nil) {
            copied[copiedKey] = copiedValue;
        }
    }];

    return [copied copy];
}

#ifdef EJS_TEST
typedef void (*EJSApplePlatformCreateContextTestHook)(void *user_data);
typedef void (*EJSApplePlatformOperationBoxDeallocTestHook)(void *user_data);
typedef void (*EJSApplePlatformContextDidInvalidateTestHook)(void *user_data);
typedef void (*EJSApplePlatformRuntimeDestroyTestHook)(void *user_data);

static pthread_mutex_t g_ejs_create_context_test_hook_mutex = PTHREAD_MUTEX_INITIALIZER;
static EJSApplePlatformCreateContextTestHook g_ejs_create_context_test_hook = NULL;
static void *g_ejs_create_context_test_hook_data = NULL;
static pthread_mutex_t g_ejs_operation_box_dealloc_test_hook_mutex = PTHREAD_MUTEX_INITIALIZER;
static EJSApplePlatformOperationBoxDeallocTestHook g_ejs_operation_box_dealloc_test_hook = NULL;
static void *g_ejs_operation_box_dealloc_test_hook_data = NULL;
static pthread_mutex_t g_ejs_context_did_invalidate_test_hook_mutex = PTHREAD_MUTEX_INITIALIZER;
static EJSApplePlatformContextDidInvalidateTestHook g_ejs_context_did_invalidate_test_hook = NULL;
static void *g_ejs_context_did_invalidate_test_hook_data = NULL;
static pthread_mutex_t g_ejs_runtime_destroy_test_hook_mutex = PTHREAD_MUTEX_INITIALIZER;
static EJSApplePlatformRuntimeDestroyTestHook g_ejs_runtime_destroy_test_hook = NULL;
static void *g_ejs_runtime_destroy_test_hook_data = NULL;
static _Atomic(int) g_ejs_operation_create_failure_enabled;

void ejs_apple_platform_test_set_create_context_hook(EJSApplePlatformCreateContextTestHook hook,
                                                     void                                  *user_data) {
    pthread_mutex_lock(&g_ejs_create_context_test_hook_mutex);
    g_ejs_create_context_test_hook = hook;
    g_ejs_create_context_test_hook_data = user_data;
    pthread_mutex_unlock(&g_ejs_create_context_test_hook_mutex);
}

static void ejs_apple_platform_test_run_create_context_hook(void) {
    EJSApplePlatformCreateContextTestHook hook = NULL;
    void *userData = NULL;

    pthread_mutex_lock(&g_ejs_create_context_test_hook_mutex);
    hook = g_ejs_create_context_test_hook;
    userData = g_ejs_create_context_test_hook_data;
    pthread_mutex_unlock(&g_ejs_create_context_test_hook_mutex);

    if (hook != NULL) {
        hook(userData);
    }
}

void ejs_apple_platform_test_set_operation_create_failure(int enabled) {
    atomic_store(&g_ejs_operation_create_failure_enabled, enabled);
}

void ejs_apple_platform_test_set_operation_box_dealloc_hook(EJSApplePlatformOperationBoxDeallocTestHook hook,
                                                            void                                       *user_data) {
    pthread_mutex_lock(&g_ejs_operation_box_dealloc_test_hook_mutex);
    g_ejs_operation_box_dealloc_test_hook = hook;
    g_ejs_operation_box_dealloc_test_hook_data = user_data;
    pthread_mutex_unlock(&g_ejs_operation_box_dealloc_test_hook_mutex);
}

static int ejs_apple_platform_test_should_fail_operation_create(void) {
    return atomic_load(&g_ejs_operation_create_failure_enabled) != 0;
}

static void ejs_apple_platform_test_run_operation_box_dealloc_hook(void) {
    EJSApplePlatformOperationBoxDeallocTestHook hook = NULL;
    void *userData = NULL;

    pthread_mutex_lock(&g_ejs_operation_box_dealloc_test_hook_mutex);
    hook = g_ejs_operation_box_dealloc_test_hook;
    userData = g_ejs_operation_box_dealloc_test_hook_data;
    pthread_mutex_unlock(&g_ejs_operation_box_dealloc_test_hook_mutex);

    if (hook != NULL) {
        hook(userData);
    }
}

void ejs_apple_platform_test_set_context_did_invalidate_hook(EJSApplePlatformContextDidInvalidateTestHook hook,
                                                             void                                        *user_data) {
    pthread_mutex_lock(&g_ejs_context_did_invalidate_test_hook_mutex);
    g_ejs_context_did_invalidate_test_hook = hook;
    g_ejs_context_did_invalidate_test_hook_data = user_data;
    pthread_mutex_unlock(&g_ejs_context_did_invalidate_test_hook_mutex);
}

static void ejs_apple_platform_test_run_context_did_invalidate_hook(void) {
    EJSApplePlatformContextDidInvalidateTestHook hook = NULL;
    void *userData = NULL;

    pthread_mutex_lock(&g_ejs_context_did_invalidate_test_hook_mutex);
    hook = g_ejs_context_did_invalidate_test_hook;
    userData = g_ejs_context_did_invalidate_test_hook_data;
    pthread_mutex_unlock(&g_ejs_context_did_invalidate_test_hook_mutex);

    if (hook != NULL) {
        hook(userData);
    }
}

void ejs_apple_platform_test_set_runtime_destroy_hook(EJSApplePlatformRuntimeDestroyTestHook hook,
                                                      void                                  *user_data) {
    pthread_mutex_lock(&g_ejs_runtime_destroy_test_hook_mutex);
    g_ejs_runtime_destroy_test_hook = hook;
    g_ejs_runtime_destroy_test_hook_data = user_data;
    pthread_mutex_unlock(&g_ejs_runtime_destroy_test_hook_mutex);
}

static void ejs_apple_platform_test_run_runtime_destroy_hook(void) {
    EJSApplePlatformRuntimeDestroyTestHook hook = NULL;
    void *userData = NULL;

    pthread_mutex_lock(&g_ejs_runtime_destroy_test_hook_mutex);
    hook = g_ejs_runtime_destroy_test_hook;
    userData = g_ejs_runtime_destroy_test_hook_data;
    pthread_mutex_unlock(&g_ejs_runtime_destroy_test_hook_mutex);

    if (hook != NULL) {
        hook(userData);
    }
}

#endif /* ifdef EJS_TEST */

static void ejs_apple_runtime_destroy(EJSCoreRuntime *runtime) {
    if (runtime == NULL) {
        return;
    }

#ifdef EJS_TEST
    ejs_apple_platform_test_run_runtime_destroy_hook();
#endif
    ejs_runtime_destroy(runtime);
}

static void ejs_objc_cf_retain(void *user_data) {
    if (user_data != NULL) {
        void *retained = (void *)CFBridgingRetain((__bridge id)user_data);
        (void)retained;
    }
}

static void ejs_objc_cf_release(void *user_data) {
    if (user_data != NULL) {
        id obj = CFBridgingRelease(user_data);
        (void)obj;
    }
}

static EJSCoreErrorCode ejs_provider_error_code_from_ns_error(NSError *error) {
    if (error == nil) {
        return EJS_ERROR_NONE;
    }

    if ([error.domain isEqualToString:EJSProviderErrorDomain]) {
        switch ((EJSProviderErrorCode)error.code) {
            case EJSProviderErrorCodeInvalidArgument:
                return EJS_ERROR_INVALID_ARGUMENT;

            case EJSProviderErrorCodeAborted:
                return EJS_ERROR_ABORTED;

            case EJSProviderErrorCodeNetwork:
                return EJS_ERROR_NETWORK;

            case EJSProviderErrorCodeTLS:
                return EJS_ERROR_TLS;

            case EJSProviderErrorCodeTimeout:
                return EJS_ERROR_TIMEOUT;

            case EJSProviderErrorCodeUnsupported:
                return EJS_ERROR_UNSUPPORTED;

            case EJSProviderErrorCodeSecurity:
                return EJS_ERROR_SECURITY;

            case EJSProviderErrorCodeInternal:
            case EJSProviderErrorCodeUnknown:
            default:
                return EJS_ERROR_INTERNAL;
        }
    }

    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorCancelled:
                return EJS_ERROR_ABORTED;

            case NSURLErrorTimedOut:
                return EJS_ERROR_TIMEOUT;

            case NSURLErrorUserAuthenticationRequired:
            case NSURLErrorNoPermissionsToReadFile:
                return EJS_ERROR_SECURITY;

            case NSURLErrorSecureConnectionFailed:
            case NSURLErrorServerCertificateHasBadDate:
            case NSURLErrorServerCertificateUntrusted:
            case NSURLErrorServerCertificateHasUnknownRoot:
            case NSURLErrorServerCertificateNotYetValid:
            case NSURLErrorClientCertificateRejected:
            case NSURLErrorClientCertificateRequired:
                return EJS_ERROR_TLS;

            default:
                return EJS_ERROR_NETWORK;
        }
    }

    return EJS_ERROR_INTERNAL;
}

static const char * ejs_apple_host_error_message(NSError *error, const char *fallbackMessage) {
    if (error != nil && error.localizedDescription.length > 0) {
        EJSAppleThreadHostErrorStorage *storage = ejs_apple_thread_host_error_storage();
        const char *message = ejs_apple_copy_thread_string(error.localizedDescription, storage != NULL ? &storage->message : NULL);

        if (message != NULL) {
            return message;
        }
    }

    return fallbackMessage != NULL ? fallbackMessage : "Apple provider failed";
}

static NSError * ejs_apple_platform_detail_error(NSError *error) {
    NSError *current = error;
    for (NSUInteger depth = 0u; depth < 8u; ++depth) {
        NSError *underlying = current.userInfo[NSUnderlyingErrorKey];
        if (![underlying isKindOfClass:[NSError class]] || underlying == current) {
            break;
        }
        current = underlying;
    }
    return current;
}

static const char * ejs_apple_platform_domain(NSError *error) {
    NSError *platformError = ejs_apple_platform_detail_error(error);
    if (platformError == nil) {
        return NULL;
    }

    if ([platformError.domain isEqualToString:EJSProviderErrorDomain]) {
        return "EJSProviderErrorDomain";
    }

    if ([platformError.domain isEqualToString:NSURLErrorDomain]) {
        return "NSURLErrorDomain";
    }

    if ([platformError.domain isEqualToString:EJSRuntimeErrorDomain]) {
        return "EJSRuntimeErrorDomain";
    }

    if (platformError.domain.length == 0) {
        return NULL;
    }

    EJSAppleThreadHostErrorStorage *storage = ejs_apple_thread_host_error_storage();
    return ejs_apple_copy_thread_string(platformError.domain, storage != NULL ? &storage->platform_domain : NULL);
}

static void ejs_apple_fill_host_error(EJSCoreHostError *hostError, NSError *error, const char *fallbackMessage) {
    if (hostError == NULL) {
        return;
    }

    NSError *platformDetailError = ejs_apple_platform_detail_error(error);
    memset(hostError, 0, sizeof(*hostError));
    hostError->abi_version = EJS_NATIVE_ABI_VERSION;
    hostError->struct_size = sizeof(*hostError);
    hostError->code = ejs_provider_error_code_from_ns_error(error);
    hostError->message = ejs_apple_host_error_message(error, fallbackMessage);
    hostError->platform_domain = ejs_apple_platform_domain(error);
    hostError->platform_code = platformDetailError != nil ? (int)platformDetailError.code : 0;
}

static void ejs_apple_byte_buffer_destroy(void *user_data, uint8_t *data, size_t size) {
    (void)user_data;
    (void)size;
    free(data);
}

static NSData * ejs_apple_data_from_byte_view(EJSCoreByteView view) {
    if (view.data == NULL) {
        return nil;
    }

    if (view.size == 0u) {
        return [NSData data];
    }

    return [NSData dataWithBytes:view.data length:view.size];
}

static NSData * ejs_apple_borrowed_data_from_byte_view(EJSCoreByteView view) {
    if (view.data == NULL) {
        return nil;
    }

    if (view.size == 0u) {
        return [NSData data];
    }

    return [NSData dataWithBytesNoCopy:(void *)view.data length:view.size freeWhenDone:NO];
}

static NSError * ejs_runtime_error(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
            NSLocalizedDescriptionKey: message
        } : @{};

    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * ejs_runtime_error_from_core(EJSCoreResult result) {
    if (result.error == NULL) {
        return ejs_runtime_error(EJSRuntimeErrorCodeUnknown, @"Unknown EJS core error");
    }

    EJSRuntimeErrorCode code = (EJSRuntimeErrorCode)ejs_error_code(result.error);
    NSString *message = [NSString stringWithUTF8String:ejs_error_message(result.error) ? : "Unknown EJS core error"];
    NSString *platformDomain = [NSString stringWithUTF8String:ejs_error_platform_domain(result.error) ? : ""];
    NSNumber *platformCode = @(ejs_error_platform_code(result.error));

    NSString *stack = [NSString stringWithUTF8String:ejs_error_stack(result.error) ? : ""];
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (stack.length > 0u) {
        userInfo[@"stack"] = stack;
    }

    if (platformDomain.length > 0) {
        userInfo[@"platformDomain"] = platformDomain;
    }

    if (platformCode.integerValue != 0) {
        userInfo[@"platformCode"] = platformCode;
    }

    ejs_error_destroy(result.error);
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * ejs_provider_exception_error(NSException *exception, NSString *prefix) {
    NSString *name = exception.name.length > 0 ? exception.name : @"NSException";
    NSString *reason = exception.reason.length > 0 ? exception.reason : @"";
    NSString *message = reason.length > 0
        ? [NSString stringWithFormat:@"%@ %@: %@", prefix, name, reason]
        : [NSString stringWithFormat:@"%@ %@", prefix, name];

    return EJSProviderMakeError(EJSProviderErrorCodeInternal, message);
}

@class EJSContext;
@protocol EJSProvider;
@class EJSOperationBox;
@class EJSContextHostBridge;

@interface EJSOperationBox : NSObject
@property (atomic, strong, nullable) id<EJSProviderOperation> providerOperation;
@property (atomic, strong, nullable) id<EJSProvider> provider;
@property (atomic, assign, nullable) EJSCoreHostOperation *coreOperation;
@property (atomic, assign, nullable) EJSCoreInvokeCompletion completion;
@property (atomic, assign, nullable) void *completionData;
@property (atomic, readonly, getter = isFinished) BOOL finished;
- (BOOL)finishOnce;
- (void)completeWithData:(NSData *_Nullable)resultData error:(NSError *_Nullable)error;
- (void)cancel;
@end

@interface EJSProviderResponder ()
- (instancetype)initWithOperationBox:(EJSOperationBox *)operationBox
                            moduleID:(NSString *)moduleID
                            methodID:(NSString *)methodID;
- (void)markInvokeReturned;
- (void)invalidateReleaseCheck;
@end

@interface EJSRuntimeConfiguration ()
- (EJSCoreRuntimeConfig)coreConfiguration;
@end

@interface EJSRuntime ()
@property (nonatomic, strong) EJSRuntimeConfiguration *configuration;
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, strong) NSMapTable<NSString *, EJSContext *> *contextsByID;
@property (nonatomic, strong) NSMutableSet<NSString *> *creatingContextIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingRuntimeTeardownContextIDs;
@property (nonatomic, strong, nullable) EJSRuntime *selfRetainForPendingTeardown;
@property (nonatomic, assign) EJSCoreRuntime *coreRuntime;
@property (nonatomic, assign) NSUInteger pendingContextTeardownCount;
@property (nonatomic, assign) NSUInteger pendingCreateContextTeardownCount;
@property (nonatomic, assign, getter = isInvalidated) BOOL invalidated;
@property (nonatomic, assign, getter = isDeallocating) BOOL deallocating;
- (void)contextDidInvalidate:(EJSContext *)context;
- (void)contextDidFinishRuntimeTeardown:(EJSContext *)context;
/* Requires stateLock held by caller. */
- (nullable EJSCoreRuntime *)consumeCoreRuntimeIfTeardownReadyLocked;
@end

@interface EJSContext ()
@property (nonatomic, strong, nullable) EJSRuntime *runtime;
@property (nonatomic, copy) NSString *contextID;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *configurationSnapshot;
@property (nonatomic, strong) EJSContextHostBridge *hostBridge;
@property (nonatomic, strong) NSCondition *stateCondition;
@property (nonatomic, strong) NSLock *providerLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<EJSProvider> > *providersByModule;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *activeCoreCallsByThread;
@property (nonatomic, assign) EJSCoreContext *coreContext;
@property (nonatomic, assign) EJSCoreContext *coreContextToDestroy;
@property (nonatomic, assign) BOOL notifyRuntimeWhenCoreContextDestroyed;
@property (nonatomic, assign, getter = isInvalidated) BOOL invalidated;
@property (nonatomic, assign) NSUInteger activeCoreCalls;
- (instancetype)initWithRuntime:(EJSRuntime *)runtime
                    coreContext:(EJSCoreContext *)coreContext
                      contextID:(NSString *)contextID
           configurationSnapshot:(NSDictionary<NSString *, NSString *> *)configurationSnapshot;
- (BOOL)getProvider:(id<EJSProvider> _Nullable *_Nullable)provider
        forModuleID:(NSString *)moduleID;
- (nullable EJSCoreContext *)beginCoreCallWithError:(NSError **)error;
- (void)beginCoreCallback;
- (void)endCoreCallback;
- (void)invalidateForRuntimeTeardown;
- (BOOL)currentThreadHasActiveCoreCallLocked;
- (void)endCoreCall;
- (void)endCoreCallDeferringDestroy:(BOOL)deferDestroy;
@end

#ifdef EJS_TEST
static pthread_mutex_t g_ejs_invalidate_wait_timeout_mutex = PTHREAD_MUTEX_INITIALIZER;
static NSTimeInterval g_ejs_invalidate_wait_timeout_seconds = 5.0;

void ejs_apple_platform_test_set_invalidate_wait_timeout(NSTimeInterval timeout_seconds) {
    pthread_mutex_lock(&g_ejs_invalidate_wait_timeout_mutex);
    if (timeout_seconds > 0.0) {
        g_ejs_invalidate_wait_timeout_seconds = timeout_seconds;
    } else {
        g_ejs_invalidate_wait_timeout_seconds = 5.0;
    }
    pthread_mutex_unlock(&g_ejs_invalidate_wait_timeout_mutex);
}
#endif

static NSTimeInterval ejs_apple_platform_invalidate_wait_timeout_seconds(void) {
#ifdef EJS_TEST
    pthread_mutex_lock(&g_ejs_invalidate_wait_timeout_mutex);
    NSTimeInterval timeout = g_ejs_invalidate_wait_timeout_seconds;
    pthread_mutex_unlock(&g_ejs_invalidate_wait_timeout_mutex);
    return timeout;
#else
    return 5.0;
#endif
}

@interface EJSContextHostBridge : NSObject
@property (nonatomic, weak, nullable) EJSContext *context;
- (instancetype)initWithContext:(EJSContext *)context;
@end

@implementation EJSContextHostBridge

- (instancetype)initWithContext:(EJSContext *)context {
    self = [super init];
    if (self != nil) {
        _context = context;
    }
    return self;
}

@end

static NSNumber * ejs_current_thread_key(void) {
    uint64_t threadID = 0;

    (void)pthread_threadid_np(NULL, &threadID);
    return @(threadID);
}

static int ejs_provider_operation_cancel(void *user_data) {
    EJSOperationBox *box = (__bridge EJSOperationBox *)user_data;

    [box cancel];
    return 0;
}

static void ejs_provider_operation_destroy(void *user_data) {
    if (user_data != NULL) {
        CFRelease(user_data);
    }
}

static EJSCoreHostOperation * ejs_context_dispatch_host_invoke(EJSCoreUserData         user_data,
                                                               const char              *module_id,
                                                               const char              *method_id,
                                                               EJSCoreByteView         payload,
                                                               EJSCoreByteView         transfer_buffer,
                                                               EJSCoreInvokeCompletion completion,
                                                               void                    *completion_data) {
    EJSContextHostBridge *bridge = (__bridge EJSContextHostBridge *)user_data.value;
    EJSContext *context = bridge.context;
    if (context == nil) {
        return NULL;
    }
    NSString *moduleID = module_id != NULL ? [NSString stringWithUTF8String:module_id] : nil;
    NSString *methodID = method_id != NULL ? [NSString stringWithUTF8String:method_id] : nil;
    NSData *payloadData = ejs_apple_data_from_byte_view(payload);
    NSData *transferData = ejs_apple_data_from_byte_view(transfer_buffer);

    [context beginCoreCallback];

    EJSOperationBox *box = [[EJSOperationBox alloc] init];
    void *operationUserData = (__bridge_retained void *)box;
    EJSCoreHostOperation *coreOperation = NULL;

#ifdef EJS_TEST
    if (!ejs_apple_platform_test_should_fail_operation_create()) {
#endif
        coreOperation = ejs_native_operation_create(operationUserData,
                                                   ejs_provider_operation_cancel,
                                                   ejs_provider_operation_destroy);
#ifdef EJS_TEST
    }
#endif

    if (coreOperation == NULL) {
        CFRelease(operationUserData);
        [context endCoreCallback];
        return NULL;
    }

    box.coreOperation = coreOperation;
    box.completion = completion;
    box.completionData = completion_data;

    if (context == nil || moduleID.length == 0 || methodID.length == 0) {
        [box completeWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeInvalidArgument,
                                                   @"Invalid context or invoke identifiers")];
        [context endCoreCallback];
        return coreOperation;
    }

    id<EJSProvider> provider = nil;

    if (![context getProvider:&provider forModuleID:moduleID]) {
        [box completeWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeAborted,
                                                   @"Context has already been invalidated")];
        [context endCoreCallback];
        return coreOperation;
    }

    if (provider == nil) {
        [box completeWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                   [NSString stringWithFormat:@"No Apple provider registered for module '%@'", moduleID])];
        [context endCoreCallback];
        return coreOperation;
    }

    box.provider = provider;
    EJSProviderResponder *responder =
        [[EJSProviderResponder alloc] initWithOperationBox:box moduleID:moduleID methodID:methodID];

    id<EJSProviderOperation> providerOperation = nil;

    @try {
        providerOperation = [provider invokeMethod:methodID
                                           payload:payloadData
                                    transferBuffer:transferData
                                           context:context
                                         responder:responder];
        [responder markInvokeReturned];
    } @catch (NSException *exception) {
        [responder invalidateReleaseCheck];
        [responder finishWithData:nil
                             error:ejs_provider_exception_error(exception, @"Apple provider exception")];
        box.providerOperation = [[EJSImmediateOperation alloc] init];
        responder = nil;
        [context endCoreCallback];
        return coreOperation;
    }

    if (providerOperation == nil) {
        [responder invalidateReleaseCheck];
        [box completeWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeInternal,
                                                   [NSString stringWithFormat:@"Provider '%@' returned a nil operation", moduleID])];
        box.providerOperation = [[EJSImmediateOperation alloc] init];
        responder = nil;
        [context endCoreCallback];
        return coreOperation;
    }

    if (!box.isFinished) {
        box.providerOperation = providerOperation;
    }

    responder = nil;
    [context endCoreCallback];
    return coreOperation;
}

static int ejs_context_dispatch_host_invoke_sync(EJSCoreUserData user_data,
                                                 const char *module_id,
                                                 const char *method_id,
                                                 EJSCoreByteView payload,
                                                 EJSCoreByteView transfer_buffer,
                                                 EJSCoreByteBuffer *result_out,
                                                 EJSCoreHostError *error_out) {
    if (result_out != NULL) {
        ejs_byte_buffer_init(result_out, NULL, 0u, NULL, NULL, NULL);
    }

    EJSContextHostBridge *bridge = (__bridge EJSContextHostBridge *)user_data.value;
    EJSContext *context = bridge.context;
    int status = EJS_STATUS_ERROR;

    if (context == nil) {
        ejs_apple_fill_host_error(error_out,
                                  EJSProviderMakeError(EJSProviderErrorCodeAborted,
                                                       @"Context has already been invalidated"),
                                  "Context has already been invalidated");
        return status;
    }

    [context beginCoreCallback];

    @try {
        NSString *moduleID = module_id != NULL ? [NSString stringWithUTF8String:module_id] : nil;
        NSString *methodID = method_id != NULL ? [NSString stringWithUTF8String:method_id] : nil;
        NSData *payloadData = ejs_apple_borrowed_data_from_byte_view(payload);
        NSData *transferData = ejs_apple_borrowed_data_from_byte_view(transfer_buffer);

        do {
            if (context == nil || moduleID.length == 0 || methodID.length == 0) {
                ejs_apple_fill_host_error(error_out,
                                          EJSProviderMakeError(EJSProviderErrorCodeInvalidArgument,
                                                               @"Invalid context or invoke identifiers"),
                                          "Invalid context or sync invoke identifiers");
                break;
            }

            id<EJSProvider> provider = nil;

            if (![context getProvider:&provider forModuleID:moduleID]) {
                ejs_apple_fill_host_error(error_out,
                                          EJSProviderMakeError(EJSProviderErrorCodeAborted,
                                                               @"Context has already been invalidated"),
                                          "Context has already been invalidated");
                break;
            }

            if (provider == nil) {
                ejs_apple_fill_host_error(error_out,
                                          EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                               @"No Apple provider registered for sync module"),
                                          "No Apple provider registered for sync module");
                break;
            }

            SEL syncSelector = @selector(invokeSyncMethod:payload:transferBuffer:context:error:);

            if (![provider respondsToSelector:syncSelector]) {
                ejs_apple_fill_host_error(error_out,
                                          EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                               @"Apple provider does not implement sync invoke"),
                                          "Apple provider does not implement sync invoke");
                break;
            }

            NSError *providerError = nil;
            NSData *resultData = [provider invokeSyncMethod:methodID
                                                   payload:payloadData
                                            transferBuffer:transferData
                                                   context:context
                                                     error:&providerError];

            if (providerError != nil) {
                ejs_apple_fill_host_error(error_out, providerError, "Apple sync provider failed");
                break;
            }

            if (resultData.length > 0u) {
                uint8_t *copy = (uint8_t *)malloc(resultData.length);

                if (copy == NULL) {
                    ejs_apple_fill_host_error(error_out,
                                              EJSProviderMakeError(EJSProviderErrorCodeInternal,
                                                                   @"Failed to copy sync provider result"),
                                              "Failed to copy sync provider result");
                    break;
                }

                memcpy(copy, resultData.bytes, resultData.length);
                ejs_byte_buffer_init(result_out,
                                     copy,
                                     resultData.length,
                                     NULL,
                                     ejs_apple_byte_buffer_destroy,
                                     NULL);
            }

            status = EJS_STATUS_OK;
        } while (false);
    } @catch (NSException *exception) {
        NSError *exceptionError = ejs_provider_exception_error(exception, @"Apple sync provider exception");
        ejs_apple_fill_host_error(error_out, exceptionError, exceptionError.localizedDescription.UTF8String);
        status = EJS_STATUS_ERROR;
    } @finally {
        [context endCoreCallback];
    }

    return status;
}

@implementation EJSModuleSource

- (instancetype)initWithSpecifier:(NSString *)specifier
                        sourceURL:(NSString *)sourceURL
                           source:(NSString *)source {
    if (specifier.length == 0 || source == nil) {
        return nil;
    }

    self = [super init];

    if (self == nil) {
        return nil;
    }

    _specifier = [specifier copy];
    _sourceURL = sourceURL.length > 0 ? [sourceURL copy] : [_specifier copy];
    _source = [source copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

@implementation EJSRuntimeConfiguration

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        _memoryLimitBytes = 0u;
        _maxStackSize = 0u;
    }

    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    EJSRuntimeConfiguration *copy = [[[self class] allocWithZone:zone] init];

    copy.runtimeName = self.runtimeName;
    copy.runtimeVersion = self.runtimeVersion;
    copy.memoryLimitBytes = self.memoryLimitBytes;
    copy.maxStackSize = self.maxStackSize;
    copy.contextDefaults = ejs_apple_copy_configuration_values(self.contextDefaults);
    return copy;
}

- (EJSCoreRuntimeConfig)coreConfiguration {
    EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();

    config.runtime_name = self.runtimeName.length > 0 ? self.runtimeName.UTF8String : NULL;
    config.runtime_version = self.runtimeVersion.length > 0 ? self.runtimeVersion.UTF8String : NULL;
    config.memory_limit_bytes = self.memoryLimitBytes;
    config.max_stack_size = self.maxStackSize;
    return config;
}

@end

@implementation EJSContextConfiguration

- (id)copyWithZone:(NSZone *)zone {
    EJSContextConfiguration *copy = [[[self class] allocWithZone:zone] init];

    copy.values = ejs_apple_copy_configuration_values(self.values);
    return copy;
}

@end

@implementation EJSImmediateOperation
@end

@implementation EJSBlockOperation {
    dispatch_block_t _cancelBlock;

    _Atomic(bool) _cancelled;
}

- (instancetype)initWithCancelBlock:(dispatch_block_t)cancelBlock {
    self = [super init];

    if (self != nil) {
        _cancelBlock = [cancelBlock copy];
        atomic_init(&_cancelled, false);
    }

    return self;
}

- (void)cancel {
    if (atomic_exchange(&_cancelled, true)) {
        return;
    }

    if (_cancelBlock != nil) {
        _cancelBlock();
    }
}

@end

@implementation EJSProviderResponder {
    __weak EJSOperationBox *_operationBox;
    NSString *_moduleID;
    NSString *_methodID;

    _Atomic(bool) _finished;
    _Atomic(bool) _invokeReturned;
    _Atomic(bool) _releaseCheckEnabled;
}

- (instancetype)initWithOperationBox:(EJSOperationBox *)operationBox
                            moduleID:(NSString *)moduleID
                            methodID:(NSString *)methodID {
    self = [super init];

    if (self != nil) {
        _operationBox = operationBox;
        _moduleID = [moduleID copy];
        _methodID = [methodID copy];
        atomic_init(&_finished, false);
        atomic_init(&_invokeReturned, false);
        atomic_init(&_releaseCheckEnabled, true);
    }

    return self;
}

- (BOOL)finishWithData:(NSData *)resultData error:(NSError *)error {
    if (atomic_exchange(&_finished, true)) {
        return NO;
    }

    EJSOperationBox *operationBox = _operationBox;

    if (operationBox != nil) {
        [operationBox completeWithData:resultData error:error];
    }

    return YES;
}

- (void)markInvokeReturned {
    atomic_store(&_invokeReturned, true);
}

- (void)invalidateReleaseCheck {
    atomic_store(&_releaseCheckEnabled, false);
}

- (void)dealloc {
    if (!atomic_load(&_invokeReturned) || atomic_load(&_finished) || !atomic_load(&_releaseCheckEnabled)) {
        return;
    }

    EJSOperationBox *operationBox = _operationBox;

    if (operationBox != nil) {
        NSString *message =
            [NSString stringWithFormat:@"Provider '%@' method '%@' returned without retaining responder or finishing invocation",
             _moduleID,
             _methodID];
        [operationBox completeWithData:nil
                                 error:EJSProviderMakeError(EJSProviderErrorCodeInternal, message)];
    }
}

@end

NSError * EJSProviderMakeError(EJSProviderErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
            NSLocalizedDescriptionKey: message
        } : @{};

    return [NSError errorWithDomain:EJSProviderErrorDomain code:code userInfo:userInfo];
}

@implementation EJSOperationBox {
    _Atomic(bool) _finished;
}

- (instancetype)init {
    self = [super init];

    if (self != nil) {
        atomic_init(&_finished, false);
    }

    return self;
}

- (BOOL)isFinished {
    return atomic_load(&_finished);
}

- (BOOL)finishOnce {
    return !atomic_exchange(&_finished, true);
}

- (void)completeWithData:(NSData *)resultData error:(NSError *)error {
    if (![self finishOnce]) {
        return;
    }

    EJSOperationBox *strongSelf = self;
    (void)strongSelf;

    EJSCoreByteView resultView = {
        NULL, 0u
    };
    EJSCoreHostError hostError;
    EJSCoreHostError *hostErrorPtr = NULL;

    if (resultData != nil && resultData.length > 0) {
        resultView.data = resultData.bytes;
        resultView.size = resultData.length;
    } else if (resultData != nil) {
        resultView.data = &EJSAppleEmptyByte;
        resultView.size = 0u;
    }

    if (error != nil) {
        ejs_apple_fill_host_error(&hostError, error, "Apple provider failed");
        hostErrorPtr = &hostError;
        resultView.data = NULL;
        resultView.size = 0u;
    }

    EJSCoreInvokeCompletion completion = self.completion;
    void *completionData = self.completionData;
    EJSCoreHostOperation *coreOperation = self.coreOperation;

    self.providerOperation = nil;
    self.provider = nil;
    self.completion = NULL;
    self.completionData = NULL;
    self.coreOperation = NULL;

    if (completion != NULL) {
        completion(completionData, resultView, hostErrorPtr);
    }

    if (coreOperation != NULL) {
        (void)ejs_native_operation_complete(coreOperation);
    }
}

#ifdef EJS_TEST
- (void)dealloc {
    ejs_apple_platform_test_run_operation_box_dealloc_hook();
}
#endif

- (void)cancel {
    id<EJSProviderOperation> operation = self.providerOperation;
    [self completeWithData:nil
                     error:EJSProviderMakeError(EJSProviderErrorCodeAborted,
                                                @"Operation aborted")];

    if (operation != nil && [operation respondsToSelector:@selector(cancel)]) {
        @try {
            [operation cancel];
        } @catch (__unused NSException *exception) {
            // Provider cancel is best-effort; abort completion has already been delivered.
        }
    }
}

@end

@implementation EJSRuntime

- (instancetype)init {
    return [self initWithConfiguration:nil];
}

- (instancetype)initWithConfiguration:(EJSRuntimeConfiguration *)configuration {
    self = [super init];

    if (self == nil) {
        return nil;
    }

    _configuration = configuration != nil ? [configuration copy] : [[EJSRuntimeConfiguration alloc] init];
    _stateLock = [[NSLock alloc] init];
    _contextsByID = [NSMapTable strongToWeakObjectsMapTable];
    _creatingContextIDs = [[NSMutableSet alloc] init];
    _pendingRuntimeTeardownContextIDs = [[NSMutableSet alloc] init];
    _selfRetainForPendingTeardown = nil;
    _invalidated = NO;
    _deallocating = NO;
    _pendingContextTeardownCount = 0u;
    _pendingCreateContextTeardownCount = 0u;

    EJSCoreRuntimeConfig coreConfiguration = [_configuration coreConfiguration];
    _coreRuntime = ejs_runtime_create(&coreConfiguration);

    if (_coreRuntime == NULL) {
        return nil;
    }

    return self;
}

- (void)dealloc {
    [self.stateLock lock];
    _deallocating = YES;
    [self.stateLock unlock];
    [self invalidate];
}

- (EJSContext *)createContextWithID:(NSString *)contextID error:(NSError **)error {
    return [self createContextWithID:contextID configuration:nil error:error];
}

- (EJSContext *)createContextWithID:(NSString *)contextID
                       configuration:(EJSContextConfiguration *)configuration
                               error:(NSError **)error {
    if (contextID.length == 0) {
        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument, @"contextID must not be empty");
        }

        return nil;
    }

    EJSCoreRuntime *coreRuntime = NULL;
    EJSCoreRuntime *runtimeToDestroy = NULL;
    [self.stateLock lock];

    if (_invalidated || _coreRuntime == NULL) {
        [self.stateLock unlock];

        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidated, @"Runtime has already been invalidated");
        }

        return nil;
    }

    if ([_contextsByID objectForKey:contextID] != nil || [_creatingContextIDs containsObject:contextID]) {
        [self.stateLock unlock];

        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeDuplicateContextID,
                                       [NSString stringWithFormat:@"Context ID '%@' already exists", contextID]);
        }

        return nil;
    }

    [_creatingContextIDs addObject:contextID];
    coreRuntime = _coreRuntime;
    [self.stateLock unlock];

    EJSContextConfiguration *contextConfiguration = configuration != nil ? [configuration copy] : nil;
    NSMutableDictionary<NSString *, NSString *> *configurationSnapshot =
        [ejs_apple_copy_configuration_values(_configuration.contextDefaults) mutableCopy] ?: [[NSMutableDictionary alloc] init];
    if (contextConfiguration.values.count > 0u) {
        [configurationSnapshot addEntriesFromDictionary:ejs_apple_copy_configuration_values(contextConfiguration.values)];
    }

#ifdef EJS_TEST
    ejs_apple_platform_test_run_create_context_hook();
#endif
    EJSCoreContext *coreContext = ejs_context_create(coreRuntime);

    if (coreContext == NULL) {
        [self.stateLock lock];
        [_creatingContextIDs removeObject:contextID];
        if (_invalidated && _pendingCreateContextTeardownCount > 0u) {
            _pendingCreateContextTeardownCount -= 1u;
        }
        runtimeToDestroy = [self consumeCoreRuntimeIfTeardownReadyLocked];
        [self.stateLock unlock];

        if (runtimeToDestroy != NULL) {
            ejs_apple_runtime_destroy(runtimeToDestroy);
        }

        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInternal, @"Failed to create core context");
        }

        return nil;
    }

    EJSContext *context = [[EJSContext alloc] initWithRuntime:self
                                                  coreContext:coreContext
                                                    contextID:contextID
                                         configurationSnapshot:configurationSnapshot];

    if (context == nil) {
        [self.stateLock lock];
        [_creatingContextIDs removeObject:contextID];
        if (_invalidated && _pendingCreateContextTeardownCount > 0u) {
            _pendingCreateContextTeardownCount -= 1u;
        }
        runtimeToDestroy = [self consumeCoreRuntimeIfTeardownReadyLocked];
        [self.stateLock unlock];
        ejs_context_destroy(coreContext);

        if (runtimeToDestroy != NULL) {
            ejs_apple_runtime_destroy(runtimeToDestroy);
        }

        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInternal, @"Failed to create Apple context");
        }

        return nil;
    }

    [self.stateLock lock];
    [_creatingContextIDs removeObject:contextID];
    if (_invalidated && _pendingCreateContextTeardownCount > 0u) {
        _pendingCreateContextTeardownCount -= 1u;
    }

    if (!_invalidated && _coreRuntime != NULL) {
        [_contextsByID setObject:context forKey:contextID];
        [self.stateLock unlock];
        return context;
    }

    runtimeToDestroy = [self consumeCoreRuntimeIfTeardownReadyLocked];
    [self.stateLock unlock];

    if (runtimeToDestroy != NULL) {
        ejs_apple_runtime_destroy(runtimeToDestroy);
    }

    [context invalidate];

    if (error != NULL) {
        *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidated, @"Runtime was invalidated during context creation");
    }

    return nil;
}

- (void)requestInterrupt {
    [self.stateLock lock];

    if (_coreRuntime != NULL) {
        ejs_request_interrupt(_coreRuntime);
    }

    [self.stateLock unlock];
}

- (void)invalidate {
    NSArray<EJSContext *> *contexts = nil;
    EJSCoreRuntime *coreRuntime = NULL;
    BOOL deallocating = NO;

    [self.stateLock lock];

    if (_invalidated) {
        [self.stateLock unlock];
        return;
    }

    _invalidated = YES;
    deallocating = _deallocating;
    contexts = [[_contextsByID objectEnumerator] allObjects];
    [_contextsByID removeAllObjects];
    _pendingCreateContextTeardownCount = _creatingContextIDs.count;

    if (contexts.count == 0u) {
        if (_pendingCreateContextTeardownCount > 0u) {
            if (!deallocating) {
                _selfRetainForPendingTeardown = self;
            }
        } else {
            coreRuntime = [self consumeCoreRuntimeIfTeardownReadyLocked];
        }
    } else {
        [_pendingRuntimeTeardownContextIDs removeAllObjects];

        for (EJSContext *context in contexts) {
            if (context.contextID.length > 0) {
                [_pendingRuntimeTeardownContextIDs addObject:context.contextID];
            }
        }

        _pendingContextTeardownCount = _pendingRuntimeTeardownContextIDs.count;
        if (!deallocating) {
            _selfRetainForPendingTeardown = self;
        }
        coreRuntime = [self consumeCoreRuntimeIfTeardownReadyLocked];
    }

    [self.stateLock unlock];

    for (EJSContext *context in contexts) {
        [context invalidateForRuntimeTeardown];
    }

    if (coreRuntime != NULL) {
        ejs_apple_runtime_destroy(coreRuntime);
    }
}

- (void)contextDidInvalidate:(EJSContext *)context {
    if (context == nil) {
        return;
    }

    [self.stateLock lock];
    [_contextsByID removeObjectForKey:context.contextID];
    [_creatingContextIDs removeObject:context.contextID];
    [self.stateLock unlock];

#ifdef EJS_TEST
    ejs_apple_platform_test_run_context_did_invalidate_hook();
#endif
}

- (void)contextDidFinishRuntimeTeardown:(EJSContext *)context {
    if (context == nil) {
        return;
    }

    EJSCoreRuntime *coreRuntime = NULL;

    [self.stateLock lock];

    if (_pendingContextTeardownCount > 0u &&
        [_pendingRuntimeTeardownContextIDs containsObject:context.contextID]) {
        [_pendingRuntimeTeardownContextIDs removeObject:context.contextID];
        _pendingContextTeardownCount -= 1u;
    }

    coreRuntime = [self consumeCoreRuntimeIfTeardownReadyLocked];

    [self.stateLock unlock];

    if (coreRuntime != NULL) {
        ejs_apple_runtime_destroy(coreRuntime);
    }
}

- (EJSCoreRuntime *)consumeCoreRuntimeIfTeardownReadyLocked {
    if (!_invalidated ||
        _coreRuntime == NULL ||
        _pendingContextTeardownCount != 0u ||
        _pendingCreateContextTeardownCount != 0u) {
        return NULL;
    }

    EJSCoreRuntime *coreRuntime = _coreRuntime;
    _coreRuntime = NULL;
    [_pendingRuntimeTeardownContextIDs removeAllObjects];
    _selfRetainForPendingTeardown = nil;
    return coreRuntime;
}

@end

@implementation EJSContext

- (instancetype)initWithRuntime:(EJSRuntime *)runtime
                    coreContext:(EJSCoreContext *)coreContext
                      contextID:(NSString *)contextID
           configurationSnapshot:(NSDictionary<NSString *, NSString *> *)configurationSnapshot {
    self = [super init];

    if (self == nil) {
        return nil;
    }

    _runtime = runtime;
    _coreContext = coreContext;
    _contextID = [contextID copy];
    _configurationSnapshot = [configurationSnapshot copy] ?: @{};
    _stateCondition = [[NSCondition alloc] init];
    _providerLock = [[NSLock alloc] init];
    _providersByModule = [[NSMutableDictionary alloc] init];
    _activeCoreCallsByThread = [[NSMutableDictionary alloc] init];
    _invalidated = NO;
    _activeCoreCalls = 0u;
    _coreContextToDestroy = NULL;
    _notifyRuntimeWhenCoreContextDestroyed = NO;
    _hostBridge = [[EJSContextHostBridge alloc] initWithContext:self];

    EJSCoreHostAPI hostAPI = ejs_host_api_default_value();
    hostAPI.invoke_api.user_data =
        ejs_user_data_ref_make((__bridge void *)_hostBridge, ejs_objc_cf_retain, ejs_objc_cf_release);
    hostAPI.invoke_api.invoke = ejs_context_dispatch_host_invoke;
    hostAPI.sync_invoke_api.user_data =
        ejs_user_data_ref_make((__bridge void *)_hostBridge, ejs_objc_cf_retain, ejs_objc_cf_release);
    hostAPI.sync_invoke_api.invoke_sync = ejs_context_dispatch_host_invoke_sync;
    ejs_context_register_host(coreContext, &hostAPI);
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (BOOL)evaluateScript:(NSString *)source filename:(NSString *)filename error:(NSError **)error {
    if (source == nil || filename == nil) {
        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument, @"Source and filename are required");
        }

        return NO;
    }

    EJSCoreContext *coreContext = [self beginCoreCallWithError:error];

    if (coreContext == NULL) {
        return NO;
    }

    const char *sourceCString = source.UTF8String;
    EJSCoreResult result = ejs_eval_script(coreContext,
                                           filename.UTF8String,
                                           sourceCString,
                                           [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    [self endCoreCall];

    if (result.status != EJS_STATUS_OK) {
        if (error != NULL) {
            *error = ejs_runtime_error_from_core(result);
        } else if (result.error != NULL) {
            ejs_error_destroy(result.error);
        }

        return NO;
    }

    return YES;
}

- (BOOL)evaluateModule:(NSString *)source
             specifier:(NSString *)specifier
             sourceURL:(NSString *)sourceURL
                 error:(NSError **)error {
    if (source == nil || specifier == nil) {
        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument, @"Source and specifier are required");
        }

        return NO;
    }

    EJSCoreContext *coreContext = [self beginCoreCallWithError:error];

    if (coreContext == NULL) {
        return NO;
    }

    EJSCoreEvalOptions options;
    memset(&options, 0, sizeof(options));
    options.abi_version = EJS_RUNTIME_ABI_VERSION;
    options.struct_size = sizeof(options);
    options.specifier = specifier.UTF8String;
    options.source_url = sourceURL.length > 0 ? sourceURL.UTF8String : NULL;
    options.kind = EJS_EVAL_KIND_MODULE;

    EJSCoreResult result = ejs_eval_module(coreContext,
                                           &options,
                                           source.UTF8String,
                                           [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    [self endCoreCall];

    if (result.status != EJS_STATUS_OK) {
        if (error != NULL) {
            *error = ejs_runtime_error_from_core(result);
        } else if (result.error != NULL) {
            ejs_error_destroy(result.error);
        }

        return NO;
    }

    return YES;
}

- (BOOL)registerModuleSources:(NSArray<EJSModuleSource *> *)sources error:(NSError **)error {
    if (sources == nil) {
        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument, @"Module sources are required");
        }

        return NO;
    }

    const NSUInteger sourceCount = sources.count;
    EJSCoreModuleSource *coreSources = NULL;

    if (sourceCount > 0u) {
        coreSources = (EJSCoreModuleSource *)calloc(sourceCount, sizeof(*coreSources));

        if (coreSources == NULL) {
            if (error != NULL) {
                *error = ejs_runtime_error(EJSRuntimeErrorCodeInternal, @"Failed to allocate module source table");
            }

            return NO;
        }

        for (NSUInteger index = 0u; index < sourceCount; ++index) {
            EJSModuleSource *moduleSource = sources[index];

            if (![moduleSource isKindOfClass:[EJSModuleSource class]] ||
                moduleSource.specifier.length == 0 ||
                moduleSource.source == nil) {
                free(coreSources);
                if (error != NULL) {
                    *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument,
                                               @"Module source entries require specifier and source");
                }

                return NO;
            }

            coreSources[index].specifier = moduleSource.specifier.UTF8String;
            coreSources[index].source_url = moduleSource.sourceURL.length > 0
                ? moduleSource.sourceURL.UTF8String
                : moduleSource.specifier.UTF8String;
            coreSources[index].source = moduleSource.source.UTF8String;
            coreSources[index].source_len = [moduleSource.source lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

            if (coreSources[index].specifier == NULL || coreSources[index].source == NULL) {
                free(coreSources);
                if (error != NULL) {
                    *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument,
                                               @"Module source entries must be UTF-8 encodable");
                }

                return NO;
            }
        }
    }

    EJSCoreContext *coreContext = [self beginCoreCallWithError:error];

    if (coreContext == NULL) {
        free(coreSources);
        return NO;
    }

    EJSCoreResult result = ejs_context_register_module_sources(coreContext, coreSources, sourceCount);
    [self endCoreCall];
    free(coreSources);

    if (result.status != EJS_STATUS_OK) {
        if (error != NULL) {
            *error = ejs_runtime_error_from_core(result);
        } else if (result.error != NULL) {
            ejs_error_destroy(result.error);
        }

        return NO;
    }

    return YES;
}

- (BOOL)registerProvider:(id<EJSProvider>)provider error:(NSError **)error {
    if (provider == nil || provider.moduleID.length == 0) {
        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidArgument, @"Provider must expose a non-empty moduleID");
        }

        return NO;
    }

    [self.stateCondition lock];

    if (_invalidated) {
        [self.stateCondition unlock];

        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidated, @"Context has already been invalidated");
        }

        return NO;
    }

    [self.providerLock lock];
    _providersByModule[provider.moduleID] = provider;
    [self.providerLock unlock];
    [self.stateCondition unlock];
    return YES;
}

- (void)unregisterProviderForModuleID:(NSString *)moduleID {
    if (moduleID.length == 0) {
        return;
    }

    [self.providerLock lock];
    [self.providersByModule removeObjectForKey:moduleID];
    [self.providerLock unlock];
}

- (void)unregisterAllProviders {
    [self.providerLock lock];
    [self.providersByModule removeAllObjects];
    [self.providerLock unlock];
}

- (NSString *)configurationValueForKey:(NSString *)key {
    if (key.length == 0) {
        return nil;
    }

    return self.configurationSnapshot[key];
}

- (void)invalidate {
    [self invalidateForRuntimeTeardown];
}

- (void)invalidateForRuntimeTeardown {
    EJSRuntime *runtime = nil;
    EJSCoreContext *coreContext = NULL;
    BOOL notifyRuntimeAfterDestroy = NO;
    BOOL timedOutWaitingForActiveCalls = NO;

    [self.stateCondition lock];

    if (_invalidated) {
        [self.stateCondition unlock];
        return;
    }

    _invalidated = YES;
    runtime = _runtime;

    if (_activeCoreCalls > 0u && [self currentThreadHasActiveCoreCallLocked]) {
        _coreContextToDestroy = _coreContext;
        _coreContext = NULL;
        _notifyRuntimeWhenCoreContextDestroyed = YES;
    } else {
        if (_activeCoreCalls > 0u) {
            [self.stateCondition unlock];
            [runtime requestInterrupt];
            [self.stateCondition lock];
        }

        NSDate *deadline =
            [NSDate dateWithTimeIntervalSinceNow:ejs_apple_platform_invalidate_wait_timeout_seconds()];
        while (_activeCoreCalls > 0u) {
            if (![self.stateCondition waitUntilDate:deadline]) {
                if (_activeCoreCalls > 0u) {
                    _coreContextToDestroy = _coreContext;
                    _coreContext = NULL;
                    _notifyRuntimeWhenCoreContextDestroyed = YES;
                    timedOutWaitingForActiveCalls = YES;
                }
                break;
            }
        }

        if (!timedOutWaitingForActiveCalls) {
            coreContext = _coreContext;
            _coreContext = NULL;
            notifyRuntimeAfterDestroy = YES;
        }
    }

    [self.stateCondition unlock];

    [self.providerLock lock];
    [self.providersByModule removeAllObjects];
    [self.providerLock unlock];

    if (coreContext != NULL) {
        ejs_context_destroy(coreContext);
    }

    if (notifyRuntimeAfterDestroy) {
        [runtime contextDidInvalidate:self];
        [runtime contextDidFinishRuntimeTeardown:self];

        [self.stateCondition lock];
        if (_runtime == runtime) {
            _runtime = nil;
        }
        [self.stateCondition unlock];
    }
}

- (BOOL)getProvider:(id<EJSProvider> *)provider
        forModuleID:(NSString *)moduleID {
    if (provider != NULL) {
        *provider = nil;
    }

    [self.stateCondition lock];

    if (_invalidated) {
        [self.stateCondition unlock];
        return NO;
    }

    [self.providerLock lock];
    id<EJSProvider> snapshot = _providersByModule[moduleID];
    [self.providerLock unlock];
    [self.stateCondition unlock];

    if (provider != NULL) {
        *provider = snapshot;
    }

    return YES;
}

- (EJSCoreContext *)beginCoreCallWithError:(NSError **)error {
    [self.stateCondition lock];

    if (_invalidated || _coreContext == NULL) {
        [self.stateCondition unlock];

        if (error != NULL) {
            *error = ejs_runtime_error(EJSRuntimeErrorCodeInvalidated, @"Context has already been invalidated");
        }

        return NULL;
    }

    _activeCoreCalls += 1u;
    NSNumber *threadKey = ejs_current_thread_key();
    NSUInteger threadDepth = [_activeCoreCallsByThread[threadKey] unsignedIntegerValue];
    _activeCoreCallsByThread[threadKey] = @(threadDepth + 1u);
    EJSCoreContext *coreContext = _coreContext;
    [self.stateCondition unlock];
    return coreContext;
}

- (void)beginCoreCallback {
    [self.stateCondition lock];
    _activeCoreCalls += 1u;
    NSNumber *threadKey = ejs_current_thread_key();
    NSUInteger threadDepth = [_activeCoreCallsByThread[threadKey] unsignedIntegerValue];
    _activeCoreCallsByThread[threadKey] = @(threadDepth + 1u);
    [self.stateCondition unlock];
}

- (BOOL)currentThreadHasActiveCoreCallLocked {
    return [_activeCoreCallsByThread[ejs_current_thread_key()] unsignedIntegerValue] > 0u;
}

- (void)endCoreCallback {
    [self endCoreCallDeferringDestroy:YES];
}

- (void)endCoreCall {
    [self endCoreCallDeferringDestroy:NO];
}

- (void)endCoreCallDeferringDestroy:(BOOL)deferDestroy {
    EJSCoreContext *contextToDestroy = NULL;
    BOOL notifyRuntimeAfterDestroy = NO;
    EJSRuntime *runtime = nil;

    [self.stateCondition lock];

    if (_activeCoreCalls > 0u) {
        _activeCoreCalls -= 1u;
    }

    NSNumber *threadKey = ejs_current_thread_key();
    NSUInteger threadDepth = [_activeCoreCallsByThread[threadKey] unsignedIntegerValue];

    if (threadDepth > 1u) {
        _activeCoreCallsByThread[threadKey] = @(threadDepth - 1u);
    } else if (threadDepth == 1u) {
        [_activeCoreCallsByThread removeObjectForKey:threadKey];
    }

    if (_activeCoreCalls == 0u && _coreContextToDestroy != NULL) {
        contextToDestroy = _coreContextToDestroy;
        _coreContextToDestroy = NULL;
        notifyRuntimeAfterDestroy = _notifyRuntimeWhenCoreContextDestroyed;
        _notifyRuntimeWhenCoreContextDestroyed = NO;
        runtime = _runtime;
    }

    if (_activeCoreCalls == 0u) {
        [self.stateCondition broadcast];
    }

    [self.stateCondition unlock];

    if (contextToDestroy != NULL) {
        if (deferDestroy) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                ejs_context_destroy(contextToDestroy);

                if (notifyRuntimeAfterDestroy) {
                    [runtime contextDidInvalidate:self];
                    [runtime contextDidFinishRuntimeTeardown:self];

                    [self.stateCondition lock];
                    if (_runtime == runtime) {
                        _runtime = nil;
                    }
                    [self.stateCondition unlock];
                }
            });
            return;
        }

        ejs_context_destroy(contextToDestroy);

        if (notifyRuntimeAfterDestroy) {
            [runtime contextDidInvalidate:self];
            [runtime contextDidFinishRuntimeTeardown:self];

            [self.stateCondition lock];
            if (_runtime == runtime) {
                _runtime = nil;
            }
            [self.stateCondition unlock];
        }
    }
}

@end
