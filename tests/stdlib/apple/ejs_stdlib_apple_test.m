#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSHashingApple.h"
#import "EJSIPAddrApple.h"
#import "EJSUUIDApple.h"

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

static BOOL expect_uuid_install_requires_context(void) {
  EJSContext *missingContext = nil;
  NSError *installError = nil;
  if (EJSUUIDInstallIntoContext(missingContext, &installError)) {
    fprintf(stderr, "EJSUUIDInstallIntoContext unexpectedly accepted nil context\n");
    return NO;
  }
  if (installError == nil ||
      ![installError.domain isEqualToString:EJSRuntimeErrorDomain] ||
      installError.code != EJSRuntimeErrorCodeInvalidArgument ||
      [installError.localizedDescription rangeOfString:@"Context is required"].location == NSNotFound) {
    fprintf(stderr, "unexpected nil-context EJSUUID error: %s\n", installError.localizedDescription.UTF8String);
    return NO;
  }
  if (EJSUUIDInstallIntoContext(missingContext, NULL)) {
    fprintf(stderr, "EJSUUIDInstallIntoContext unexpectedly accepted nil context without error output\n");
    return NO;
  }
  return YES;
}

static BOOL expect_uuid_install_evaluate_failure(EJSRuntime *runtime) {
  NSError *error = nil;
  EJSContext *lockedContext = [runtime createContextWithID:@"app://tests/stdlib/uuid/locked" error:&error];
  if (lockedContext == nil) {
    fprintf(stderr, "failed to create UUID locked context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  NSString *lockScript =
    @"Object.defineProperty(globalThis, 'EJSUUID', {"
     " configurable: true,"
     " get() { return undefined; },"
     " set() { throw new Error('locked uuid global'); }"
     "});";
  if (![lockedContext evaluateScript:lockScript filename:@"uuid_lock.js" error:&error]) {
    fprintf(stderr, "failed to lock EJSUUID global: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  error = nil;
  if (EJSUUIDInstallIntoContext(lockedContext, &error)) {
    fprintf(stderr, "EJSUUIDInstallIntoContext unexpectedly installed over a throwing EJSUUID setter\n");
    return NO;
  }
  if (error == nil) {
    fprintf(stderr, "EJSUUIDInstallIntoContext failed without an NSError for throwing EJSUUID setter\n");
    return NO;
  }
  return YES;
}

#ifdef EJS_TEST
static BOOL expect_uuid_install_failure_mode(EJSRuntime *runtime,
                                             EJSUUIDInstallFailureModeForTesting mode,
                                             NSString *label) {
  NSError *error = nil;
  NSString *contextID = [NSString stringWithFormat:@"app://tests/stdlib/uuid/%@", label];
  EJSContext *failureContext = [runtime createContextWithID:contextID error:&error];
  if (failureContext == nil) {
    fprintf(stderr, "failed to create UUID failure context %s: %s\n",
            label.UTF8String,
            error.localizedDescription.UTF8String);
    return NO;
  }

  EJSUUIDSetInstallFailureModeForTesting(mode);
  error = nil;
  if (EJSUUIDInstallIntoContext(failureContext, &error)) {
    fprintf(stderr, "EJSUUIDInstallIntoContext unexpectedly accepted failure mode %s\n", label.UTF8String);
    return NO;
  }
  if (error == nil) {
    fprintf(stderr, "EJSUUIDInstallIntoContext failure mode %s did not set NSError\n", label.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_uuid_install_rejects_invalid_bundle(EJSRuntime *runtime) {
  NSError *error = nil;
  EJSContext *invalidContext = [runtime createContextWithID:@"app://tests/stdlib/uuid/invalid-bundle" error:&error];
  if (invalidContext == nil) {
    fprintf(stderr, "failed to create invalid UUID bundle context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  const unsigned char invalidScript[] = { 0xff };
  error = nil;
  if (EJSUUIDInstallBundledScriptForTesting(invalidContext,
                                           "invalid_uuid_bundle.js",
                                           invalidScript,
                                           sizeof(invalidScript),
                                           &error)) {
    fprintf(stderr, "EJSUUIDInstallBundledScriptForTesting unexpectedly accepted invalid UTF-8\n");
    return NO;
  }
  if (error == nil ||
      ![error.domain isEqualToString:EJSRuntimeErrorDomain] ||
      error.code != EJSRuntimeErrorCodeInvalidArgument ||
      [error.localizedDescription rangeOfString:@"valid UTF-8"].location == NSNotFound) {
    fprintf(stderr, "unexpected invalid bundle EJSUUID error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  if (EJSUUIDInstallBundledScriptForTesting(invalidContext,
                                           "invalid_uuid_bundle.js",
                                           invalidScript,
                                           sizeof(invalidScript),
                                           NULL)) {
    fprintf(stderr, "EJSUUIDInstallBundledScriptForTesting unexpectedly accepted invalid UTF-8 without error output\n");
    return NO;
  }
  return YES;
}
#endif

int main(void) {
  @autoreleasepool {
    if (!expect_uuid_install_requires_context()) {
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSRuntime *runtime = [[EJSRuntime alloc] init];
    if (!expect_uuid_install_evaluate_failure(runtime)) {
      return EXIT_FAILURE;
    }
#ifdef EJS_TEST
    if (!expect_uuid_install_failure_mode(runtime, EJSUUIDInstallFailureModeBeginForTesting, @"begin")) {
      return EXIT_FAILURE;
    }
    if (!expect_uuid_install_failure_mode(runtime, EJSUUIDInstallFailureModeRegisterProviderForTesting, @"register")) {
      return EXIT_FAILURE;
    }
    if (!expect_uuid_install_failure_mode(runtime, EJSUUIDInstallFailureModeCommitForTesting, @"commit")) {
      return EXIT_FAILURE;
    }
    if (!expect_uuid_install_rejects_invalid_bundle(runtime)) {
      return EXIT_FAILURE;
    }
#endif

    EJSContext *context = [runtime createContextWithID:@"app://tests/stdlib" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error] ||
        !EJSHashingInstallIntoContext(context, &error) ||
        !EJSUUIDInstallIntoContext(context, &error) ||
        !EJSIPAddrInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install stdlib modules: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " if (!globalThis.EJSHashing || !globalThis.EJSUUID || !globalThis.EJSIPAddr) throw new Error('missing stdlib');"
                     " const sha256 = await EJSHashing.sha256('abc');"
                     " const sha512 = await EJSHashing.sha512(new Uint8Array([97, 98, 99]));"
                     " const base64 = await EJSHashing.sha256('abc', { encoding: 'base64' });"
                     " const uuid = await EJSUUID.v4();"
                     " const uuid2 = await EJSUUID.randomUUID();"
                     " const upper = uuid.toUpperCase();"
                     " const wrongVersion = uuid.slice(0, 14) + '6' + uuid.slice(15);"
                     " const wrongVariant = uuid.slice(0, 19) + '7' + uuid.slice(20);"
                     " const ok = sha256 === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' &&"
                     "   sha512 === 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f' &&"
                     "   base64 === 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=' &&"
                     "   EJSUUID.validate(uuid) && EJSUUID.validate(uuid2) && uuid !== uuid2 &&"
                     "   uuid.charAt(14) === '4' && '89ab'.indexOf(uuid.charAt(19)) >= 0 &&"
                     "   EJSUUID.validate(upper) && !EJSUUID.validate(wrongVersion) && !EJSUUID.validate(wrongVariant) &&"
                     "   !EJSUUID.validate('not-a-uuid') && !EJSUUID.validate(null) && !EJSUUID.validate({});"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'stdlib-ok' : 'stdlib-bad:' + sha256 + ':' + uuid);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"stdlib.js",
                    @"stdlib-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const ipv4 = EJSIPAddr.parse('192.0.2.1');"
                     " const ipv6 = EJSIPAddr.parse('2001:0db8:0:0:0:0:0:1');"
                     " const scoped = EJSIPAddr.parse('fe80::1%lo0');"
                     " const cidr = EJSIPAddr.parseCIDR('127.0.0.0/8');"
                     " const ok = EJSIPAddr.isValidIPv4('127.0.0.1') &&"
                     "   !EJSIPAddr.isValidIPv4('01.0.0.1') &&"
                     "   EJSIPAddr.isValidIPv6('::ffff:192.0.2.128') &&"
                     "   EJSIPAddr.isValidIPv6('fe80::1%lo0') &&"
                     "   EJSIPAddr.isValid('2001:db8::1') &&"
                     "   !EJSIPAddr.isValid('not an address') &&"
                     "   EJSIPAddr.isValidCIDR('127.0.0.0/8') &&"
                     "   !EJSIPAddr.isValidCIDR('127.0.0.0/33') &&"
                     "   ipv4.family === 4 && ipv4.normalized === '192.0.2.1' &&"
                     "   ipv6.family === 6 && ipv6.normalized === '2001:db8::1' &&"
                     "   scoped.scopeId === 'lo0' && scoped.normalized === 'fe80::1%lo0' &&"
                     "   cidr.normalized === '127.0.0.0/8' &&"
                     "   EJSIPAddr.contains(cidr, '127.0.0.1') &&"
                     "   !EJSIPAddr.contains(cidr, '128.0.0.1') &&"
                     "   EJSIPAddr.normalize('::ffff:192.0.2.128') === '::ffff:c000:280';"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'ipaddr-ok' : 'ipaddr-bad');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"ipaddr.js",
                    @"ipaddr-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " let unsupportedAlgorithm = false;"
                     " let badEncoding = false;"
                     " let unsupportedUUIDMethod = false;"
                     " try { await EJSHashing.digest('sha1', 'abc'); }"
                     " catch (e) { unsupportedAlgorithm = e && e.code === 6; }"
                     " try { await EJSHashing.sha256('abc', { encoding: 'binary' }); }"
                     " catch (e) { badEncoding = e instanceof TypeError && String(e.message).indexOf('hash encoding') >= 0; }"
                     " try { await __ejs_native__.invoke('ejs.uuid', 'unsupported', '{}', null); }"
                     " catch (e) { unsupportedUUIDMethod = e && e.code === 6 && String(e.message).indexOf('Unsupported ejs.uuid method') >= 0; }"
                     " await __ejs_native__.invoke('test', 'report', unsupportedAlgorithm && badEncoding && unsupportedUUIDMethod ? 'stdlib-errors-ok' : 'stdlib-errors-bad');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"stdlib_errors.js",
                    @"stdlib-errors-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    [runtime invalidate];
  }

  printf("ejs_stdlib_apple_test PASS\n");
  return EXIT_SUCCESS;
}
