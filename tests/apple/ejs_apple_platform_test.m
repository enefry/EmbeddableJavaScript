#import <Foundation/Foundation.h>
#import <stdatomic.h>

#import "EJSApplePlatform.h"

static NSErrorDomain const EJSTestSyncErrorDomain = @"EJSTestSyncErrorDomain";

#ifdef EJS_TEST
typedef void (*EJSApplePlatformCreateContextTestHook)(void *user_data);
typedef void (*EJSApplePlatformOperationBoxDeallocTestHook)(void *user_data);
typedef void (*EJSApplePlatformContextDidInvalidateTestHook)(void *user_data);
typedef void (*EJSApplePlatformRuntimeDestroyTestHook)(void *user_data);
extern void ejs_apple_platform_test_set_create_context_hook(EJSApplePlatformCreateContextTestHook hook,
                                                             void *user_data);
extern void ejs_apple_platform_test_set_operation_create_failure(int enabled);
extern void ejs_apple_platform_test_set_operation_box_dealloc_hook(EJSApplePlatformOperationBoxDeallocTestHook hook,
                                                                    void *user_data);
extern void ejs_apple_platform_test_set_context_did_invalidate_hook(EJSApplePlatformContextDidInvalidateTestHook hook,
                                                                     void *user_data);
extern void ejs_apple_platform_test_set_runtime_destroy_hook(EJSApplePlatformRuntimeDestroyTestHook hook,
                                                              void *user_data);
extern void ejs_apple_platform_test_set_invalidate_wait_timeout(NSTimeInterval timeout_seconds);
#endif

@interface TestReportProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, copy) NSString *lastMessage;
@end

@implementation TestReportProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"test";
    _semaphore = dispatch_semaphore_create(0);
    _lastMessage = @"";
  }
  return self;
}

- (void)reset {
  self.lastMessage = @"";
  self.semaphore = dispatch_semaphore_create(0);
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                                responder:(EJSProviderResponder *)responder {
  (void)transferBuffer;
  (void)context;
  if (![methodID isEqualToString:@"report"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported report method")];
    return [[EJSImmediateOperation alloc] init];
  }

  NSString *message = payload != nil ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : @"";
  self.lastMessage = message ?: @"";
  dispatch_semaphore_signal(self.semaphore);
  [responder finishWithData:nil error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface EchoOperation : EJSBlockOperation
@end

@implementation EchoOperation
@end

@interface EmptyModuleProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation EmptyModuleProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"";
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
  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeInternal, @"empty module provider should not be invoked")];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface StaticProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, copy) NSString *value;
- (instancetype)initWithModuleID:(NSString *)moduleID value:(NSString *)value;
@end

@implementation StaticProvider

- (instancetype)initWithModuleID:(NSString *)moduleID value:(NSString *)value {
  self = [super init];
  if (self != nil) {
    _moduleID = [moduleID copy];
    _value = [value copy];
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
  NSData *result = [self.value dataUsingEncoding:NSUTF8StringEncoding];
  [responder finishWithData:result error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface ContextIDProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation ContextIDProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.context";
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
  if (![methodID isEqualToString:@"id"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported context method")];
    return [[EJSImmediateOperation alloc] init];
  }

  [responder finishWithData:[context.contextID dataUsingEncoding:NSUTF8StringEncoding] error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface TransferProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation TransferProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.transfer";
  }
  return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                                responder:(EJSProviderResponder *)responder {
  (void)context;
  if (![methodID isEqualToString:@"join"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported transfer method")];
    return [[EJSImmediateOperation alloc] init];
  }

  NSString *payloadString = payload != nil ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : @"";
  NSString *transferString = transferBuffer != nil ? [[NSString alloc] initWithData:transferBuffer encoding:NSUTF8StringEncoding] : @"";
  NSString *joined = [NSString stringWithFormat:@"%@|%@", payloadString ?: @"", transferString ?: @""];
  [responder finishWithData:[joined dataUsingEncoding:NSUTF8StringEncoding] error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface DataShapeProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation DataShapeProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.data";
  }
  return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
  (void)context;

  if ([methodID isEqualToString:@"describe"]) {
    NSString *payloadShape = payload != nil ? [NSString stringWithFormat:@"payload:%lu", (unsigned long)payload.length] : @"payload:nil";
    NSString *transferShape = transferBuffer != nil ? [NSString stringWithFormat:@"transfer:%lu", (unsigned long)transferBuffer.length] : @"transfer:nil";
    NSString *result = [NSString stringWithFormat:@"%@|%@", payloadShape, transferShape];
    [responder finishWithData:[result dataUsingEncoding:NSUTF8StringEncoding] error:nil];
    return [[EJSImmediateOperation alloc] init];
  }

  if ([methodID isEqualToString:@"emptyResult"]) {
    (void)payload;
    (void)transferBuffer;
    [responder finishWithData:[NSData data] error:nil];
    return [[EJSImmediateOperation alloc] init];
  }

  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported data-shape method")];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface NilOperationProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation NilOperationProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.nilop";
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
  (void)responder;
  return nil;
}

@end

@interface DroppedResponderProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation DroppedResponderProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.drop";
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
  (void)responder;
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface EchoProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation EchoProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.echo";
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

  if ([methodID isEqualToString:@"sync"]) {
    [responder finishWithData:payload error:nil];
    return [[EJSImmediateOperation alloc] init];
  }

  if ([methodID isEqualToString:@"async"]) {
    __block atomic_bool cancelled;
    atomic_init(&cancelled, false);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), queue, ^{
      if (!atomic_load(&cancelled)) {
        [responder finishWithData:payload error:nil];
      }
    });
    return [[EJSBlockOperation alloc] initWithCancelBlock:^{
      atomic_store(&cancelled, true);
    }];
  }

  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported echo method")];
  return [[EJSImmediateOperation alloc] init];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
  (void)context;

  if ([methodID isEqualToString:@"sync"]) {
    return payload;
  }

  if ([methodID isEqualToString:@"transfer"]) {
    return transferBuffer;
  }

  if ([methodID isEqualToString:@"empty"]) {
    return [NSData data];
  }

  if ([methodID isEqualToString:@"customError"]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:EJSTestSyncErrorDomain
                                   code:123
                               userInfo:@{NSLocalizedDescriptionKey: @"custom sync failure"}];
    }
    return nil;
  }

  if (error != NULL) {
    *error = EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported echo sync method");
  }
  return nil;
}

@end

@interface ExceptionSyncProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation ExceptionSyncProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.exception";
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

  if ([methodID isEqualToString:@"throwAsync"]) {
    [NSException raise:@"EJSTestAsyncException" format:@"async provider exploded"];
  }

  (void)methodID;
  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported exception method")];
  return [[EJSImmediateOperation alloc] init];
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
  (void)error;
  [NSException raise:@"EJSTestSyncException" format:@"sync provider exploded"];
  return nil;
}

@end

@interface HangingProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t cancelSemaphore;
@end

@implementation HangingProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.hang";
    _cancelSemaphore = dispatch_semaphore_create(0);
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

  if (![methodID isEqualToString:@"wait"]) {
    return [[EJSImmediateOperation alloc] init];
  }

  dispatch_semaphore_t cancelSemaphore = self.cancelSemaphore;
  return [[EJSBlockOperation alloc] initWithCancelBlock:^{
    (void)responder;
    dispatch_semaphore_signal(cancelSemaphore);
  }];
}

@end

@interface DelayedProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t completionSemaphore;
@property (nonatomic, strong) dispatch_semaphore_t deallocSemaphore;
@end

@interface CancelBehaviorProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, assign) BOOL throwOnCancel;
@property (nonatomic, assign) BOOL finishSuccessOnCancel;
@property (nonatomic, strong) dispatch_semaphore_t cancelSemaphore;
@end

@implementation CancelBehaviorProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.canceltest";
    _cancelSemaphore = dispatch_semaphore_create(0);
    _throwOnCancel = NO;
    _finishSuccessOnCancel = NO;
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

  if (![methodID isEqualToString:@"wait"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported cancel behavior method")];
    return [[EJSImmediateOperation alloc] init];
  }

  dispatch_semaphore_t cancelSemaphore = self.cancelSemaphore;
  BOOL throwOnCancel = self.throwOnCancel;
  BOOL finishSuccessOnCancel = self.finishSuccessOnCancel;
  return [[EJSBlockOperation alloc] initWithCancelBlock:^{
    if (finishSuccessOnCancel) {
      [responder finishWithData:[@"cancel-success" dataUsingEncoding:NSUTF8StringEncoding] error:nil];
    }
    dispatch_semaphore_signal(cancelSemaphore);
    if (throwOnCancel) {
      [NSException raise:@"EJSTestCancelException" format:@"cancel exploded"];
    }
  }];
}

@end

@implementation DelayedProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.delayed";
    _completionSemaphore = dispatch_semaphore_create(0);
    _deallocSemaphore = dispatch_semaphore_create(0);
  }
  return self;
}

- (void)dealloc {
  dispatch_semaphore_signal(_deallocSemaphore);
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                                responder:(EJSProviderResponder *)responder {
  (void)transferBuffer;
  (void)context;

  if (![methodID isEqualToString:@"later"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported delayed method")];
    return [[EJSImmediateOperation alloc] init];
  }

  NSData *result = [payload copy];
  dispatch_semaphore_t completionSemaphore = self.completionSemaphore;
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), queue, ^{
    [responder finishWithData:result error:nil];
    dispatch_semaphore_signal(completionSemaphore);
  });

  return [[EJSImmediateOperation alloc] init];
}

@end

@interface BlockingProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t invokedSemaphore;
@property (nonatomic, strong) dispatch_semaphore_t resumeSemaphore;
@property (nonatomic, copy) NSString *result;
@end

@implementation BlockingProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.block";
    _invokedSemaphore = dispatch_semaphore_create(0);
    _resumeSemaphore = dispatch_semaphore_create(0);
    _result = @"blocked-ok";
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

  if (![methodID isEqualToString:@"wait"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported blocking method")];
    return [[EJSImmediateOperation alloc] init];
  }

  dispatch_semaphore_signal(self.invokedSemaphore);
  dispatch_semaphore_wait(self.resumeSemaphore, DISPATCH_TIME_FOREVER);
  [responder finishWithData:[self.result dataUsingEncoding:NSUTF8StringEncoding] error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface ReentrantInvalidateProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) EJSRuntime *runtime;
- (instancetype)initWithRuntime:(EJSRuntime *)runtime;
@end

@implementation ReentrantInvalidateProvider

- (instancetype)initWithRuntime:(EJSRuntime *)runtime {
  self = [super init];
  if (self != nil) {
    _moduleID = @"apple.reentrant";
    _runtime = runtime;
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

  if (![methodID isEqualToString:@"invalidate"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported reentrant method")];
    return [[EJSImmediateOperation alloc] init];
  }

  [context invalidate];
  [self.runtime invalidate];
  [responder finishWithData:[@"reentrant-ok" dataUsingEncoding:NSUTF8StringEncoding] error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end

#ifdef EJS_TEST
typedef struct {
  dispatch_semaphore_t enteredSemaphore;
  dispatch_semaphore_t resumeSemaphore;
} CreateContextHookState;

typedef struct {
  dispatch_semaphore_t enteredSemaphore;
  dispatch_semaphore_t resumeSemaphore;
  _Atomic(int) didBlock;
} ContextInvalidateHookState;

static void create_context_blocking_hook(void *user_data) {
  CreateContextHookState *state = (CreateContextHookState *)user_data;
  dispatch_semaphore_signal(state->enteredSemaphore);
  dispatch_semaphore_wait(state->resumeSemaphore, DISPATCH_TIME_FOREVER);
}

static void context_did_invalidate_blocking_hook(void *user_data) {
  ContextInvalidateHookState *state = (ContextInvalidateHookState *)user_data;
  int expected = 0;
  if (atomic_compare_exchange_strong(&state->didBlock, &expected, 1)) {
    dispatch_semaphore_signal(state->enteredSemaphore);
    dispatch_semaphore_wait(state->resumeSemaphore, DISPATCH_TIME_FOREVER);
  }
}

static void operation_box_dealloc_hook(void *user_data) {
  dispatch_semaphore_signal((__bridge dispatch_semaphore_t)user_data);
}

static void runtime_destroy_signal_hook(void *user_data) {
  dispatch_semaphore_signal((__bridge dispatch_semaphore_t)user_data);
}
#endif

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
  if (result != 0) {
    fprintf(stderr, "timed out waiting for report payload\n");
    return NO;
  }
  if (![provider.lastMessage isEqualToString:expected]) {
    fprintf(stderr, "unexpected report payload: %s\n", provider.lastMessage.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_error_code(NSError *error, NSInteger expectedCode, const char *label) {
  if (error == nil) {
    fprintf(stderr, "%s did not produce an error\n", label);
    return NO;
  }
  if (error.code != expectedCode) {
    fprintf(stderr, "%s produced unexpected error code: %ld\n", label, (long)error.code);
    return NO;
  }
  return YES;
}

static BOOL wait_for_semaphore(dispatch_semaphore_t semaphore, NSTimeInterval seconds, const char *label) {
  long result = dispatch_semaphore_wait(semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
  if (result != 0) {
    fprintf(stderr, "timed out waiting for %s\n", label);
    return NO;
  }
  return YES;
}

static BOOL expect_semaphore_timeout(dispatch_semaphore_t semaphore, NSTimeInterval seconds, const char *label) {
  long result = dispatch_semaphore_wait(semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
  if (result == 0) {
    fprintf(stderr, "%s returned before the guarded operation completed\n", label);
    return NO;
  }
  return YES;
}

int main(void) {
  @autoreleasepool {
    EJSRuntime *runtime = [[EJSRuntime alloc] init];
    if (runtime == nil) {
      fprintf(stderr, "failed to create Apple runtime\n");
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSContext *context = [runtime createContextWithID:@"app://tests/main" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create Apple context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSError *emptyContextError = nil;
    if ([runtime createContextWithID:@"" error:&emptyContextError] != nil ||
        !expect_error_code(emptyContextError, EJSRuntimeErrorCodeInvalidArgument, "empty context ID")) {
      fprintf(stderr, "empty context ID check failed\n");
      return EXIT_FAILURE;
    }

    EJSContext *duplicate = [runtime createContextWithID:@"app://tests/main" error:&error];
    if (duplicate != nil || error.code != EJSRuntimeErrorCodeDuplicateContextID) {
      fprintf(stderr, "duplicate context ID check failed\n");
      return EXIT_FAILURE;
    }

    NSMutableString *runtimeMutableValue = [NSMutableString stringWithString:@"runtime-mutable"];
    NSMutableDictionary<NSString *, NSString *> *runtimeDefaults = [@{
      @"shared": @"runtime",
      @"overridden": @"runtime",
      @"mutable": runtimeMutableValue
    } mutableCopy];
    EJSRuntimeConfiguration *configFixture = [[EJSRuntimeConfiguration alloc] init];
    configFixture.contextDefaults = runtimeDefaults;
    EJSRuntime *configRuntime = [[EJSRuntime alloc] initWithConfiguration:configFixture];
    if (configRuntime == nil) {
      fprintf(stderr, "failed to create configuration fixture runtime\n");
      return EXIT_FAILURE;
    }

    runtimeDefaults[@"shared"] = @"mutated-after-runtime-init";
    [runtimeMutableValue appendString:@"-mutated"];
    configFixture.contextDefaults = @{ @"shared": @"mutated-config-object" };

    EJSContext *defaultConfigContext = [configRuntime createContextWithID:@"app://tests/config-default"
                                                                    error:&error];
    if (defaultConfigContext == nil ||
        ![[defaultConfigContext configurationValueForKey:@"shared"] isEqualToString:@"runtime"] ||
        ![[defaultConfigContext configurationValueForKey:@"overridden"] isEqualToString:@"runtime"] ||
        ![[defaultConfigContext configurationValueForKey:@"mutable"] isEqualToString:@"runtime-mutable"]) {
      fprintf(stderr, "runtime context default configuration snapshot failed: %s\n",
              error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSMutableString *contextMutableValue = [NSMutableString stringWithString:@"context-mutable"];
    NSMutableDictionary<NSString *, NSString *> *contextValues = [@{
      @"overridden": @"context",
      @"contextOnly": @"context",
      @"mutable": contextMutableValue
    } mutableCopy];
    EJSContextConfiguration *contextConfig = [[EJSContextConfiguration alloc] init];
    contextConfig.values = contextValues;
    EJSContext *overrideConfigContext =
        [configRuntime createContextWithID:@"app://tests/config-override"
                             configuration:contextConfig
                                     error:&error];
    if (overrideConfigContext == nil) {
      fprintf(stderr, "failed to create override configuration context: %s\n",
              error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    contextValues[@"contextOnly"] = @"mutated-after-context-create";
    [contextMutableValue appendString:@"-mutated"];
    contextConfig.values = @{ @"contextOnly": @"mutated-config-object" };

    if (![[overrideConfigContext configurationValueForKey:@"shared"] isEqualToString:@"runtime"] ||
        ![[overrideConfigContext configurationValueForKey:@"overridden"] isEqualToString:@"context"] ||
        ![[overrideConfigContext configurationValueForKey:@"contextOnly"] isEqualToString:@"context"] ||
        ![[overrideConfigContext configurationValueForKey:@"mutable"] isEqualToString:@"context-mutable"] ||
        [overrideConfigContext configurationValueForKey:@"missing"] != nil) {
      fprintf(stderr, "context configuration merge or immutability check failed\n");
      return EXIT_FAILURE;
    }

    [overrideConfigContext invalidate];
    if (![[overrideConfigContext configurationValueForKey:@"contextOnly"] isEqualToString:@"context"]) {
      fprintf(stderr, "context configuration snapshot should remain readable after invalidation\n");
      return EXIT_FAILURE;
    }
    [configRuntime invalidate];

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    EchoProvider *echoProvider = [[EchoProvider alloc] init];
    ContextIDProvider *contextIDProvider = [[ContextIDProvider alloc] init];
    TransferProvider *transferProvider = [[TransferProvider alloc] init];
    DataShapeProvider *dataShapeProvider = [[DataShapeProvider alloc] init];
    NilOperationProvider *nilOperationProvider = [[NilOperationProvider alloc] init];
    DroppedResponderProvider *droppedResponderProvider = [[DroppedResponderProvider alloc] init];
    ExceptionSyncProvider *exceptionSyncProvider = [[ExceptionSyncProvider alloc] init];

    if (![context registerProvider:reportProvider error:&error] ||
        ![context registerProvider:echoProvider error:&error] ||
        ![context registerProvider:contextIDProvider error:&error] ||
        ![context registerProvider:transferProvider error:&error] ||
        ![context registerProvider:dataShapeProvider error:&error] ||
        ![context registerProvider:nilOperationProvider error:&error] ||
        ![context registerProvider:droppedResponderProvider error:&error] ||
        ![context registerProvider:exceptionSyncProvider error:&error]) {
      fprintf(stderr, "failed to register Apple providers: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSError *invalidProviderError = nil;
    id<EJSProvider> nilProvider = nil;
    if ([context registerProvider:nilProvider error:&invalidProviderError] ||
        !expect_error_code(invalidProviderError, EJSRuntimeErrorCodeInvalidArgument, "nil provider")) {
      fprintf(stderr, "nil provider registration check failed\n");
      return EXIT_FAILURE;
    }

    EmptyModuleProvider *emptyModuleProvider = [[EmptyModuleProvider alloc] init];
    NSError *emptyModuleError = nil;
    if ([context registerProvider:emptyModuleProvider error:&emptyModuleError] ||
        !expect_error_code(emptyModuleError, EJSRuntimeErrorCodeInvalidArgument, "empty provider moduleID")) {
      fprintf(stderr, "empty provider moduleID check failed\n");
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.echo', 'sync', 'sync-ok')"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"sync_dispatch.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"sync-ok")) {
      fprintf(stderr, "sync provider dispatch verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const syncValue = __ejs_native__.invokeSync('apple.echo', 'sync', 'sync-now');"
           "__ejs_native__.invoke('test', 'report', syncValue);"
                         filename:@"sync_invoke_dispatch.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"sync-now")) {
      fprintf(stderr, "sync invoke provider dispatch verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const syncTransfer = __ejs_native__.invokeSync('apple.echo', 'transfer', 'ignored', new Uint8Array([65, 66, 67]));"
           "__ejs_native__.invoke('test', 'report', syncTransfer);"
                         filename:@"sync_invoke_transfer.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"ABC")) {
      fprintf(stderr, "sync invoke transfer dispatch verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const syncEmpty = __ejs_native__.invokeSync('apple.echo', 'empty', 'ignored');"
           "__ejs_native__.invoke('test', 'report', "
           "syncEmpty instanceof ArrayBuffer ? 'buffer:' + syncEmpty.byteLength : typeof syncEmpty);"
                         filename:@"sync_invoke_empty_result.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"buffer:0")) {
      fprintf(stderr, "sync invoke zero-length result verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"try {"
           "  __ejs_native__.invokeSync('apple.echo', 'missingSyncMethod', 'x');"
           "} catch (error) {"
           "  if (error.code === 6 && error.platform_domain === 'EJSProviderErrorDomain') __ejs_native__.invoke('test', 'report', 'sync-error-ok');"
           "}"
                         filename:@"sync_invoke_error.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"sync-error-ok")) {
      fprintf(stderr, "sync invoke error mapping verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"try {"
           "  __ejs_native__.invokeSync('apple.echo', 'customError', 'x');"
           "} catch (error) {"
           "  if (error.code === 8 && error.message === 'custom sync failure' && error.platform_domain === 'EJSTestSyncErrorDomain' && error.platform_code === 123) __ejs_native__.invoke('test', 'report', 'sync-custom-error-ok');"
           "}"
                         filename:@"sync_invoke_custom_error.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"sync-custom-error-ok")) {
      fprintf(stderr, "sync invoke custom error mapping verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"try {"
           "  __ejs_native__.invokeSync('apple.exception', 'throw', 'x');"
           "} catch (error) {"
           "  if (error.code === 8 && String(error.message).indexOf('EJSTestSyncException') >= 0) __ejs_native__.invoke('test', 'report', 'sync-exception-ok');"
           "}"
                         filename:@"sync_invoke_exception.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"sync-exception-ok")) {
      fprintf(stderr, "sync invoke exception mapping verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.exception', 'throwAsync', 'x')"
           ".catch(error => {"
           "  if (error.code === 8 && String(error.message).indexOf('EJSTestAsyncException') >= 0) {"
           "    return __ejs_native__.invoke('test', 'report', 'async-exception-ok');"
           "  }"
           "  return __ejs_native__.invoke('test', 'report', 'async-exception-bad');"
           "});"
                         filename:@"async_invoke_exception.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"async-exception-ok")) {
      fprintf(stderr, "async invoke exception mapping verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.echo', 'async', 'async-ok')"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"async_dispatch.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"async-ok")) {
      fprintf(stderr, "async provider dispatch verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.context', 'id', '')"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"context_id_dispatch.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"app://tests/main")) {
      fprintf(stderr, "provider context propagation verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.transfer', 'join', 'payload', "
           "new Uint8Array([116, 114, 97, 110, 115, 102, 101, 114]))"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"transfer_dispatch.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"payload|transfer")) {
      fprintf(stderr, "transfer buffer propagation verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.data', 'describe', '', new Uint8Array([]))"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"zero_length_payload_transfer.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"payload:0|transfer:0")) {
      fprintf(stderr, "zero-length payload/transfer propagation failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.data', 'emptyResult', 'x')"
           ".then(value => __ejs_native__.invoke('test', 'report', "
           "value instanceof ArrayBuffer ? 'buffer:' + value.byteLength : typeof value));"
                         filename:@"zero_length_result.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"buffer:0")) {
      fprintf(stderr, "zero-length provider result propagation failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateModule:
          @"__ejs_native__.invoke('test', 'report', 'module-ok');"
                      specifier:@"apple_module_test"
                      sourceURL:@"app://tests/apple_module_test.mjs"
                          error:&error] ||
        !wait_for_report(reportProvider, @"module-ok")) {
      fprintf(stderr, "module evaluation verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (![context registerProvider:[[StaticProvider alloc] initWithModuleID:@"apple.replace" value:@"first"] error:&error] ||
        ![context registerProvider:[[StaticProvider alloc] initWithModuleID:@"apple.replace" value:@"second"] error:&error]) {
      fprintf(stderr, "provider replacement registration failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.replace', 'value', '')"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"provider_replace.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"second")) {
      fprintf(stderr, "provider replacement verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [context unregisterAllProviders];
    if (![context registerProvider:reportProvider error:&error] ||
        ![context registerProvider:echoProvider error:&error] ||
        ![context registerProvider:contextIDProvider error:&error] ||
        ![context registerProvider:transferProvider error:&error] ||
        ![context registerProvider:dataShapeProvider error:&error] ||
        ![context registerProvider:nilOperationProvider error:&error] ||
        ![context registerProvider:droppedResponderProvider error:&error] ||
        ![context registerProvider:exceptionSyncProvider error:&error]) {
      fprintf(stderr, "failed to restore providers after unregisterAll: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.replace', 'value', '')"
           ".catch(error => __ejs_native__.invoke('test', 'report', error.message));"
                         filename:@"provider_unregister_all.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"No Apple provider registered for module 'apple.replace'")) {
      fprintf(stderr, "unregisterAll provider verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.nilop', 'bad', '')"
           ".catch(error => __ejs_native__.invoke('test', 'report', error.message));"
                         filename:@"nil_operation_provider.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"Provider 'apple.nilop' returned a nil operation")) {
      fprintf(stderr, "nil provider operation verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.drop', 'bad', '')"
           ".catch(error => __ejs_native__.invoke('test', 'report', error.message));"
                         filename:@"dropped_responder_provider.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"Provider 'apple.drop' method 'bad' returned without retaining responder or finishing invocation")) {
      fprintf(stderr, "dropped responder fail-fast verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    dispatch_semaphore_t operationBoxDeallocSemaphore = dispatch_semaphore_create(0);
    ejs_apple_platform_test_set_operation_box_dealloc_hook(operation_box_dealloc_hook,
                                                           (__bridge void *)operationBoxDeallocSemaphore);
    ejs_apple_platform_test_set_operation_create_failure(1);
    BOOL operationCreateFailureEval = [context evaluateScript:@"__ejs_native__.invoke('apple.echo', 'sync', 'oom');"
                                                     filename:@"operation_create_failure.js"
                                                        error:&error];
    ejs_apple_platform_test_set_operation_create_failure(0);
    if (!operationCreateFailureEval ||
        !wait_for_semaphore(operationBoxDeallocSemaphore, 1.0, "operation box release after operation-create failure")) {
      ejs_apple_platform_test_set_operation_box_dealloc_hook(NULL, NULL);
      fprintf(stderr, "operation create failure ownership verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    ejs_apple_platform_test_set_operation_box_dealloc_hook(NULL, NULL);
#endif

    DelayedProvider *delayedProvider = [[DelayedProvider alloc] init];
    dispatch_semaphore_t delayedCompletionSemaphore = delayedProvider.completionSemaphore;
    dispatch_semaphore_t delayedDeallocSemaphore = delayedProvider.deallocSemaphore;
    if (![context registerProvider:delayedProvider error:&error]) {
      fprintf(stderr, "failed to register delayed provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.delayed', 'later', 'delayed-ok')"
           ".then(value => __ejs_native__.invoke('test', 'report', value));"
                         filename:@"delayed_dispatch.js"
                            error:&error]) {
      fprintf(stderr, "delayed provider dispatch invocation failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [context unregisterProviderForModuleID:@"apple.delayed"];
    delayedProvider = nil;

    long earlyDeallocResult = dispatch_semaphore_wait(delayedDeallocSemaphore,
                                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_MSEC)));
    if (earlyDeallocResult == 0) {
      fprintf(stderr, "delayed provider deallocated before pending invoke completed\n");
      return EXIT_FAILURE;
    }

    if (!wait_for_report(reportProvider, @"delayed-ok")) {
      fprintf(stderr, "delayed provider pending invoke verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    long delayedCompletionResult = dispatch_semaphore_wait(delayedCompletionSemaphore,
                                                           dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    if (delayedCompletionResult != 0) {
      fprintf(stderr, "delayed provider completion did not finish in time\n");
      return EXIT_FAILURE;
    }

    (void)delayedDeallocSemaphore;

    DelayedProvider *invalidatedProvider = [[DelayedProvider alloc] init];
    EJSContext *invalidatedContext = [runtime createContextWithID:@"app://tests/invalidated" error:&error];
    if (invalidatedContext == nil) {
      fprintf(stderr, "failed to create invalidated-context fixture: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    [invalidatedContext invalidate];
    if ([invalidatedContext registerProvider:invalidatedProvider error:&error] ||
        error.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "register after context invalidate should fail with invalidated error\n");
      return EXIT_FAILURE;
    }
    if ([invalidatedContext evaluateScript:@"1 + 1" filename:@"invalidated_eval.js" error:&error] ||
        error.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "evaluate after context invalidate should fail with invalidated error\n");
      return EXIT_FAILURE;
    }
    EJSContext *cancelContext = [runtime createContextWithID:@"app://tests/cancel" error:&error];
    if (cancelContext == nil) {
      fprintf(stderr, "failed to create cancel-context fixture: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    HangingProvider *hangingProvider = [[HangingProvider alloc] init];
    if (![cancelContext registerProvider:hangingProvider error:&error]) {
      fprintf(stderr, "failed to register hanging provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![cancelContext evaluateScript:@"__ejs_native__.invoke('apple.hang', 'wait', '');"
                              filename:@"cancel_pending.js"
                                 error:&error]) {
      fprintf(stderr, "failed to start hanging provider invoke: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    [cancelContext invalidate];
    long cancelResult = dispatch_semaphore_wait(hangingProvider.cancelSemaphore,
                                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    if (cancelResult != 0) {
      fprintf(stderr, "context invalidate did not cancel hanging provider operation\n");
      return EXIT_FAILURE;
    }

    EJSContext *cancelExceptionContext = [runtime createContextWithID:@"app://tests/cancel-exception" error:&error];
    if (cancelExceptionContext == nil) {
      fprintf(stderr, "failed to create cancel-exception context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    CancelBehaviorProvider *cancelExceptionProvider = [[CancelBehaviorProvider alloc] init];
    cancelExceptionProvider.throwOnCancel = YES;
    if (![cancelExceptionContext registerProvider:cancelExceptionProvider error:&error]) {
      fprintf(stderr, "failed to register cancel-exception provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![cancelExceptionContext evaluateScript:@"__ejs_native__.invoke('apple.canceltest', 'wait', '').catch(function(){});"
                                      filename:@"cancel_exception.js"
                                         error:&error]) {
      fprintf(stderr, "failed to start cancel-exception invoke: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    [cancelExceptionContext invalidate];
    long cancelExceptionResult = dispatch_semaphore_wait(cancelExceptionProvider.cancelSemaphore,
                                                         dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    if (cancelExceptionResult != 0) {
      fprintf(stderr, "cancel-exception provider did not receive cancel callback\n");
      return EXIT_FAILURE;
    }

    EJSContext *cancelOrderContext = [runtime createContextWithID:@"app://tests/cancel-order" error:&error];
    if (cancelOrderContext == nil) {
      fprintf(stderr, "failed to create cancel-order context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *cancelOrderReportProvider = [[TestReportProvider alloc] init];
    CancelBehaviorProvider *cancelOrderProvider = [[CancelBehaviorProvider alloc] init];
    cancelOrderProvider.finishSuccessOnCancel = YES;
    if (![cancelOrderContext registerProvider:cancelOrderReportProvider error:&error] ||
        ![cancelOrderContext registerProvider:cancelOrderProvider error:&error]) {
      fprintf(stderr, "failed to register cancel-order providers: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![cancelOrderContext evaluateScript:
          @"__ejs_native__.invoke('apple.canceltest', 'wait', '')"
           ".then(function(value) {"
           "  __ejs_native__.invoke('test', 'report', 'cancel-order-success:' + value);"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'cancel-order-error:' + error.message);"
           "});"
                                     filename:@"cancel_ordering.js"
                                        error:&error]) {
      fprintf(stderr, "failed to start cancel-order invoke: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    [cancelOrderContext invalidate];
    long cancelOrderResult = dispatch_semaphore_wait(cancelOrderProvider.cancelSemaphore,
                                                     dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    usleep(20 * 1000);
    if (cancelOrderResult != 0 ||
        [cancelOrderReportProvider.lastMessage hasPrefix:@"cancel-order-success:"]) {
      fprintf(stderr, "cancel ordering verification failed: report=%s\n",
              cancelOrderReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    __weak EJSRuntime *weakTransientRuntime = nil;
    EJSContext *heldContext = nil;
    @autoreleasepool {
      EJSRuntime *transientRuntime = [[EJSRuntime alloc] init];
      if (transientRuntime == nil) {
        fprintf(stderr, "failed to create transient runtime fixture\n");
        return EXIT_FAILURE;
      }
      weakTransientRuntime = transientRuntime;
      heldContext = [transientRuntime createContextWithID:@"app://tests/runtime-retained-by-context" error:&error];
      transientRuntime = nil;
    }
    if (weakTransientRuntime == nil || heldContext.runtime == nil) {
      fprintf(stderr, "context did not retain runtime after caller released runtime reference\n");
      return EXIT_FAILURE;
    }
    if (![heldContext evaluateScript:@"1 + 1" filename:@"runtime_retained_by_context.js" error:&error]) {
      fprintf(stderr, "context should remain usable after caller releases runtime: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    @autoreleasepool {
      [heldContext invalidate];
      heldContext = nil;
    }
    if (weakTransientRuntime != nil) {
      fprintf(stderr, "runtime should release after its last retained context invalidates\n");
      return EXIT_FAILURE;
    }

    EJSRuntime *cycleRuntime = [[EJSRuntime alloc] init];
    if (cycleRuntime == nil) {
      fprintf(stderr, "failed to create host-cycle runtime fixture\n");
      return EXIT_FAILURE;
    }
    __weak EJSContext *weakCycleContext = nil;
    @autoreleasepool {
      EJSContext *cycleContext = [cycleRuntime createContextWithID:@"app://tests/host-cycle-release"
                                                             error:&error];
      if (cycleContext == nil) {
        fprintf(stderr, "failed to create host-cycle context: %s\n", error.localizedDescription.UTF8String);
        return EXIT_FAILURE;
      }
      weakCycleContext = cycleContext;
      cycleContext = nil;
    }
    usleep(20 * 1000);
    if (weakCycleContext != nil) {
      fprintf(stderr, "context should deallocate after caller releases last strong reference\n");
      return EXIT_FAILURE;
    }
    [cycleRuntime invalidate];

    EJSRuntime *reentrantRuntime = [[EJSRuntime alloc] init];
    if (reentrantRuntime == nil) {
      fprintf(stderr, "failed to create reentrant-invalidate runtime fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *reentrantContext = [reentrantRuntime createContextWithID:@"app://tests/reentrant-invalidate"
                                                                   error:&error];
    if (reentrantContext == nil) {
      fprintf(stderr, "failed to create reentrant-invalidate context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    ReentrantInvalidateProvider *reentrantProvider = [[ReentrantInvalidateProvider alloc] initWithRuntime:reentrantRuntime];
    if (![reentrantContext registerProvider:reentrantProvider error:&error]) {
      fprintf(stderr, "failed to register reentrant invalidate provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![reentrantContext evaluateScript:@"__ejs_native__.invoke('apple.reentrant', 'invalidate', '');"
                                 filename:@"reentrant_context_runtime_invalidate.js"
                                    error:&error]) {
      fprintf(stderr, "reentrant context/runtime invalidate should not fail active eval: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSError *reentrantPostError = nil;
    if ([reentrantRuntime createContextWithID:@"app://tests/reentrant-after" error:&reentrantPostError] != nil ||
        reentrantPostError.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "runtime should be invalidated after reentrant runtime invalidate\n");
      return EXIT_FAILURE;
    }

    EJSRuntime *activeInvalidateRuntime = [[EJSRuntime alloc] init];
    if (activeInvalidateRuntime == nil) {
      fprintf(stderr, "failed to create active-invalidate runtime fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *activeInvalidateContext = [activeInvalidateRuntime createContextWithID:@"app://tests/active-invalidate"
                                                                                 error:&error];
    if (activeInvalidateContext == nil) {
      fprintf(stderr, "failed to create active-invalidate context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    BlockingProvider *blockingProvider = [[BlockingProvider alloc] init];
    if (![activeInvalidateContext registerProvider:blockingProvider error:&error]) {
      fprintf(stderr, "failed to register blocking provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t activeEvalReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t activeInvalidateReturned = dispatch_semaphore_create(0);
    __block BOOL activeEvalResult = NO;
    __block NSError *activeEvalError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        activeEvalResult = [activeInvalidateContext evaluateScript:
                            @"__ejs_native__.invoke('apple.block', 'wait', '');"
                                                         filename:@"active_invalidate.js"
                                                            error:&activeEvalError];
        dispatch_semaphore_signal(activeEvalReturned);
      }
    });

    if (!wait_for_semaphore(blockingProvider.invokedSemaphore, 1.0, "blocking provider invocation")) {
      return EXIT_FAILURE;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [activeInvalidateContext invalidate];
        dispatch_semaphore_signal(activeInvalidateReturned);
      }
    });

    if (!expect_semaphore_timeout(activeInvalidateReturned, 0.05, "context invalidate")) {
      return EXIT_FAILURE;
    }

    dispatch_semaphore_signal(blockingProvider.resumeSemaphore);
    if (!wait_for_semaphore(activeEvalReturned, 1.0, "active invalidate evaluation")) {
      return EXIT_FAILURE;
    }
    if (!activeEvalResult) {
      fprintf(stderr, "active invalidate evaluation failed unexpectedly: %s\n",
              activeEvalError.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!wait_for_semaphore(activeInvalidateReturned, 1.0, "active context invalidate completion")) {
      return EXIT_FAILURE;
    }

    EJSRuntime *runtimeInvalidateRuntime = [[EJSRuntime alloc] init];
    if (runtimeInvalidateRuntime == nil) {
      fprintf(stderr, "failed to create runtime-invalidate runtime fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *runtimeInvalidateContext = [runtimeInvalidateRuntime createContextWithID:@"app://tests/runtime-active-invalidate"
                                                                                   error:&error];
    if (runtimeInvalidateContext == nil) {
      fprintf(stderr, "failed to create runtime-invalidate context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    BlockingProvider *runtimeBlockingProvider = [[BlockingProvider alloc] init];
    if (![runtimeInvalidateContext registerProvider:runtimeBlockingProvider error:&error]) {
      fprintf(stderr, "failed to register runtime blocking provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t runtimeEvalReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t runtimeInvalidateReturned = dispatch_semaphore_create(0);
    __block BOOL runtimeEvalResult = NO;
    __block NSError *runtimeEvalError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        runtimeEvalResult = [runtimeInvalidateContext evaluateScript:
                             @"__ejs_native__.invoke('apple.block', 'wait', '');"
                                                          filename:@"runtime_active_invalidate.js"
                                                             error:&runtimeEvalError];
        dispatch_semaphore_signal(runtimeEvalReturned);
      }
    });

    if (!wait_for_semaphore(runtimeBlockingProvider.invokedSemaphore, 1.0, "runtime blocking provider invocation")) {
      return EXIT_FAILURE;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [runtimeInvalidateRuntime invalidate];
        dispatch_semaphore_signal(runtimeInvalidateReturned);
      }
    });

    if (!expect_semaphore_timeout(runtimeInvalidateReturned, 0.05, "runtime invalidate")) {
      return EXIT_FAILURE;
    }

    dispatch_semaphore_signal(runtimeBlockingProvider.resumeSemaphore);
    if (!wait_for_semaphore(runtimeEvalReturned, 1.0, "runtime invalidate evaluation")) {
      return EXIT_FAILURE;
    }
    if (!runtimeEvalResult) {
      fprintf(stderr, "runtime invalidate evaluation failed unexpectedly: %s\n",
              runtimeEvalError.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!wait_for_semaphore(runtimeInvalidateReturned, 1.0, "runtime invalidate completion")) {
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    ejs_apple_platform_test_set_invalidate_wait_timeout(0.05);
    EJSRuntime *timeoutInvalidateRuntime = [[EJSRuntime alloc] init];
    if (timeoutInvalidateRuntime == nil) {
      fprintf(stderr, "failed to create timeout-invalidate runtime fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *timeoutInvalidateContext =
      [timeoutInvalidateRuntime createContextWithID:@"app://tests/runtime-timeout-invalidate"
                                              error:&error];
    if (timeoutInvalidateContext == nil) {
      fprintf(stderr, "failed to create timeout-invalidate context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    BlockingProvider *timeoutBlockingProvider = [[BlockingProvider alloc] init];
    if (![timeoutInvalidateContext registerProvider:timeoutBlockingProvider error:&error]) {
      fprintf(stderr, "failed to register timeout blocking provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t timeoutEvalReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t timeoutInvalidateReturned = dispatch_semaphore_create(0);
    __block BOOL timeoutEvalResult = NO;
    __block NSError *timeoutEvalError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        timeoutEvalResult = [timeoutInvalidateContext evaluateScript:
                             @"__ejs_native__.invoke('apple.block', 'wait', '');"
                                                           filename:@"runtime_timeout_invalidate.js"
                                                              error:&timeoutEvalError];
        dispatch_semaphore_signal(timeoutEvalReturned);
      }
    });

    if (!wait_for_semaphore(timeoutBlockingProvider.invokedSemaphore, 1.0, "timeout blocking provider invocation")) {
      return EXIT_FAILURE;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [timeoutInvalidateRuntime invalidate];
        dispatch_semaphore_signal(timeoutInvalidateReturned);
      }
    });

    if (!wait_for_semaphore(timeoutInvalidateReturned, 1.0, "timeout runtime invalidate completion")) {
      fprintf(stderr, "runtime invalidate should return after timeout when provider stays blocked\n");
      return EXIT_FAILURE;
    }

    dispatch_semaphore_signal(timeoutBlockingProvider.resumeSemaphore);
    if (!wait_for_semaphore(timeoutEvalReturned, 1.0, "timeout runtime invalidate evaluation")) {
      return EXIT_FAILURE;
    }
    if (!timeoutEvalResult) {
      fprintf(stderr, "timeout runtime invalidate evaluation failed unexpectedly: %s\n",
              timeoutEvalError.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    ejs_apple_platform_test_set_invalidate_wait_timeout(5.0);
#endif

    EJSRuntime *interruptRuntime = [[EJSRuntime alloc] init];
    if (interruptRuntime == nil) {
      fprintf(stderr, "failed to create interrupt-on-invalidate runtime fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *interruptContext = [interruptRuntime createContextWithID:@"app://tests/interrupt-on-invalidate"
                                                                   error:&error];
    if (interruptContext == nil) {
      fprintf(stderr, "failed to create interrupt-on-invalidate context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t interruptEvalStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t interruptEvalReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t interruptInvalidateReturned = dispatch_semaphore_create(0);
    __block BOOL interruptEvalResult = YES;
    __block NSError *interruptEvalError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        dispatch_semaphore_signal(interruptEvalStarted);
        interruptEvalResult = [interruptContext evaluateScript:@"while (true) {}"
                                                      filename:@"interrupt_on_invalidate.js"
                                                         error:&interruptEvalError];
        dispatch_semaphore_signal(interruptEvalReturned);
      }
    });

    if (!wait_for_semaphore(interruptEvalStarted, 1.0, "interrupt-on-invalidate eval start")) {
      return EXIT_FAILURE;
    }
    if (!expect_semaphore_timeout(interruptEvalReturned, 0.05, "interrupt-on-invalidate eval")) {
      return EXIT_FAILURE;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [interruptContext invalidate];
        dispatch_semaphore_signal(interruptInvalidateReturned);
      }
    });

    if (!wait_for_semaphore(interruptEvalReturned, 2.0, "interrupted infinite evaluation")) {
      return EXIT_FAILURE;
    }
    if (interruptEvalResult || interruptEvalError == nil) {
      fprintf(stderr, "infinite evaluation should fail after context invalidate requests interrupt\n");
      return EXIT_FAILURE;
    }
    if (!wait_for_semaphore(interruptInvalidateReturned, 1.0, "interrupting context invalidate completion")) {
      return EXIT_FAILURE;
    }
    [interruptRuntime invalidate];

    EJSRuntime *runtimeInterruptRuntime = [[EJSRuntime alloc] init];
    if (runtimeInterruptRuntime == nil) {
      fprintf(stderr, "failed to create runtime-interrupt-on-invalidate fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *runtimeInterruptContext = [runtimeInterruptRuntime createContextWithID:@"app://tests/runtime-interrupt-on-invalidate"
                                                                                 error:&error];
    if (runtimeInterruptContext == nil) {
      fprintf(stderr, "failed to create runtime-interrupt-on-invalidate context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t runtimeInterruptEvalStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t runtimeInterruptEvalReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t runtimeInterruptInvalidateReturned = dispatch_semaphore_create(0);
    __block BOOL runtimeInterruptEvalResult = YES;
    __block NSError *runtimeInterruptEvalError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        dispatch_semaphore_signal(runtimeInterruptEvalStarted);
        runtimeInterruptEvalResult = [runtimeInterruptContext evaluateScript:@"while (true) {}"
                                                                    filename:@"runtime_interrupt_on_invalidate.js"
                                                                       error:&runtimeInterruptEvalError];
        dispatch_semaphore_signal(runtimeInterruptEvalReturned);
      }
    });

    if (!wait_for_semaphore(runtimeInterruptEvalStarted, 1.0, "runtime-interrupt-on-invalidate eval start")) {
      return EXIT_FAILURE;
    }
    if (!expect_semaphore_timeout(runtimeInterruptEvalReturned, 0.05, "runtime-interrupt-on-invalidate eval")) {
      return EXIT_FAILURE;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [runtimeInterruptRuntime invalidate];
        dispatch_semaphore_signal(runtimeInterruptInvalidateReturned);
      }
    });

    if (!wait_for_semaphore(runtimeInterruptEvalReturned, 2.0, "runtime-interrupted infinite evaluation")) {
      return EXIT_FAILURE;
    }
    if (runtimeInterruptEvalResult || runtimeInterruptEvalError == nil) {
      fprintf(stderr, "infinite evaluation should fail after runtime invalidate requests interrupt\n");
      return EXIT_FAILURE;
    }
    if (!wait_for_semaphore(runtimeInterruptInvalidateReturned, 1.0, "runtime interrupting invalidate completion")) {
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    EJSRuntime *pendingMembershipRuntime = [[EJSRuntime alloc] init];
    if (pendingMembershipRuntime == nil) {
      fprintf(stderr, "failed to create pending-membership runtime fixture\n");
      return EXIT_FAILURE;
    }
    EJSContext *removedBeforeRuntimeInvalidateContext =
        [pendingMembershipRuntime createContextWithID:@"app://tests/pending-membership-removed" error:&error];
    EJSContext *pendingRuntimeTeardownContext =
        [pendingMembershipRuntime createContextWithID:@"app://tests/pending-membership-active" error:&error];
    if (removedBeforeRuntimeInvalidateContext == nil || pendingRuntimeTeardownContext == nil) {
      fprintf(stderr, "failed to create pending-membership contexts: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    BlockingProvider *pendingMembershipProvider = [[BlockingProvider alloc] init];
    if (![pendingRuntimeTeardownContext registerProvider:pendingMembershipProvider error:&error]) {
      fprintf(stderr, "failed to register pending-membership blocking provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    ContextInvalidateHookState pendingMembershipHook = {
      .enteredSemaphore = dispatch_semaphore_create(0),
      .resumeSemaphore = dispatch_semaphore_create(0),
    };
    atomic_init(&pendingMembershipHook.didBlock, 0);
    dispatch_semaphore_t pendingMembershipDestroySemaphore = dispatch_semaphore_create(0);
    ejs_apple_platform_test_set_context_did_invalidate_hook(context_did_invalidate_blocking_hook,
                                                            &pendingMembershipHook);
    ejs_apple_platform_test_set_runtime_destroy_hook(runtime_destroy_signal_hook,
                                                     (__bridge void *)pendingMembershipDestroySemaphore);

    dispatch_semaphore_t removedInvalidateReturned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [removedBeforeRuntimeInvalidateContext invalidate];
        dispatch_semaphore_signal(removedInvalidateReturned);
      }
    });

    if (!wait_for_semaphore(pendingMembershipHook.enteredSemaphore,
                            1.0,
                            "removed context invalidate hook")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t pendingMembershipEvalReturned = dispatch_semaphore_create(0);
    __block BOOL pendingMembershipEvalResult = NO;
    __block NSError *pendingMembershipEvalError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        pendingMembershipEvalResult = [pendingRuntimeTeardownContext evaluateScript:
                                       @"__ejs_native__.invoke('apple.block', 'wait', '');"
                                                                    filename:@"pending_membership_active.js"
                                                                       error:&pendingMembershipEvalError];
        dispatch_semaphore_signal(pendingMembershipEvalReturned);
      }
    });

    if (!wait_for_semaphore(pendingMembershipProvider.invokedSemaphore,
                            1.0,
                            "pending-membership provider invocation")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_t pendingMembershipRuntimeInvalidateReturned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [pendingMembershipRuntime invalidate];
        dispatch_semaphore_signal(pendingMembershipRuntimeInvalidateReturned);
      }
    });

    if (!expect_semaphore_timeout(pendingMembershipRuntimeInvalidateReturned,
                                  0.05,
                                  "pending-membership runtime invalidate")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_signal(pendingMembershipHook.resumeSemaphore);
    if (!wait_for_semaphore(removedInvalidateReturned, 1.0, "removed context invalidate completion")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }

    if (!expect_semaphore_timeout(pendingMembershipDestroySemaphore,
                                  0.05,
                                  "runtime destroy before pending context teardown")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }

    dispatch_semaphore_signal(pendingMembershipProvider.resumeSemaphore);
    if (!wait_for_semaphore(pendingMembershipEvalReturned, 1.0, "pending-membership active evaluation")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }
    if (!pendingMembershipEvalResult) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      fprintf(stderr, "pending-membership evaluation failed unexpectedly: %s\n",
              pendingMembershipEvalError.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!wait_for_semaphore(pendingMembershipRuntimeInvalidateReturned,
                            1.0,
                            "pending-membership runtime invalidate completion")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }
    if (!wait_for_semaphore(pendingMembershipDestroySemaphore,
                            1.0,
                            "runtime destroy after pending context teardown")) {
      ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
      ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);
      return EXIT_FAILURE;
    }
    ejs_apple_platform_test_set_context_did_invalidate_hook(NULL, NULL);
    ejs_apple_platform_test_set_runtime_destroy_hook(NULL, NULL);

    EJSRuntime *createInvalidateRuntime = [[EJSRuntime alloc] init];
    if (createInvalidateRuntime == nil) {
      fprintf(stderr, "failed to create create-invalidate runtime fixture\n");
      return EXIT_FAILURE;
    }
    CreateContextHookState hookState = {
      .enteredSemaphore = dispatch_semaphore_create(0),
      .resumeSemaphore = dispatch_semaphore_create(0),
    };
    ejs_apple_platform_test_set_create_context_hook(create_context_blocking_hook, &hookState);

    dispatch_semaphore_t createReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t createInvalidateReturned = dispatch_semaphore_create(0);
    __block EJSContext *createdWhileInvalidating = nil;
    __block NSError *createWhileInvalidatingError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        createdWhileInvalidating = [createInvalidateRuntime createContextWithID:@"app://tests/create-invalidate"
                                                                          error:&createWhileInvalidatingError];
        dispatch_semaphore_signal(createReturned);
      }
    });

    if (!wait_for_semaphore(hookState.enteredSemaphore, 1.0, "create context hook")) {
      ejs_apple_platform_test_set_create_context_hook(NULL, NULL);
      return EXIT_FAILURE;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      @autoreleasepool {
        [createInvalidateRuntime invalidate];
        dispatch_semaphore_signal(createInvalidateReturned);
      }
    });

    if (!wait_for_semaphore(createInvalidateReturned, 1.0, "runtime invalidate during context creation")) {
      ejs_apple_platform_test_set_create_context_hook(NULL, NULL);
      fprintf(stderr, "runtime invalidate should not wait for blocked context creation hook\n");
      return EXIT_FAILURE;
    }

    dispatch_semaphore_signal(hookState.resumeSemaphore);
    if (!wait_for_semaphore(createReturned, 1.0, "create context completion")) {
      ejs_apple_platform_test_set_create_context_hook(NULL, NULL);
      return EXIT_FAILURE;
    }
    ejs_apple_platform_test_set_create_context_hook(NULL, NULL);

    if (createdWhileInvalidating != nil ||
        createWhileInvalidatingError.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "context creation should fail once runtime is invalidated during create hook\n");
      return EXIT_FAILURE;
    }
#endif

    [context unregisterProviderForModuleID:@"apple.echo"];
    [reportProvider reset];
    if (![context evaluateScript:
          @"__ejs_native__.invoke('apple.echo', 'sync', 'miss')"
           ".catch(error => __ejs_native__.invoke('test', 'report', error.message));"
                         filename:@"missing_provider.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"No Apple provider registered for module 'apple.echo'")) {
      fprintf(stderr, "unsupported provider verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
    __block NSInteger successCount = 0;
    __block NSInteger duplicateCount = 0;
    __block EJSContext *winnerContext = nil;

    for (NSInteger index = 0; index < 8; index++) {
      dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        dispatch_semaphore_wait(startSemaphore, DISPATCH_TIME_FOREVER);
        NSError *localError = nil;
        EJSContext *racedContext = [runtime createContextWithID:@"app://tests/race" error:&localError];
        if (racedContext != nil) {
          @synchronized (runtime) {
            successCount += 1;
            if (winnerContext == nil) {
              winnerContext = racedContext;
            } else {
              duplicateCount = NSIntegerMin;
            }
          }
          return;
        }

        if (localError.code == EJSRuntimeErrorCodeDuplicateContextID) {
          @synchronized (runtime) {
            duplicateCount += 1;
          }
          return;
        }

        @synchronized (runtime) {
          duplicateCount = NSIntegerMin;
        }
      });
    }

    for (NSInteger index = 0; index < 8; index++) {
      dispatch_semaphore_signal(startSemaphore);
    }

    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    if (successCount != 1 || duplicateCount != 7) {
      fprintf(stderr, "concurrent context creation guard failed: success=%ld duplicate=%ld\n",
              (long)successCount, (long)duplicateCount);
      return EXIT_FAILURE;
    }
    [winnerContext invalidate];

    EJSRuntime *invalidatedRuntime = [[EJSRuntime alloc] init];
    if (invalidatedRuntime == nil) {
      fprintf(stderr, "failed to create invalidated runtime fixture\n");
      return EXIT_FAILURE;
    }
    [invalidatedRuntime invalidate];
    if ([invalidatedRuntime createContextWithID:@"app://tests/runtime-invalidated" error:&error] != nil ||
        error.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "create context after runtime invalidate should fail with invalidated error\n");
      return EXIT_FAILURE;
    }

    [runtime invalidate];
  }

  printf("ejs_apple_platform_test PASS\n");
  return EXIT_SUCCESS;
}
