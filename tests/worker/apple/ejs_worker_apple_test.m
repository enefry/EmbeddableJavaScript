#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSWorkerApple.h"

@interface TestReportProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, strong) NSMutableArray<NSString *> *messages;
@end

@implementation TestReportProvider
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"test";
    _semaphore = dispatch_semaphore_create(0);
    _messages = [[NSMutableArray alloc] init];
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
  if ([methodID isEqualToString:@"yield"]) {
    [responder finishWithData:nil error:nil];
    return [[EJSImmediateOperation alloc] init];
  }
  if (![methodID isEqualToString:@"report"]) {
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported report method")];
    return [[EJSImmediateOperation alloc] init];
  }

  NSString *message = payload != nil ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : @"";
  if (message == nil) {
    message = @"";
  }

  @synchronized (self) {
    [self.messages addObject:message];
  }
  dispatch_semaphore_signal(self.semaphore);
  [responder finishWithData:nil error:nil];
  return [[EJSImmediateOperation alloc] init];
}
@end

static NSString * wait_for_report(TestReportProvider *provider, NSTimeInterval timeout) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
  if (result != 0) {
    return nil;
  }

  @synchronized (provider) {
    if (provider.messages.count == 0u) {
      return @"";
    }
    NSString *message = provider.messages.firstObject;
    [provider.messages removeObjectAtIndex:0u];
    return message;
  }
}

static BOOL expect_report(TestReportProvider *provider, NSString *expected) {
  NSString *actual = wait_for_report(provider, 3.0);
  if (actual == nil) {
    fprintf(stderr, "timed out waiting report: %s\n", expected.UTF8String);
    return NO;
  }
  if (![actual isEqualToString:expected]) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n",
            expected.UTF8String,
            actual.UTF8String);
    return NO;
  }
  return YES;
}

static NSString * worker_config_json_with_limit(NSString *rootPath, NSNumber *maxQueuedMessages);

static NSString * worker_config_json(NSString *rootPath) {
  return worker_config_json_with_limit(rootPath, @64);
}

static NSString * worker_config_json_with_limit(NSString *rootPath, NSNumber *maxQueuedMessages) {
  NSDictionary *config = @{
    @"version": @1,
    @"defaultRoot": @"app",
    @"roots": @{
      @"app": @{
        @"path": rootPath,
        @"permissions": @[ @"read" ]
      }
    },
    @"scripts": @{
      @"echo": @{
        @"root": @"app",
        @"path": @"workers/echo.js",
        @"type": @"classic"
      },
      @"blocker": @{
        @"root": @"app",
        @"path": @"workers/blocker.js",
        @"type": @"classic"
      },
      @"spammer": @{
        @"root": @"app",
        @"path": @"workers/spammer.js",
        @"type": @"classic"
      },
      @"startup-blocker": @{
        @"root": @"app",
        @"path": @"workers/startup_blocker.js",
        @"type": @"classic"
      },
      @"startup-messenger": @{
        @"root": @"app",
        @"path": @"workers/startup_messenger.js",
        @"type": @"classic"
      },
      @"message-blocker": @{
        @"root": @"app",
        @"path": @"workers/message_blocker.js",
        @"type": @"classic"
      },
      @"close-flush": @{
        @"root": @"app",
        @"path": @"workers/close_flush.js",
        @"type": @"classic"
      },
      @"rejecter": @{
        @"root": @"app",
        @"path": @"workers/rejecter.js",
        @"type": @"classic"
      }
    },
    @"inlineScripts": @{
      @"inline-echo": @{
        @"source": @"onmessage = function(event) { postMessage({ inline: event.data }); };",
        @"type": @"classic"
      }
    },
    @"pathPolicy": @{
      @"allowAbsolutePath": @NO,
      @"allowParentTraversal": @NO,
      @"allowSymlinkEscape": @NO
    },
    @"limits": @{
      @"maxWorkers": @4,
      @"maxQueuedMessages": maxQueuedMessages ?: @64,
      @"maxMessageBytes": @1048576,
      @"maxSourceBytes": @1048576,
      @"startupTimeoutMs": @5000,
      @"terminationTimeoutMs": @2000
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL evaluate_script(EJSContext *context, NSString *source, NSString *filename, NSError **error) {
  if (![context evaluateScript:source filename:filename error:error]) {
    fprintf(stderr, "%s failed: %s\n",
            filename.UTF8String,
            ((*error).localizedDescription ?: @"unknown").UTF8String);
    return NO;
  }
  return YES;
}

int main(void) {
  @autoreleasepool {
    NSError *error = nil;

    EJSRuntime *invalidRuntime = [[EJSRuntime alloc] init];
    EJSContext *invalidContext = [invalidRuntime createContextWithID:@"app://tests/worker-invalid" error:&error];
    if (invalidContext == nil) {
      fprintf(stderr, "failed to create invalid context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (EJSWorkerInstallIntoContext(invalidContext, &error)) {
      fprintf(stderr, "worker install unexpectedly succeeded without ejs.worker config\n");
      return EXIT_FAILURE;
    }
    [invalidRuntime invalidate];
#ifdef EJS_TEST
    error = nil;
    EJSContext *nilContext = nil;
    if (EJSWorkerInstallIntoContext(nilContext, &error) || error == nil ||
        [error.localizedDescription containsString:@"Context is required"] == NO) {
      fprintf(stderr, "worker nil context install should fail with context error\n");
      return EXIT_FAILURE;
    }
    error = nil;
    NSString *nilRootPath = nil;
    if (EJSWorkerAppleTestRunInternalCoverage(nilRootPath, &error) || error == nil ||
        [error.localizedDescription containsString:@"rootPath is required"] == NO) {
      fprintf(stderr, "worker internal coverage helper should reject a nil root path\n");
      return EXIT_FAILURE;
    }
    error = nil;
#endif

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"ejs-worker-test-%@", NSUUID.UUID.UUIDString]];
    NSString *workersDir = [base stringByAppendingPathComponent:@"workers"];
    if (![fileManager createDirectoryAtPath:workersDir
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error]) {
      fprintf(stderr, "failed to create workers fixture dir: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
#ifdef EJS_TEST
    if (!EJSWorkerAppleTestRunInternalCoverage(base, &error)) {
      fprintf(stderr, "worker internal coverage helper failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    error = nil;
#endif

    NSString *workerScript =
      @"onmessage = function(event) {"
       "  if (event.data && event.data.op === 'close') { close(); return; }"
       "  postMessage({ echo: event.data });"
       "};";
    NSString *workerPath = [workersDir stringByAppendingPathComponent:@"echo.js"];
    if (![workerScript writeToFile:workerPath
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:&error]) {
      fprintf(stderr, "failed to write worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *blockerScript =
      @"onmessage = function() {"
       "  const end = Date.now() + 1000;"
       "  while (Date.now() < end) {}"
       "};";
    NSString *blockerPath = [workersDir stringByAppendingPathComponent:@"blocker.js"];
    if (![blockerScript writeToFile:blockerPath
                          atomically:YES
                            encoding:NSUTF8StringEncoding
                               error:&error]) {
      fprintf(stderr, "failed to write blocker worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *rejecterScript = @"Promise.reject(new Error('worker-rejection'));";
    NSString *rejecterPath = [workersDir stringByAppendingPathComponent:@"rejecter.js"];
    if (![rejecterScript writeToFile:rejecterPath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:&error]) {
      fprintf(stderr, "failed to write rejecter worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *spammerScript =
      @"onmessage = function() {"
       "  const makeEnvelope = function(index) {"
       "    return { kind: 'message', version: 1, buffers: [], payload: { kind: 'object', value: [ [ 'index', { kind: 'number', value: index } ] ] } };"
       "  };"
       "  const first = JSON.stringify({ envelope: makeEnvelope(1) });"
       "  const second = JSON.stringify({ envelope: makeEnvelope(2) });"
       "  Promise.resolve(__ejs_native__.invoke('ejs.worker', 'postMessage', first, null)).catch(function() {});"
       "  Promise.resolve(__ejs_native__.invoke('ejs.worker', 'postMessage', second, null)).catch(function() {});"
       "};";
    NSString *spammerPath = [workersDir stringByAppendingPathComponent:@"spammer.js"];
    if (![spammerScript writeToFile:spammerPath
                          atomically:YES
                            encoding:NSUTF8StringEncoding
                               error:&error]) {
      fprintf(stderr, "failed to write spammer worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *startupBlockerScript =
      @"const end = Date.now() + 1000;"
       "while (Date.now() < end) {}"
       "onmessage = function() { postMessage({ done: true }); };";
    NSString *startupBlockerPath = [workersDir stringByAppendingPathComponent:@"startup_blocker.js"];
    if (![startupBlockerScript writeToFile:startupBlockerPath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&error]) {
      fprintf(stderr, "failed to write startup blocker worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *startupMessengerScript =
      @"postMessage({ ready: 'top-level' });"
       "onmessage = function(event) { postMessage({ echo: event.data }); };";
    NSString *startupMessengerPath = [workersDir stringByAppendingPathComponent:@"startup_messenger.js"];
    if (![startupMessengerScript writeToFile:startupMessengerPath
                                  atomically:YES
                                    encoding:NSUTF8StringEncoding
                                       error:&error]) {
      fprintf(stderr, "failed to write startup messenger worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *messageBlockerScript =
      @"onmessage = function(event) {"
       "  const end = Date.now() + 1000;"
       "  while (Date.now() < end) {}"
       "  postMessage({ done: event.data && event.data.index });"
       "};";
    NSString *messageBlockerPath = [workersDir stringByAppendingPathComponent:@"message_blocker.js"];
    if (![messageBlockerScript writeToFile:messageBlockerPath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&error]) {
      fprintf(stderr, "failed to write message blocker worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *closeFlushScript =
      @"onmessage = function() {"
       "  postMessage({ op: 'before-close' });"
       "  close();"
       "};";
    NSString *closeFlushPath = [workersDir stringByAppendingPathComponent:@"close_flush.js"];
    if (![closeFlushScript writeToFile:closeFlushPath
                            atomically:YES
                              encoding:NSUTF8StringEncoding
                                 error:&error]) {
      fprintf(stderr, "failed to write close flush worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSData *invalidUTF8 = [NSData dataWithBytes:(const uint8_t[]){ 0xff, 0xfe, 0xfd } length:3];
    NSString *invalidUTF8Path = [workersDir stringByAppendingPathComponent:@"invalid_utf8.js"];
    if (![invalidUTF8 writeToFile:invalidUTF8Path options:NSDataWritingAtomic error:&error]) {
      fprintf(stderr, "failed to write invalid UTF-8 worker fixture script: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    EJSRuntimeConfiguration *rollbackConfiguration = [[EJSRuntimeConfiguration alloc] init];
    rollbackConfiguration.contextDefaults = @{
      EJSWorkerConfigurationKey: worker_config_json(base)
    };
    EJSRuntime *rollbackRuntime = [[EJSRuntime alloc] initWithConfiguration:rollbackConfiguration];
    EJSContext *rollbackContext = [rollbackRuntime createContextWithID:@"app://tests/worker-install-rollback" error:&error];
    if (rollbackContext == nil) {
      fprintf(stderr, "failed to create worker rollback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *rollbackReportProvider = [[TestReportProvider alloc] init];
    if (![rollbackContext registerProvider:rollbackReportProvider error:&error]) {
      fprintf(stderr, "failed to register worker rollback report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![rollbackContext evaluateScript:
          @"Object.defineProperty(globalThis, 'Worker', { value: { marker: 'pre-worker' }, configurable: true, writable: false, enumerable: false });"
           "Object.defineProperty(globalThis, 'EJSWorker', { value: { marker: 'pre-ejs-worker' }, configurable: true, writable: true, enumerable: false });"
           "Object.defineProperty(globalThis, '__EJSWorkerDispatch', { value: { marker: 'pre-dispatch' }, configurable: true, writable: true, enumerable: false });"
           "Object.defineProperty(globalThis, '__EJSWorkerLastError', { value: { marker: 'pre-last-error' }, configurable: true, writable: true, enumerable: false });"
                            filename:@"worker_rollback_setup.js"
                               error:&error]) {
      fprintf(stderr, "failed to setup worker rollback globals: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSWorkerAppleTestSetInstallFailScriptIndex(0);
    NSError *rollbackInstallError = nil;
    BOOL rollbackInstallResult = EJSWorkerInstallIntoContext(rollbackContext, &rollbackInstallError);
    EJSWorkerAppleTestSetInstallFailScriptIndex(-1);
    if (rollbackInstallResult || rollbackInstallError == nil ||
        [rollbackInstallError.localizedDescription containsString:@"sentinel"] == NO) {
      fprintf(stderr, "worker rollback install should fail with sentinel error\n");
      return EXIT_FAILURE;
    }

    if (!evaluate_script(rollbackContext,
                         @"(async function(){"
                          " const workerDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'Worker');"
                          " const ejsWorkerDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'EJSWorker');"
                          " const dispatchDescriptor = Object.getOwnPropertyDescriptor(globalThis, '__EJSWorkerDispatch');"
                          " const lastErrorDescriptor = Object.getOwnPropertyDescriptor(globalThis, '__EJSWorkerLastError');"
                          " if (!workerDescriptor || workerDescriptor.writable !== false || !workerDescriptor.value || workerDescriptor.value.marker !== 'pre-worker') throw new Error('Worker rollback mismatch');"
                          " if (!ejsWorkerDescriptor || !ejsWorkerDescriptor.value || ejsWorkerDescriptor.value.marker !== 'pre-ejs-worker') throw new Error('EJSWorker rollback mismatch');"
                          " if (!dispatchDescriptor || !dispatchDescriptor.value || dispatchDescriptor.value.marker !== 'pre-dispatch') throw new Error('dispatch rollback mismatch');"
                          " if (!lastErrorDescriptor || !lastErrorDescriptor.value || lastErrorDescriptor.value.marker !== 'pre-last-error') throw new Error('last error rollback mismatch');"
                          " let providerRolledBack = false;"
                          " try { await __ejs_native__.invoke('ejs.worker', 'create', JSON.stringify({ specifier: 'echo' }), null); }"
                          " catch (error) { providerRolledBack = true; }"
                          " if (!providerRolledBack) throw new Error('worker provider rollback missing');"
                          " await __ejs_native__.invoke('test', 'report', 'worker:install-rollback');"
                          "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));",
                         @"worker_install_rollback.js",
                         &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(rollbackReportProvider, @"worker:install-rollback")) {
      return EXIT_FAILURE;
    }
    [rollbackRuntime invalidate];
#endif

    EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
    configuration.contextDefaults = @{
      EJSWorkerConfigurationKey: worker_config_json(base)
    };
    EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
    EJSContext *context = [runtime createContextWithID:@"app://tests/worker" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create worker context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error]) {
      fprintf(stderr, "failed to register report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!EJSWorkerInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install worker module: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *basicScript =
      @"(async function(){"
       "  const worker = new Worker('echo', { name: 'echo-worker' });"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  worker.onmessage = async (event) => {"
       "    if (!event.data || !event.data.echo || event.data.echo.op !== 'ping') {"
       "      await __ejs_native__.invoke('test', 'report', 'error:bad-echo');"
       "      return;"
       "    }"
       "    await __ejs_native__.invoke('test', 'report', 'basic:message');"
       "    worker.terminate();"
       "    worker.terminate();"
       "    await __ejs_native__.invoke('test', 'report', 'basic:terminated');"
       "  };"
       "  worker.postMessage({ op: 'ping' });"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, basicScript, @"worker_basic.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"basic:message") ||
        !expect_report(reportProvider, @"basic:terminated")) {
      return EXIT_FAILURE;
    }

    NSString *inlineScript =
      @"(async function(){"
       "  const worker = new Worker('inline-echo');"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  worker.onmessage = async (event) => {"
       "    if (!event.data || !event.data.inline || event.data.inline.op !== 'inline') {"
       "      await __ejs_native__.invoke('test', 'report', 'error:inline-mismatch');"
       "      return;"
       "    }"
       "    await __ejs_native__.invoke('test', 'report', 'inline:ok');"
       "    worker.terminate();"
       "  };"
       "  worker.postMessage({ op: 'inline' });"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, inlineScript, @"worker_inline.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"inline:ok")) {
      return EXIT_FAILURE;
    }

    NSString *transferScript =
      @"(async function(){"
       "  const worker = new Worker('echo', { name: 'transfer-worker' });"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  worker.onmessage = async (event) => {"
       "    const value = event.data && event.data.echo;"
       "    const bytes = new Uint8Array(value);"
       "    if (bytes.length !== 3 || bytes[0] !== 1 || bytes[1] !== 2 || bytes[2] !== 3) {"
       "      await __ejs_native__.invoke('test', 'report', 'error:transfer-mismatch');"
       "      return;"
       "    }"
       "    await __ejs_native__.invoke('test', 'report', 'transfer:ok');"
       "    worker.terminate();"
       "  };"
       "  const buffer = new ArrayBuffer(3);"
       "  new Uint8Array(buffer).set([1,2,3]);"
       "  worker.postMessage(buffer, [buffer]);"
       "  if (typeof buffer.transfer === 'function' && buffer.byteLength !== 0) {"
       "    throw new Error('transfer did not detach');"
       "  }"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, transferScript, @"worker_transfer.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"transfer:ok")) {
      return EXIT_FAILURE;
    }

    NSString *queueScript =
      @"(async function(){"
       "  const worker = new Worker('echo');"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  worker.onmessage = async (event) => {"
       "    if (!event.data || !event.data.echo || event.data.echo.op !== 'queued') {"
       "      await __ejs_native__.invoke('test', 'report', 'error:queue-mismatch');"
       "      return;"
       "    }"
       "    await __ejs_native__.invoke('test', 'report', 'queue:ok');"
       "    worker.terminate();"
       "  };"
       "  worker.postMessage({ op: 'queued' });"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, queueScript, @"worker_queue.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"queue:ok")) {
      return EXIT_FAILURE;
    }

    NSString *startupNonBlockingScript =
      @"(async function(){"
       "  const start = Date.now();"
       "  const worker = new Worker('startup-blocker');"
       "  const elapsed = Date.now() - start;"
       "  await worker._createPromise;"
       "  worker.terminate();"
       "  await worker._terminatedPromise;"
       "  if (elapsed < 500) {"
       "    await __ejs_native__.invoke('test', 'report', 'startup-nonblocking:ok');"
       "  } else {"
       "    await __ejs_native__.invoke('test', 'report', 'error:startup-blocked:' + elapsed);"
       "  }"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, startupNonBlockingScript, @"worker_startup_nonblocking.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"startup-nonblocking:ok")) {
      return EXIT_FAILURE;
    }

    NSString *parallelStartupScript =
      @"(async function(){"
       "  const start = Date.now();"
       "  const first = new Worker('startup-blocker');"
       "  const second = new Worker('startup-blocker');"
       "  await Promise.all([first._createPromise, second._createPromise]);"
       "  const elapsed = Date.now() - start;"
       "  first.terminate();"
       "  second.terminate();"
       "  await Promise.all([first._terminatedPromise, second._terminatedPromise]);"
       "  if (elapsed < 1700) {"
       "    await __ejs_native__.invoke('test', 'report', 'parallel-startup:ok');"
       "  } else {"
       "    await __ejs_native__.invoke('test', 'report', 'error:parallel-startup-serialized:' + elapsed);"
       "  }"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, parallelStartupScript, @"worker_parallel_startup.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"parallel-startup:ok")) {
      return EXIT_FAILURE;
    }

    NSString *parallelMessageDispatchScript =
      @"(async function(){"
       "  const first = new Worker('message-blocker');"
       "  const second = new Worker('message-blocker');"
       "  const seen = [];"
       "  const done = new Promise((resolve) => {"
       "    const record = (event) => {"
       "      seen.push(event.data && event.data.done);"
       "      if (seen.length === 2) { resolve(); }"
       "    };"
       "    first.onmessage = record;"
       "    second.onmessage = record;"
       "  });"
       "  first.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:first-message-blocker:' + event.message); };"
       "  second.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:second-message-blocker:' + event.message); };"
       "  await Promise.all([first._createPromise, second._createPromise]);"
       "  const start = Date.now();"
       "  first.postMessage({ index: 1 });"
       "  second.postMessage({ index: 2 });"
       "  await done;"
       "  const elapsed = Date.now() - start;"
       "  first.terminate();"
       "  second.terminate();"
       "  await Promise.all([first._terminatedPromise, second._terminatedPromise]);"
       "  if (seen.indexOf(1) !== -1 && seen.indexOf(2) !== -1 && elapsed < 1700) {"
       "    await __ejs_native__.invoke('test', 'report', 'parallel-message-dispatch:ok');"
       "  } else {"
       "    await __ejs_native__.invoke('test', 'report', 'error:parallel-message-dispatch:' + elapsed + ':' + JSON.stringify(seen));"
       "  }"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, parallelMessageDispatchScript, @"worker_parallel_message_dispatch.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"parallel-message-dispatch:ok")) {
      return EXIT_FAILURE;
    }

    NSString *startupMessageScript =
      @"(async function(){"
       "  const worker = new Worker('startup-messenger');"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  worker.onmessage = async (event) => {"
       "    if (event.data && event.data.ready === 'top-level') {"
       "      worker.terminate();"
       "      await worker._terminatedPromise;"
       "      await __ejs_native__.invoke('test', 'report', 'startup-message:ok');"
       "    } else {"
       "      await __ejs_native__.invoke('test', 'report', 'error:startup-message-mismatch');"
       "    }"
       "  };"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, startupMessageScript, @"worker_startup_message.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"startup-message:ok")) {
      return EXIT_FAILURE;
    }

    NSString *closeFlushTestScript =
      @"(async function(){"
       "  const worker = new Worker('close-flush');"
       "  const seen = [];"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  worker.onmessage = async (event) => {"
       "    seen.push(event.data && event.data.op);"
       "    for (let i = 0; i < 200; i++) {"
       "      await __ejs_native__.invoke('test', 'yield', '', null);"
       "      if (__EJSWorkerInternalActiveCount() === 0) {"
       "        break;"
       "      }"
       "    }"
       "    if (seen[0] === 'before-close' && __EJSWorkerInternalActiveCount() === 0) {"
       "      await __ejs_native__.invoke('test', 'report', 'close-flush:ok');"
       "    } else {"
       "      await __ejs_native__.invoke('test', 'report', 'error:close-flush:' + JSON.stringify(seen) + ':' + __EJSWorkerInternalActiveCount());"
       "    }"
       "  };"
       "  worker.postMessage({ go: true });"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, closeFlushTestScript, @"worker_close_flush.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"close-flush:ok")) {
      return EXIT_FAILURE;
    }

    NSString *closeScript =
      @"(async function(){"
       "  const worker = new Worker('echo');"
       "  worker.onerror = async (event) => { await __ejs_native__.invoke('test', 'report', 'error:' + event.message); };"
       "  await worker._createPromise;"
       "  worker.postMessage({ op: 'close' });"
       "  await worker._sendChain;"
       "  for (let i = 0; i < 200; i++) {"
       "    await __ejs_native__.invoke('test', 'yield', '', null);"
       "    if (__EJSWorkerInternalActiveCount() === 0) {"
       "      await __ejs_native__.invoke('test', 'report', 'close:ok');"
       "      return;"
       "    }"
       "  }"
       "  await __ejs_native__.invoke('test', 'report', 'error:close-leak:' + __EJSWorkerInternalActiveCount());"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, closeScript, @"worker_close.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"close:ok")) {
      return EXIT_FAILURE;
    }

    NSString *rejectionScript =
      @"(async function(){"
       "  const worker = new Worker('rejecter');"
       "  worker.onerror = async (event) => {"
       "    if (String(event.message).indexOf('worker-rejection') === -1) {"
       "      await __ejs_native__.invoke('test', 'report', 'error:bad-rejection:' + event.message);"
       "      return;"
       "    }"
       "    await __ejs_native__.invoke('test', 'report', 'rejection:ok');"
       "    worker.terminate();"
       "  };"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, rejectionScript, @"worker_rejection.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"rejection:ok")) {
      return EXIT_FAILURE;
    }

    NSString *missingTakeScript =
      @"(async function(){"
       "  try {"
       "    await __ejs_native__.invoke('ejs.worker', 'takeMessage', JSON.stringify({ workerID: 'missing-worker', direction: 'toParent', messageID: 'missing-message' }), null);"
       "    await __ejs_native__.invoke('test', 'report', 'error:missing-take-succeeded');"
       "  } catch (error) {"
       "    if (String(error && (error.message || error)).indexOf('Worker message is missing') !== -1) {"
       "      await __ejs_native__.invoke('test', 'report', 'missing-take:ok');"
       "    } else {"
       "      await __ejs_native__.invoke('test', 'report', 'error:missing-take:' + (error.message || error));"
       "    }"
       "  }"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, missingTakeScript, @"worker_missing_take.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"missing-take:ok")) {
      return EXIT_FAILURE;
    }

    NSString *asyncDispatchScript =
      @"(async function(){"
       "  const worker = new Worker('blocker');"
       "  await worker._createPromise;"
       "  const envelope = { kind: 'message', version: 1, buffers: [], payload: { kind: 'object', value: [] } };"
       "  const request = JSON.stringify({ workerID: worker._workerID, direction: 'toChild', envelope });"
       "  const start = Date.now();"
       "  await __ejs_native__.invoke('ejs.worker', 'postMessage', request, null);"
       "  const elapsed = Date.now() - start;"
       "  if (elapsed < 500) {"
       "    await __ejs_native__.invoke('test', 'report', 'async-dispatch:ok');"
       "  } else {"
       "    await __ejs_native__.invoke('test', 'report', 'error:async-dispatch-blocked:' + elapsed);"
       "  }"
       "  worker.terminate();"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, asyncDispatchScript, @"worker_async_dispatch.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"async-dispatch:ok")) {
      return EXIT_FAILURE;
    }

    NSString *nativeErrorScript =
      @"(async function(){"
       "  const invoke = (method, request, transfer) => __ejs_native__.invoke('ejs.worker', method, JSON.stringify(request), transfer === undefined ? null : transfer);"
       "  const expectReject = async (promise, needle) => {"
       "    let rejected = false;"
       "    try { await promise; } catch (e) {"
       "      rejected = true;"
       "      if (String(e && (e.message || e)).indexOf(needle) === -1) throw e;"
       "    }"
       "    if (!rejected) throw new Error('missing rejection: ' + needle);"
       "  };"
       "  await expectReject(__ejs_native__.invoke('ejs.worker', 'unsupportedMethod', '{}', null), 'Unsupported ejs.worker method');"
       "  await expectReject(__ejs_native__.invoke('ejs.worker', 'create', '', null), 'payload is required');"
       "  await expectReject(__ejs_native__.invoke('ejs.worker', 'create', '[]', null), 'JSON object');"
       "  await expectReject(invoke('create', {}), 'specifier');"
       "  await expectReject(invoke('create', { specifier: 'https://example.com/worker.js' }), 'URL scheme');"
       "  await expectReject(invoke('create', { specifier: '../escape.js' }), 'Parent traversal');"
       "  await expectReject(invoke('create', { specifier: '/tmp/worker.js' }), 'Absolute worker paths');"
       "  await expectReject(invoke('create', { specifier: 'workers/missing.js' }), 'missing.js');"
       "  await expectReject(invoke('create', { specifier: 'workers/invalid_utf8.js' }), 'valid UTF-8');"
       "  await expectReject(invoke('create', { specifier: 'workers/echo.js', options: { root: 'missing' } }), 'root is not allowed');"
       "  await expectReject(invoke('create', { specifier: 'echo', options: { type: 'shared' } }), 'Unsupported worker type');"
       "  await expectReject(invoke('start', {}), 'requires workerID');"
       "  await expectReject(invoke('start', { workerID: 'missing-worker' }), 'not running');"
       "  await expectReject(invoke('postMessage', { direction: 'toParent' }), 'direction=toChild');"
       "  await expectReject(invoke('postMessage', { direction: 'toChild', workerID: 'missing-worker', envelope: { kind: 'message' } }), 'not running');"
       "  await expectReject(invoke('postMessage', { direction: 'toChild', workerID: 'missing-worker' }), 'workerID and envelope');"
       "  await expectReject(invoke('takeMessage', { direction: 'toChild' }), 'direction=toParent');"
       "  await expectReject(invoke('takeMessage', { direction: 'toParent', workerID: 'missing-worker' }), 'workerID and messageID');"
       "  await expectReject(invoke('terminate', {}), 'requires workerID');"
       "  await invoke('terminate', { workerID: 'missing-worker' });"
       "  await __ejs_native__.invoke('test', 'report', 'native-worker-errors:ok');"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(context, nativeErrorScript, @"worker_native_errors.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(reportProvider, @"native-worker-errors:ok")) {
      return EXIT_FAILURE;
    }

    [runtime invalidate];

    EJSRuntimeConfiguration *smallQueueConfiguration = [[EJSRuntimeConfiguration alloc] init];
    smallQueueConfiguration.contextDefaults = @{
      EJSWorkerConfigurationKey: worker_config_json_with_limit(base, @1)
    };
    EJSRuntime *smallQueueRuntime = [[EJSRuntime alloc] initWithConfiguration:smallQueueConfiguration];
    EJSContext *smallQueueContext = [smallQueueRuntime createContextWithID:@"app://tests/worker-small-queue" error:&error];
    if (smallQueueContext == nil) {
      fprintf(stderr, "failed to create small queue worker context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *smallQueueReportProvider = [[TestReportProvider alloc] init];
    if (![smallQueueContext registerProvider:smallQueueReportProvider error:&error]) {
      fprintf(stderr, "failed to register small queue report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!EJSWorkerInstallIntoContext(smallQueueContext, &error)) {
      fprintf(stderr, "failed to install small queue worker module: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *nativeQueueLimitScript =
      @"(async function(){"
       "  const worker = new Worker('blocker');"
       "  await worker._createPromise;"
       "  const envelope = { kind: 'message', version: 1, buffers: [], payload: { kind: 'object', value: [] } };"
       "  const request = JSON.stringify({ workerID: worker._workerID, direction: 'toChild', envelope });"
       "  const first = __ejs_native__.invoke('ejs.worker', 'postMessage', request, null);"
       "  const second = __ejs_native__.invoke('ejs.worker', 'postMessage', request, null);"
       "  const results = await Promise.allSettled([first, second]);"
       "  if (results.some((result) => result.status === 'rejected' && String(result.reason && (result.reason.message || result.reason)).indexOf('maxQueuedMessages') !== -1)) {"
       "    await __ejs_native__.invoke('test', 'report', 'native-queue:ok');"
       "  } else {"
       "    await __ejs_native__.invoke('test', 'report', 'error:native-queue-missing');"
       "  }"
       "  worker.terminate();"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(smallQueueContext, nativeQueueLimitScript, @"worker_native_queue_limit.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(smallQueueReportProvider, @"native-queue:ok")) {
      return EXIT_FAILURE;
    }

    NSString *nativeParentQueueLimitScript =
      @"(async function(){"
       "  const worker = new Worker('spammer');"
       "  const seen = [];"
       "  worker.onmessage = (event) => { seen.push(event.data && event.data.index); };"
       "  worker.onerror = (event) => { seen.push('error:' + event.message); };"
       "  await worker._createPromise;"
       "  worker.postMessage({ go: true });"
       "  await worker._sendChain;"
       "  const deadline = Date.now() + 2500;"
       "  while (Date.now() < deadline && seen.indexOf(1) === -1 && seen.indexOf(2) === -1) {"
       "    await __ejs_native__.invoke('test', 'yield', '', null);"
       "  }"
       "  for (let i = 0; i < 20; i++) {"
       "    await __ejs_native__.invoke('test', 'yield', '', null);"
       "  }"
       "  if (seen.indexOf(1) !== -1 && seen.indexOf(2) === -1) {"
       "    await __ejs_native__.invoke('test', 'report', 'native-parent-queue:ok');"
       "  } else {"
       "    await __ejs_native__.invoke('test', 'report', 'error:native-parent-queue:' + JSON.stringify(seen));"
       "  }"
       "  worker.terminate();"
       "})().catch((error) => __ejs_native__.invoke('test', 'report', 'error:' + error.message));";

    if (!evaluate_script(smallQueueContext, nativeParentQueueLimitScript, @"worker_native_parent_queue_limit.js", &error)) {
      return EXIT_FAILURE;
    }
    if (!expect_report(smallQueueReportProvider, @"native-parent-queue:ok")) {
      return EXIT_FAILURE;
    }
    [smallQueueRuntime invalidate];

    [fileManager removeItemAtPath:base error:nil];
  }

  printf("ejs_worker_apple_test PASS\n");
  return EXIT_SUCCESS;
}
