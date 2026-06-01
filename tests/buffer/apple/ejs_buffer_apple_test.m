#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSBufferApple.h"

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

static BOOL expect_buffer_install_requires_context(void) {
  EJSContext *missingContext = nil;
  NSError *installError = nil;
  if (EJSBufferInstallIntoContext(missingContext, &installError)) {
    fprintf(stderr, "EJSBufferInstallIntoContext unexpectedly accepted nil context\n");
    return NO;
  }
  if (installError == nil ||
      ![installError.domain isEqualToString:EJSRuntimeErrorDomain] ||
      installError.code != EJSRuntimeErrorCodeInvalidArgument ||
      [installError.localizedDescription rangeOfString:@"Context is required"].location == NSNotFound) {
    fprintf(stderr, "unexpected nil-context EJSBuffer error: %s\n", installError.localizedDescription.UTF8String);
    return NO;
  }
  if (EJSBufferInstallIntoContext(missingContext, NULL)) {
    fprintf(stderr, "EJSBufferInstallIntoContext unexpectedly accepted nil context without error output\n");
    return NO;
  }
  return YES;
}

static BOOL expect_buffer_install_evaluate_failure(EJSRuntime *runtime) {
  NSError *error = nil;
  EJSContext *lockedContext = [runtime createContextWithID:@"app://tests/buffer/locked" error:&error];
  if (lockedContext == nil) {
    fprintf(stderr, "failed to create locked buffer context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  NSString *lockScript =
    @"Object.defineProperty(globalThis, 'EJSBinary', { configurable: false, value: 1 });";
  if (![lockedContext evaluateScript:lockScript filename:@"buffer_lock.js" error:&error]) {
    fprintf(stderr, "failed to lock EJSBinary global: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  error = nil;
  if (EJSBufferInstallIntoContext(lockedContext, &error)) {
    fprintf(stderr, "EJSBufferInstallIntoContext unexpectedly overwrote a locked global\n");
    return NO;
  }
  if (error == nil) {
    fprintf(stderr, "EJSBufferInstallIntoContext failed without an NSError for locked global\n");
    return NO;
  }
  return YES;
}

#ifdef EJS_TEST
static BOOL expect_buffer_install_rejects_invalid_bundle(EJSRuntime *runtime) {
  NSError *error = nil;
  EJSContext *invalidContext = [runtime createContextWithID:@"app://tests/buffer/invalid-bundle" error:&error];
  if (invalidContext == nil) {
    fprintf(stderr, "failed to create invalid buffer bundle context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  const unsigned char invalidScript[] = { 0xff };
  error = nil;
  if (EJSBufferInstallBundledScriptForTesting(invalidContext,
                                             "invalid_buffer_bundle.js",
                                             invalidScript,
                                             sizeof(invalidScript),
                                             &error)) {
    fprintf(stderr, "EJSBufferInstallBundledScriptForTesting unexpectedly accepted invalid UTF-8\n");
    return NO;
  }
  if (error == nil ||
      ![error.domain isEqualToString:EJSRuntimeErrorDomain] ||
      error.code != EJSRuntimeErrorCodeInvalidArgument ||
      [error.localizedDescription rangeOfString:@"valid UTF-8"].location == NSNotFound) {
    fprintf(stderr, "unexpected invalid bundle EJSBuffer error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  if (EJSBufferInstallBundledScriptForTesting(invalidContext,
                                             "invalid_buffer_bundle.js",
                                             invalidScript,
                                             sizeof(invalidScript),
                                             NULL)) {
    fprintf(stderr, "EJSBufferInstallBundledScriptForTesting unexpectedly accepted invalid UTF-8 without error output\n");
    return NO;
  }
  return YES;
}
#endif

int main(void) {
  @autoreleasepool {
    if (!expect_buffer_install_requires_context()) {
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
    configuration.runtimeName = @"ejs_buffer_apple_test";
    EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
    if (!expect_buffer_install_evaluate_failure(runtime)) {
      return EXIT_FAILURE;
    }
#ifdef EJS_TEST
    if (!expect_buffer_install_rejects_invalid_bundle(runtime)) {
      return EXIT_FAILURE;
    }
#endif

    EJSContext *context = [runtime createContextWithID:@"app://tests/buffer" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create buffer context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error]) {
      fprintf(stderr, "failed to register report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!EJSBufferInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install EJSBinary: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *script =
      @"(async function(){"
       " const b = EJSBinary;"
       " if (!b) throw new Error('missing EJSBinary');"
       " const typeError = (fn, text) => { try { fn(); return false; } catch (e) { return e instanceof TypeError && String(e.message).indexOf(text) >= 0; } };"
       " const hello = b.fromString('hello', 'utf8');"
       " const unicode = b.fromString('hi \\uD83D\\uDC4B', 'utf-8');"
       " const sliced = new Uint8Array([0, 1, 2, 3]).subarray(1, 3);"
       " const combined = b.concat([hello, new Uint8Array([33])]);"
       " let invalidHex = false;"
       " let invalidHexChars = false;"
       " let invalidBase64 = false;"
       " let invalidBase64Chars = false;"
       " let invalidBase64Padding = false;"
       " try { b.fromHex('abc'); } catch (e) { invalidHex = true; }"
       " try { b.fromHex('0g'); } catch (e) { invalidHexChars = true; }"
       " try { b.fromBase64('abcde'); } catch (e) { invalidBase64 = true; }"
       " try { b.fromBase64('!!!!'); } catch (e) { invalidBase64Chars = true; }"
       " try { b.fromBase64('ab=c'); } catch (e) { invalidBase64Padding = true; }"
       " const checks = ["
       "   [hello instanceof Uint8Array, 'fromString returns Uint8Array'],"
       "   [b.toString(hello, 'utf8') === 'hello', 'utf8 roundtrip'],"
       "   [b.toString(b.fromString('hello')) === 'hello', 'default encoding'],"
       "   [b.toString(unicode, 'utf8') === 'hi \\uD83D\\uDC4B', 'unicode roundtrip'],"
       "   [b.toString(b.fromString('\\uD800')) === '\\uFFFD', 'lone high surrogate'],"
       "   [b.toString(b.fromString('\\uDC00')) === '\\uFFFD', 'lone low surrogate'],"
       "   [b.toBase64(hello) === 'aGVsbG8=', 'toBase64 five bytes'],"
       "   [b.toBase64(new Uint8Array([102])) === 'Zg==', 'toBase64 one byte'],"
       "   [b.toBase64(new Uint8Array([102, 111])) === 'Zm8=', 'toBase64 two bytes'],"
       "   [b.toString(b.fromBase64('aGVsbG8')) === 'hello', 'base64 no padding'],"
       "   [b.toString(b.fromBase64('Zg')) === 'f', 'base64 remainder two'],"
       "   [b.toString(b.fromBase64('Zm8')) === 'fo', 'base64 remainder three'],"
       "   [b.toString(b.fromBase64('aGVsbG8=')) === 'hello', 'base64 padded'],"
       "   [b.fromBase64('').byteLength === 0, 'base64 empty'],"
       "   [b.toString(b.fromBase64(' Z m 8= ')) === 'fo', 'base64 whitespace'],"
       "   [b.toHex(hello) === '68656c6c6f', 'toHex'],"
       "   [b.toString(hello, 'hex') === '68656c6c6f', 'toString hex'],"
       "   [b.toString(hello, 'base64') === 'aGVsbG8=', 'toString base64'],"
       "   [b.toString(b.fromString('6869', 'hex')) === 'hi', 'fromString hex'],"
       "   [b.toString(b.fromString('aGk=', 'base64')) === 'hi', 'fromString base64'],"
       "   [b.toString(b.fromHex('68 65 6c 6c 6f')) === 'hello', 'fromHex whitespace'],"
       "   [b.toString(b.fromHex('68656c6c6f')) === 'hello', 'fromHex'],"
       "   [b.toHex(sliced) === '0102', 'typed array slice'],"
       "   [b.toHex(new Uint8Array([1, 2]).buffer) === '0102', 'ArrayBuffer input'],"
       "   [b.toString(new Uint8Array([0xe2, 0x82])) === '\\uFFFD', 'truncated three byte utf8'],"
       "   [b.toString(new Uint8Array([0xf0, 0x9f])) === '\\uFFFD', 'truncated four byte utf8'],"
       "   [b.toString(new Uint8Array([0xc0, 0x80])) === '\\uFFFD\\uFFFD', 'invalid utf8 bytes'],"
       "   [b.toString(combined) === 'hello!', 'concat'],"
       "   [b.concat([]).byteLength === 0, 'concat empty'],"
       "   [b.equals(hello, b.fromBase64('aGVsbG8=')), 'equals true'],"
       "   [!b.equals(hello, combined), 'equals false'],"
       "   [b.compare(new Uint8Array([2]), new Uint8Array([1])) === 1, 'compare byte greater'],"
       "   [b.compare(new Uint8Array([1]), new Uint8Array([2])) === -1, 'compare byte smaller'],"
       "   [b.compare(hello, combined) === -1, 'compare shorter'],"
       "   [b.compare(combined, hello) === 1, 'compare longer'],"
       "   [b.compare(hello, b.fromHex('68656c6c6f')) === 0, 'compare equal'],"
       "   [invalidHex, 'invalid odd hex'],"
       "   [invalidHexChars, 'invalid hex chars'],"
       "   [invalidBase64, 'invalid base64 length'],"
       "   [invalidBase64Chars, 'invalid base64 chars'],"
       "   [invalidBase64Padding, 'invalid base64 padding'],"
       "   [typeError(() => b.fromString('x', 'latin1'), 'encoding must be utf8, base64, or hex'), 'fromString rejects encoding'],"
       "   [typeError(() => b.toString(123), 'bytes must be an ArrayBuffer or ArrayBufferView'), 'toString rejects bytes'],"
       "   [typeError(() => b.concat('x'), 'chunks must be an array'), 'concat rejects non-array'],"
       "   [typeError(() => b.concat([123]), 'bytes must be an ArrayBuffer or ArrayBufferView'), 'concat rejects chunk']"
       " ];"
       " const failed = checks.find(item => !item[0]);"
       " if (failed) throw new Error('buffer check failed: ' + failed[1]);"
       " await __ejs_native__.invoke('test', 'report', 'buffer:ok');"
       "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));";

    if (![context evaluateScript:script filename:@"buffer_smoke.js" error:&error]) {
      fprintf(stderr, "buffer smoke failed to evaluate: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!wait_for_report(reportProvider, @"buffer:ok")) {
      return EXIT_FAILURE;
    }

    [runtime invalidate];
    return EXIT_SUCCESS;
  }
}
