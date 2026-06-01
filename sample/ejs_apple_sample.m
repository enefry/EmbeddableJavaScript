#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSWinterTCApple.h"

@interface SampleReportProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, copy) NSString *lastMessage;
@end

@implementation SampleReportProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"test";
    _semaphore = dispatch_semaphore_create(0);
    _lastMessage = @"";
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

int main(void) {
  @autoreleasepool {
    EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
    configuration.runtimeName = @"ejs_apple_sample";
    configuration.runtimeVersion = @"1.0.0";
    configuration.memoryLimitBytes = 16u * 1024u * 1024u;
    configuration.maxStackSize = 256u * 1024u;

    EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
    if (runtime == nil) {
      fprintf(stderr, "failed to create Apple EJSRuntime\n");
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSContext *context = [runtime createContextWithID:@"app://sample/main" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create Apple EJSContext: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    SampleReportProvider *provider = [[SampleReportProvider alloc] init];
    if (![context registerProvider:provider error:&error]) {
      fprintf(stderr, "failed to register Apple provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!EJSWinterTCInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install WinterTC: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *script =
        @"if (!globalThis.WinterTC || WinterTC.loaded !== true) {"
         "  throw new Error('WinterTC bundle was not installed');"
         "}"
         "__ejs_native__.invoke('test', 'report', 'Hello from the Apple platform facade');";
    if (![context evaluateScript:script filename:@"apple_sample.js" error:&error]) {
      fprintf(stderr, "failed to evaluate Apple sample script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    long waitResult = dispatch_semaphore_wait(provider.semaphore,
                                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    if (waitResult != 0) {
      fprintf(stderr, "timed out waiting for Apple provider callback\n");
      return EXIT_FAILURE;
    }

    printf("Apple sample provider received: %s\n", provider.lastMessage.UTF8String);
    [runtime invalidate];
  }

  return EXIT_SUCCESS;
}
