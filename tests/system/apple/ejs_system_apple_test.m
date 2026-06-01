#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSSystemApple.h"

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
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
  if (result != 0 || ![provider.lastMessage isEqualToString:expected]) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n", expected.UTF8String, provider.lastMessage.UTF8String);
    return NO;
  }
  return YES;
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

static NSString * json_string(NSString *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ?: @"" ] options:0 error:nil];
  NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (array.length < 2) {
    return @"\"\"";
  }
  return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

int main(void) {
  @autoreleasepool {
    NSError *error = nil;
    EJSRuntime *runtime = [[EJSRuntime alloc] init];
    EJSContext *context = [runtime createContextWithID:@"app://tests/system" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error] ||
        !EJSSystemInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install system module: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *oldCWD = [fileManager currentDirectoryPath];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ejs-system-test-%@", NSUUID.UUID.UUIDString]];
    if (![fileManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:&error]) {
      fprintf(stderr, "failed to create cwd fixture: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *script = [NSString stringWithFormat:
      @"(async function(){"
       " if (!globalThis.EJSSystem || typeof EJSSystem.cwd !== 'function' || typeof EJSSystem.getenv !== 'function') throw new Error('missing system');"
       " const before = await EJSSystem.cwd();"
       " await EJSSystem.chdir(%@);"
       " const changed = await EJSSystem.cwd();"
       " await EJSSystem.chdir(%@);"
       " await EJSSystem.setenv('EJS_SYSTEM_TEST_VALUE', 'phase1');"
       " const value = await EJSSystem.getenv('EJS_SYSTEM_TEST_VALUE');"
       " await EJSSystem.unsetenv('EJS_SYSTEM_TEST_VALUE');"
       " const missing = await EJSSystem.getenv('EJS_SYSTEM_TEST_VALUE');"
       " const env = await EJSSystem.env();"
       " const pid = await EJSSystem.pid();"
       " const ppid = await EJSSystem.ppid();"
       " const home = await EJSSystem.homeDir();"
       " const tmp = await EJSSystem.tmpDir();"
       " const exe = await EJSSystem.exePath();"
       " const host = await EJSSystem.hostName();"
       " const platform = await EJSSystem.platform();"
       " const arch = await EJSSystem.arch();"
       " const uname = await EJSSystem.uname();"
       " const uptime = await EJSSystem.uptime();"
       " const load = await EJSSystem.loadAvg();"
       " const parallelism = await EJSSystem.availableParallelism();"
       " const cpu = await EJSSystem.cpuInfo();"
       " const nets = await EJSSystem.networkInterfaces();"
       " const user = await EJSSystem.userInfo();"
       " const ok = before.length > 0 && changed.indexOf('ejs-system-test-') >= 0 && value === 'phase1' && missing === null && env &&"
       "   pid > 0 && ppid >= 0 && home.length > 0 && tmp.length > 0 && exe.length > 0 && host.length > 0 &&"
       "   platform === 'darwin' && arch.length > 0 && uname && uname.sysname && uptime >= 0 &&"
       "   Array.isArray(load) && load.length === 3 && parallelism >= 1 && Array.isArray(cpu) && cpu.length >= 1 &&"
       "   nets && typeof nets === 'object' && user && typeof user.uid === 'number';"
       " await __ejs_native__.invoke('test', 'report', ok ? 'system-ok' : 'system-bad');"
       "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
      json_string(base),
      json_string(oldCWD)];

    if (!run_script(context, reportProvider, script, @"system.js", @"system-ok", &error)) {
      return EXIT_FAILURE;
    }

    NSString *missingPath = [base stringByAppendingPathComponent:@"missing-dir"];
    NSString *negativeScript = [NSString stringWithFormat:
      @"(async function(){"
       " let missingDir = false;"
       " let badPath = false;"
       " let badName = false;"
       " let emptyName = false;"
       " try { await EJSSystem.chdir(%@); }"
       " catch (e) { missingDir = e && e.code === 1; }"
       " try { await EJSSystem.chdir(''); }"
       " catch (e) { badPath = e instanceof TypeError && String(e.message).indexOf('system path') >= 0; }"
       " try { await EJSSystem.getenv('BAD=NAME'); }"
       " catch (e) { badName = e instanceof TypeError && String(e.message).indexOf('environment variable name') >= 0; }"
       " try { await EJSSystem.setenv('', 'x'); }"
       " catch (e) { emptyName = e instanceof TypeError && String(e.message).indexOf('environment variable name') >= 0; }"
       " await __ejs_native__.invoke('test', 'report', missingDir && badPath && badName && emptyName ? 'system-errors-ok' : 'system-errors-bad');"
       "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
      json_string(missingPath)];

    if (!run_script(context, reportProvider, negativeScript, @"system_errors.js", @"system-errors-ok", &error)) {
      return EXIT_FAILURE;
    }

    [fileManager changeCurrentDirectoryPath:oldCWD];
    [fileManager removeItemAtPath:base error:nil];
    [runtime invalidate];
  }

  printf("ejs_system_apple_test PASS\n");
  return EXIT_SUCCESS;
}
