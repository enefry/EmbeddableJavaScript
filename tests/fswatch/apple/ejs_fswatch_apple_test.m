#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSFSWatchApple.h"

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
  self.lastMessage = payload != nil ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"" : @"";
  dispatch_semaphore_signal(self.semaphore);
  [responder finishWithData:nil error:nil];
  return [[EJSImmediateOperation alloc] init];
}
@end

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
  if (result == 0 && [provider.lastMessage isEqualToString:expected]) {
    return YES;
  }
  if (result == 0) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n", expected.UTF8String, provider.lastMessage.UTF8String);
    return NO;
  }
  fprintf(stderr, "timed out waiting for report: expected=%s actual=%s\n", expected.UTF8String, provider.lastMessage.UTF8String);
  return NO;
}

static NSString * fswatch_json(NSString *root) {
  NSDictionary *config = @{
    @"version": @1,
    @"defaultRoot": @"documents",
    @"roots": @{
      @"documents": @{ @"path": root }
    },
    @"pathPolicy": @{
      @"allowAbsolutePath": @NO,
      @"allowParentTraversal": @NO,
      @"allowSymlinkEscape": @NO
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static EJSContext * make_context(NSString *root, EJSRuntime **runtimeOut, NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  configuration.contextDefaults = @{
    EJSFSWatchConfigurationKey: fswatch_json(root)
  };
  EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
  EJSContext *context = [runtime createContextWithID:@"app://tests/fswatch" error:error];
  if (context == nil) {
    [runtime invalidate];
    return nil;
  }
  if (runtimeOut != NULL) *runtimeOut = runtime;
  return context;
}

static BOOL run_script(EJSContext *context,
                       TestReportProvider *reportProvider,
                       NSString *source,
                       NSString *filename,
                       NSString *expected,
                       NSError **error) {
  [reportProvider reset];
  if (![context evaluateScript:source filename:filename error:error]) {
    fprintf(stderr, "%s failed: %s\n", filename.UTF8String, (*error).localizedDescription.UTF8String);
    return NO;
  }
  return wait_for_report(reportProvider, expected);
}

int main(void) {
  @autoreleasepool {
    NSError *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ejs-fswatch-test-%@", NSUUID.UUID.UUIDString]];
    if (![fileManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:&error]) {
      fprintf(stderr, "failed to create fixture root: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSRuntime *runtime = nil;
    EJSContext *context = make_context(base, &runtime, &error);
    if (context == nil) {
      fprintf(stderr, "failed to create fswatch context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error] ||
        !EJSFSWatchInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install fswatch: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *watchedPath = [base stringByAppendingPathComponent:@"watched.txt"];
    if (![@"seed" writeToFile:watchedPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
      fprintf(stderr, "failed to seed watched file: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " let watcher;"
                     " watcher = await EJSFSWatch.watch('watched.txt', (type, path) => { watcher.close(); __ejs_native__.invoke('test', 'report', type + ':' + path); });"
                     " await __ejs_native__.invoke('test', 'report', 'watch-ready');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fswatch_change_setup.js",
                    @"watch-ready",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (![@"changed" writeToFile:watchedPath atomically:NO encoding:NSUTF8StringEncoding error:&error] ||
        !wait_for_report(reportProvider, @"change:watched.txt")) {
      return EXIT_FAILURE;
    }

    NSString *renamePath = [base stringByAppendingPathComponent:@"rename-source.txt"];
    NSString *renameDest = [base stringByAppendingPathComponent:@"rename-dest.txt"];
    if (![@"rename" writeToFile:renamePath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
      fprintf(stderr, "failed to seed rename file: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " let watcher;"
                     " watcher = await EJSFSWatch.watch('rename-source.txt', (type, path) => { watcher.close(); __ejs_native__.invoke('test', 'report', type + ':' + path); });"
                     " await __ejs_native__.invoke('test', 'report', 'rename-ready');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fswatch_rename_setup.js",
                    @"rename-ready",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (![fileManager moveItemAtPath:renamePath toPath:renameDest error:&error] ||
        !wait_for_report(reportProvider, @"rename:rename-source.txt")) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFSWatch.watch('.', () => {}, { recursive: true }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 6 ? 'recursive-unsupported' : 'recursive-bad:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'recursive-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fswatch_recursive.js",
                    @"recursive-unsupported",
                    &error)) {
      return EXIT_FAILURE;
    }

    [runtime invalidate];
    [fileManager removeItemAtPath:base error:nil];
  }

  printf("ejs_fswatch_apple_test PASS\n");
  return EXIT_SUCCESS;
}
