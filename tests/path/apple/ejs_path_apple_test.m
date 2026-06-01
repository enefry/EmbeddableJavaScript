#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSPathApple.h"

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

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
  if (result != 0) {
    fprintf(stderr, "timed out waiting for report: expected=%s last=%s\n",
            expected.UTF8String,
            provider.lastMessage.UTF8String);
    return NO;
  }
  if (![provider.lastMessage isEqualToString:expected]) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n",
            expected.UTF8String,
            provider.lastMessage.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_path_install_requires_context(void) {
  EJSContext *missingContext = nil;
  NSError *installError = nil;
  if (EJSPathInstallIntoContext(missingContext, &installError)) {
    fprintf(stderr, "EJSPathInstallIntoContext unexpectedly accepted nil context\n");
    return NO;
  }
  if (installError == nil ||
      ![installError.domain isEqualToString:EJSRuntimeErrorDomain] ||
      installError.code != EJSRuntimeErrorCodeInvalidArgument ||
      [installError.localizedDescription rangeOfString:@"Context is required"].location == NSNotFound) {
    fprintf(stderr, "unexpected nil-context EJSPath error: %s\n", installError.localizedDescription.UTF8String);
    return NO;
  }
  if (EJSPathInstallIntoContext(missingContext, NULL)) {
    fprintf(stderr, "EJSPathInstallIntoContext unexpectedly accepted nil context without error output\n");
    return NO;
  }
  return YES;
}

static BOOL expect_path_install_evaluate_failure(EJSRuntime *runtime) {
  NSError *error = nil;
  EJSContext *lockedContext = [runtime createContextWithID:@"app://tests/path/locked" error:&error];
  if (lockedContext == nil) {
    fprintf(stderr, "failed to create locked path context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  NSString *lockScript =
    @"Object.defineProperty(globalThis, 'EJSPath', { configurable: false, value: 1 });";
  if (![lockedContext evaluateScript:lockScript filename:@"path_lock.js" error:&error]) {
    fprintf(stderr, "failed to lock EJSPath global: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  error = nil;
  if (EJSPathInstallIntoContext(lockedContext, &error)) {
    fprintf(stderr, "EJSPathInstallIntoContext unexpectedly overwrote a locked global\n");
    return NO;
  }
  if (error == nil) {
    fprintf(stderr, "EJSPathInstallIntoContext failed without an NSError for locked global\n");
    return NO;
  }
  return YES;
}

#ifdef EJS_TEST
static BOOL expect_path_install_rejects_invalid_bundle(EJSRuntime *runtime) {
  NSError *error = nil;
  EJSContext *invalidContext = [runtime createContextWithID:@"app://tests/path/invalid-bundle" error:&error];
  if (invalidContext == nil) {
    fprintf(stderr, "failed to create invalid path bundle context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  const unsigned char invalidScript[] = { 0xff };
  error = nil;
  if (EJSPathInstallBundledScriptForTesting(invalidContext,
                                           "invalid_path_bundle.js",
                                           invalidScript,
                                           sizeof(invalidScript),
                                           &error)) {
    fprintf(stderr, "EJSPathInstallBundledScriptForTesting unexpectedly accepted invalid UTF-8\n");
    return NO;
  }
  if (error == nil ||
      ![error.domain isEqualToString:EJSRuntimeErrorDomain] ||
      error.code != EJSRuntimeErrorCodeInvalidArgument ||
      [error.localizedDescription rangeOfString:@"valid UTF-8"].location == NSNotFound) {
    fprintf(stderr, "unexpected invalid bundle EJSPath error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  if (EJSPathInstallBundledScriptForTesting(invalidContext,
                                           "invalid_path_bundle.js",
                                           invalidScript,
                                           sizeof(invalidScript),
                                           NULL)) {
    fprintf(stderr, "EJSPathInstallBundledScriptForTesting unexpectedly accepted invalid UTF-8 without error output\n");
    return NO;
  }
  return YES;
}
#endif

int main(void) {
  @autoreleasepool {
    if (!expect_path_install_requires_context()) {
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
    configuration.runtimeName = @"ejs_path_apple_test";
    EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
    if (!expect_path_install_evaluate_failure(runtime)) {
      return EXIT_FAILURE;
    }
#ifdef EJS_TEST
    if (!expect_path_install_rejects_invalid_bundle(runtime)) {
      return EXIT_FAILURE;
    }
#endif

    EJSContext *context = [runtime createContextWithID:@"app://tests/path" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create path context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error]) {
      fprintf(stderr, "failed to register report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!EJSPathInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install EJSPath: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *script =
      @"(async function(){"
       " const p = EJSPath && EJSPath.posix;"
       " if (!p) throw new Error('missing EJSPath');"
       " const typeError = (fn, text) => { try { fn(); return false; } catch (e) { return e instanceof TypeError && String(e.message).indexOf(text) >= 0; } };"
       " const cwdCandidate = (globalThis.process && typeof globalThis.process.cwd === 'function') ? globalThis.process.cwd() : '/';"
       " const cwd = (typeof cwdCandidate === 'string' && cwdCandidate.length > 0 && cwdCandidate.charCodeAt(0) === 47) ? p.normalize(cwdCandidate) : '/';"
       " const expectedMixedLeft = p.relative('/a/b', p.join(cwd, 'a/c'));"
       " const expectedMixedRight = p.relative(p.join(cwd, 'a/b'), '/a/c');"
       " const checks = ["
       "   [p.normalize('/a//b/../c/') === '/a/c/', 'normalize collapse'],"
       "   [p.normalize('') === '.', 'normalize empty'],"
       "   [p.normalize('/') === '/', 'normalize root'],"
       "   [p.normalize('/../a') === '/a', 'normalize root parent'],"
       "   [p.normalize('a/../../b') === '../b', 'normalize above root'],"
       "   [p.normalize('a/') === 'a/', 'normalize trailing slash'],"
       "   [p.join() === '.', 'join no args'],"
       "   [p.join('', '') === '.', 'join empty parts'],"
       "   [p.join('/a', 'b', '..', 'c') === '/a/c', 'join normalize'],"
       "   [p.dirname('') === '.', 'dirname empty'],"
       "   [p.dirname('a') === '.', 'dirname relative leaf'],"
       "   [p.dirname('/') === '/', 'dirname root'],"
       "   [p.dirname('//a') === '//', 'dirname double slash'],"
       "   [p.dirname('///a') === '//', 'dirname triple slash'],"
       "   [p.dirname('/a/b/c.txt') === '/a/b', 'dirname nested'],"
       "   [p.basename('/') === '', 'basename root'],"
       "   [p.basename('/a/b/c.txt', '.txt') === 'c', 'basename suffix'],"
       "   [p.basename('file.txt', '.js') === 'file.txt', 'basename suffix mismatch'],"
       "   [p.extname('/a/b/c.txt') === '.txt', 'extname normal'],"
       "   [p.extname('file.') === '.', 'extname trailing dot'],"
       "   [p.extname('.profile') === '', 'extname dotfile'],"
       "   [p.extname('..') === '', 'extname parent'],"
       "   [p.isAbsolute('/a') === true, 'absolute true'],"
       "   [p.isAbsolute('a') === false, 'absolute false'],"
       "   [p.relative('/a/b', '/a/b') === '', 'relative same'],"
       "   [p.relative('/a/b', '/a/c/d') === '../c/d', 'relative absolute'],"
       "   [p.relative('a/b', 'a/b/c') === 'c', 'relative cwd'],"
       "   [p.relative('/a/b', 'a/c') === expectedMixedLeft, 'relative mixed left'],"
       "   [p.relative('a/b', '/a/c') === expectedMixedRight, 'relative mixed right'],"
       "   [typeError(() => p.normalize(1), 'path must be a string'), 'normalize rejects non-string'],"
       "   [typeError(() => p.join('a', 1), 'path must be a string'), 'join rejects non-string'],"
       "   [typeError(() => p.basename('a', 1), 'suffix must be a string'), 'basename rejects non-string suffix'],"
       "   [typeError(() => p.relative('a', 1), 'path must be a string'), 'relative rejects non-string']"
       " ];"
       " const failed = checks.find(item => !item[0]);"
       " if (failed) throw new Error('path check failed: ' + failed[1]);"
       " await __ejs_native__.invoke('test', 'report', 'path:ok');"
       "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));";

    if (![context evaluateScript:script filename:@"path_smoke.js" error:&error]) {
      fprintf(stderr, "path smoke failed to evaluate: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!wait_for_report(reportProvider, @"path:ok")) {
      return EXIT_FAILURE;
    }

    [runtime invalidate];
    return EXIT_SUCCESS;
  }
}
