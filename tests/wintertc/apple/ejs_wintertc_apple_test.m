#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#import "EJSApplePlatform.h"
#import "EJSWinterTCApple.h"

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

@interface FakeFetchProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, assign) BOOL lastTransferWasNil;
@property (nonatomic, assign) NSUInteger lastTransferLength;
@property (nonatomic, copy) NSString *lastTransferText;
@property (nonatomic, copy) NSString *lastBodyKind;
@property (nonatomic, copy) NSString *lastSignalID;
@property (nonatomic, copy) NSString *lastCancelSignalID;
@property (nonatomic, assign) BOOL cancelCalled;
- (void)reset;
@end

@implementation FakeFetchProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"wintertc.fetch";
    [self reset];
  }
  return self;
}

- (void)reset {
  self.lastTransferWasNil = YES;
  self.lastTransferLength = 0;
  self.lastTransferText = @"";
  self.lastBodyKind = @"";
  self.lastSignalID = @"";
  self.lastCancelSignalID = @"";
  self.cancelCalled = NO;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
  (void)context;

  if ([methodID isEqualToString:@"start"]) {
    NSDictionary *request = nil;
    if (payload.length > 0) {
      id value = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
      if ([value isKindOfClass:[NSDictionary class]]) {
        request = (NSDictionary *)value;
      }
    }
    id bodyKind = request[@"bodyKind"];
    self.lastBodyKind = [bodyKind isKindOfClass:[NSString class]] ? bodyKind : @"";
    id signalID = request[@"signalId"];
    self.lastSignalID = [signalID isKindOfClass:[NSString class]] ? signalID : @"";
    self.lastTransferWasNil = transferBuffer == nil;
    self.lastTransferLength = transferBuffer.length;
    self.lastTransferText = transferBuffer != nil
        ? ([[NSString alloc] initWithData:transferBuffer encoding:NSUTF8StringEncoding] ?: @"")
        : @"";

    NSString *url = [request[@"url"] isKindOfClass:[NSString class]] ? request[@"url"] : @"";
    BOOL shouldDelay = [url hasSuffix:@"/abort"];
    NSData *response = [@"{\"streamId\":\"test-stream\",\"status\":204,\"statusText\":\"No Content\",\"headers\":{\"x-test\":\"ok\"}}"
        dataUsingEncoding:NSUTF8StringEncoding];
    if (shouldDelay) {
      __block BOOL cancelled = NO;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)),
                     dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (!cancelled) {
          [responder finishWithData:response error:nil];
        }
      });
      return [[EJSBlockOperation alloc] initWithCancelBlock:^{
        cancelled = YES;
      }];
    }

    [responder finishWithData:response error:nil];
    return [[EJSImmediateOperation alloc] init];
  }

  if ([methodID isEqualToString:@"pull"]) {
    [responder finishWithData:[NSData data] error:nil];
    return [[EJSImmediateOperation alloc] init];
  }

  if ([methodID isEqualToString:@"cancel"]) {
    NSDictionary *request = nil;
    if (payload.length > 0) {
      id value = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
      if ([value isKindOfClass:[NSDictionary class]]) {
        request = (NSDictionary *)value;
      }
    }
    id signalID = request[@"signalId"];
    self.lastCancelSignalID = [signalID isKindOfClass:[NSString class]] ? signalID : @"";
    self.cancelCalled = YES;
    [responder finishWithData:nil error:nil];
    return [[EJSImmediateOperation alloc] init];
  }

  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                           @"Unsupported fetch method")];
  return [[EJSImmediateOperation alloc] init];
}

@end

@interface ShortRandomProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@end

@implementation ShortRandomProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"wintertc.crypto";
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
  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported random async method")];
  return [[EJSImmediateOperation alloc] init];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
  (void)payload;
  (void)transferBuffer;
  (void)context;

  if ([methodID isEqualToString:@"getRandomValues"]) {
    const uint8_t bytes[] = { 0x01, 0x02 };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
  }

  if (error != NULL) {
    *error = EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported random sync method");
  }
  return nil;
}

@end

@interface FakeClockProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, assign) NSUInteger callCount;
@end

@implementation FakeClockProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"wintertc.clock";
    _callCount = 0;
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
  [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported clock async method")];
  return [[EJSImmediateOperation alloc] init];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
  (void)payload;
  (void)transferBuffer;
  (void)context;

  if ([methodID isEqualToString:@"now"]) {
    self.callCount += 1;
    NSString *json = [NSString stringWithFormat:@"{\"timeOriginEpochMs\":1770000000000,\"nowMs\":%0.3f}",
                                                (double)self.callCount * 1.25];
    return [json dataUsingEncoding:NSUTF8StringEncoding];
  }

  if (error != NULL) {
    *error = EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported clock sync method");
  }
  return nil;
}

@end

@interface WinterTCLocalHTTPServer : NSObject
@property (nonatomic, assign, readonly) uint16_t port;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

@implementation WinterTCLocalHTTPServer {
  int _listenSocket;
  dispatch_queue_t _queue;
  BOOL _stopped;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _listenSocket = -1;
    _queue = dispatch_queue_create("ejs.wintertc.local-http", DISPATCH_QUEUE_CONCURRENT);
  }
  return self;
}

- (BOOL)start:(NSError **)error {
  _listenSocket = socket(AF_INET, SOCK_STREAM, 0);
  if (_listenSocket < 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    return NO;
  }

  int yes = 1;
  setsockopt(_listenSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;

  if (bind(_listenSocket, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
      listen(_listenSocket, 8) != 0) {
    int savedErrno = errno;
    close(_listenSocket);
    _listenSocket = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
    }
    return NO;
  }

  socklen_t len = sizeof(addr);
  if (getsockname(_listenSocket, (struct sockaddr *)&addr, &len) != 0) {
    int savedErrno = errno;
    close(_listenSocket);
    _listenSocket = -1;
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
    }
    return NO;
  }
  _port = ntohs(addr.sin_port);

  dispatch_async(_queue, ^{
    [self acceptLoop];
  });
  return YES;
}

- (void)stop {
  _stopped = YES;
  if (_listenSocket >= 0) {
    shutdown(_listenSocket, SHUT_RDWR);
    close(_listenSocket);
    _listenSocket = -1;
  }
}

- (void)dealloc {
  [self stop];
}

static BOOL WinterTCWriteAll(int fd, const void *bytes, size_t length) {
  const uint8_t *cursor = (const uint8_t *)bytes;
  size_t remaining = length;
  while (remaining > 0u) {
    ssize_t written = send(fd, cursor, remaining, 0);
    if (written <= 0) {
      return NO;
    }
    cursor += (size_t)written;
    remaining -= (size_t)written;
  }
  return YES;
}

static BOOL WinterTCWriteString(int fd, NSString *string) {
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  if (data.length > 0u) {
    return WinterTCWriteAll(fd, data.bytes, data.length);
  }
  return YES;
}

static BOOL WinterTCWriteChunkData(int fd, NSData *data) {
  if (!WinterTCWriteString(fd, [NSString stringWithFormat:@"%lx\r\n", (unsigned long)data.length])) {
    return NO;
  }
  if (data.length > 0u) {
    if (!WinterTCWriteAll(fd, data.bytes, data.length)) {
      return NO;
    }
  }
  return WinterTCWriteString(fd, @"\r\n");
}

static BOOL WinterTCWriteChunkString(int fd, NSString *string) {
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  return WinterTCWriteChunkData(fd, data);
}

static BOOL WinterTCWriteChunkedEnd(int fd) {
  return WinterTCWriteString(fd, @"0\r\n\r\n");
}

- (void)acceptLoop {
  while (!_stopped && _listenSocket >= 0) {
    int client = accept(_listenSocket, NULL, NULL);
    if (client < 0) {
      if (_stopped) {
        break;
      }
      continue;
    }

    dispatch_async(_queue, ^{
      [self handleClient:client];
    });
  }
}

- (void)handleClient:(int)client {
  @autoreleasepool {
#ifdef SO_NOSIGPIPE
    int noSigpipe = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
#endif

    NSMutableData *requestData = [NSMutableData data];
    uint8_t buffer[512];
    while (requestData.length < 8192u) {
      ssize_t n = recv(client, buffer, sizeof(buffer), 0);
      if (n <= 0) {
        close(client);
        return;
      }
      [requestData appendBytes:buffer length:(NSUInteger)n];
      NSString *requestText = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
      if ([requestText containsString:@"\r\n\r\n"]) {
        break;
      }
    }

    NSString *requestText = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *parts = [[requestText componentsSeparatedByString:@"\r\n"].firstObject ?: @"" componentsSeparatedByString:@" "];
    NSString *path = parts.count >= 2u ? parts[1] : @"/";

    if ([path isEqualToString:@"/redirect-once"]) {
      WinterTCWriteString(client, @"HTTP/1.1 302 Found\r\nLocation: /redirect-target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
      close(client);
      return;
    }

    if (!WinterTCWriteString(client, @"HTTP/1.1 200 OK\r\nContent-Type: text/plain;charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")) {
      close(client);
      return;
    }

    if ([path isEqualToString:@"/redirect-target"]) {
      if (WinterTCWriteChunkString(client, @"redirect-ok")) {
        WinterTCWriteChunkedEnd(client);
      }
      close(client);
      return;
    }

    if ([path isEqualToString:@"/stream-incremental"]) {
      NSMutableData *first = [NSMutableData dataWithLength:128u * 1024u];
      memset(first.mutableBytes, 'a', first.length);
      usleep(10000);
      if (!WinterTCWriteChunkData(client, first)) {
        close(client);
        return;
      }
      usleep(700000);
      if (!WinterTCWriteChunkString(client, @"tail")) {
        close(client);
        return;
      }
      usleep(300000);
      WinterTCWriteChunkedEnd(client);
      close(client);
      return;
    }

    if ([path isEqualToString:@"/stream-overflow"]) {
      NSMutableData *large = [NSMutableData dataWithLength:8192u];
      memset(large.mutableBytes, 'x', large.length);
      usleep(10000);
      if (!WinterTCWriteChunkData(client, large)) {
        close(client);
        return;
      }
      usleep(300000);
      WinterTCWriteChunkedEnd(client);
      close(client);
      return;
    }

    if ([path isEqualToString:@"/stream-cancel"]) {
      NSMutableData *first = [NSMutableData dataWithLength:65536u];
      memset(first.mutableBytes, 'c', first.length);
      usleep(10000);
      if (!WinterTCWriteChunkData(client, first)) {
        close(client);
        return;
      }
      usleep(500000);
      if (!WinterTCWriteChunkString(client, @"late-data")) {
        close(client);
        return;
      }
      WinterTCWriteChunkedEnd(client);
      close(client);
      return;
    }

    if (WinterTCWriteChunkString(client, @"ok")) {
      WinterTCWriteChunkedEnd(client);
    }
    close(client);
  }
}

@end

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
  return result == 0 && [provider.lastMessage isEqualToString:expected];
}

int main(void) {
  @autoreleasepool {
    EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
    configuration.runtimeName = @"ejs_wintertc_apple_test";
    EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];

    if (runtime == nil) {
      fprintf(stderr, "failed to create Apple runtime\n");
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSContext *context = [runtime createContextWithID:@"app://tests/wintertc-main" error:&error];
    if (context == nil) {
      fprintf(stderr, "failed to create WinterTC context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    FakeFetchProvider *fakeFetchProvider = [[FakeFetchProvider alloc] init];
    ShortRandomProvider *shortRandomProvider = [[ShortRandomProvider alloc] init];
    FakeClockProvider *fakeClockProvider = [[FakeClockProvider alloc] init];

    if (![context registerProvider:reportProvider error:&error] ||
        ![context registerProvider:fakeFetchProvider error:&error] ||
        ![context registerProvider:shortRandomProvider error:&error] ||
        ![context registerProvider:fakeClockProvider error:&error]) {
      fprintf(stderr, "failed to register WinterTC test providers: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    EJSContext *failureContext = [runtime createContextWithID:@"app://tests/wintertc-init-error"
                                                        error:&error];
    if (failureContext == nil) {
      fprintf(stderr, "failed to create WinterTC failure context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSError *installError = nil;
    EJSWinterTCAppleTestSetInitSource("throw new Error('wintertc init sentinel');");
    BOOL installResult = EJSWinterTCInstallIntoContext(failureContext, &installError);
    EJSWinterTCAppleTestSetInitSource(NULL);

    if (installResult ||
        installError == nil ||
        [installError.localizedDescription containsString:@"wintertc init sentinel"] == NO ||
        [installError.localizedDescription isEqualToString:@"Failed to install WinterTC"]) {
      NSString *message = installError.localizedDescription ?: @"<nil>";
      fprintf(stderr, "WinterTC init error was not propagated: %s\n", message.UTF8String);
      return EXIT_FAILURE;
    }
    [failureContext invalidate];

    EJSContext *rollbackContext = [runtime createContextWithID:@"app://tests/wintertc-install-rollback"
                                                         error:&error];
    if (rollbackContext == nil) {
      fprintf(stderr, "failed to create WinterTC rollback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *rollbackReportProvider = [[TestReportProvider alloc] init];
    if (![rollbackContext registerProvider:rollbackReportProvider error:&error]) {
      fprintf(stderr, "failed to register WinterTC rollback report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![rollbackContext evaluateScript:
          @"Object.defineProperty(globalThis, 'setTimeout', { value: function legacyTimeout() {}, configurable: true, writable: false, enumerable: false });"
           "Object.defineProperty(globalThis, 'URL', { value: function LegacyURL() {}, configurable: true, writable: false, enumerable: false });"
                         filename:@"wintertc_rollback_setup.js"
                            error:&error]) {
      fprintf(stderr, "failed to setup WinterTC rollback globals: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    EJSWinterTCAppleTestSetInstallFailScriptIndex(3);
    NSError *rollbackInstallError = nil;
    BOOL rollbackInstallResult = EJSWinterTCInstallIntoContext(rollbackContext, &rollbackInstallError);
    EJSWinterTCAppleTestSetInstallFailScriptIndex(-1);
    if (rollbackInstallResult || rollbackInstallError == nil ||
        [rollbackInstallError.localizedDescription containsString:@"sentinel"] == NO) {
      fprintf(stderr, "WinterTC rollback install should fail with sentinel error\n");
      return EXIT_FAILURE;
    }
    [rollbackReportProvider reset];
    if (![rollbackContext evaluateScript:
          @"(async function(){"
           " const timeoutDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'setTimeout');"
           " const urlDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'URL');"
           " if (!timeoutDescriptor || timeoutDescriptor.enumerable !== false || timeoutDescriptor.writable !== false || timeoutDescriptor.value.name !== 'legacyTimeout') throw new Error('setTimeout descriptor rollback mismatch');"
           " if (!urlDescriptor || urlDescriptor.enumerable !== false || urlDescriptor.writable !== false || urlDescriptor.value.name !== 'LegacyURL') throw new Error('URL descriptor rollback mismatch');"
           " if (Object.prototype.hasOwnProperty.call(globalThis, 'addEventListener')) throw new Error('module-owned global residue: addEventListener');"
           " await __ejs_native__.invoke('test', 'report', 'wintertc:install-rollback');"
           "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));"
                         filename:@"wintertc_install_rollback.js"
                            error:&error] ||
        !wait_for_report(rollbackReportProvider, @"wintertc:install-rollback")) {
      fprintf(stderr, "WinterTC install rollback verification failed: %s / %s\n",
              error.localizedDescription.UTF8String ?: "",
              rollbackReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }
    [rollbackContext invalidate];
#endif

    if (!EJSWinterTCInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install WinterTC: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (![context evaluateScript:
          @"if (!globalThis.WinterTC || WinterTC.loaded !== true || WinterTC.apis.indexOf('crypto') < 0 || WinterTC.apis.indexOf('performance') < 0 || WinterTC.apis.indexOf('encoding') < 0 || WinterTC.apis.indexOf('request') < 0 || typeof URL !== 'function' || typeof EventTarget !== 'function' || typeof TextEncoder !== 'function' || typeof TextDecoder !== 'function' || typeof reportError !== 'function' || typeof performance.now !== 'function' || typeof Request !== 'function' || typeof Headers !== 'function' || typeof Response !== 'function') {"
           "  throw new Error('WinterTC bundle did not install expected globals');"
           "}"
           "__ejs_native__.invoke('test', 'report', 'wintertc-installed');"
                         filename:@"wintertc_bundle_install.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"wintertc-installed")) {
      fprintf(stderr, "WinterTC bundle verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const params = new URLSearchParams('a=1&a=2&b=3');"
           "params.set('a', 'z');"
           "if (params.toString() === 'a=z&b=3' && params.getAll('a').length === 1) {"
           "  __ejs_native__.invoke('test', 'report', 'urlsearchparams-set-ok');"
           "} else {"
           "  __ejs_native__.invoke('test', 'report', 'urlsearchparams-set-failed:' + params.toString());"
           "}"
                         filename:@"wintertc_urlsearchparams_set.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"urlsearchparams-set-ok")) {
      fprintf(stderr, "WinterTC URLSearchParams.set duplicate removal failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const sample = ["
           "  new URL('../g', 'https://a.test/b/c/d').href,"
           "  new URL('../../g', 'https://a.test/b/c/d').href,"
           "  new URL('../', 'https://a.test/b/c/d').href,"
           "  new URL('/a/./b/../c', 'https://a.test/base').href,"
           "  new URL('g?x=/../z', 'https://a.test/b/c/d').href,"
           "  new URL('https://a.test/p/./q/../r').href,"
           "  new URL('../../../x', 'https://a.test/b/').href,"
           "  new URL('a//b/../c', 'https://a.test/root/').href"
           "];"
           "const expected = ["
           "  'https://a.test/b/g',"
           "  'https://a.test/g',"
           "  'https://a.test/b/',"
           "  'https://a.test/a/c',"
           "  'https://a.test/b/c/g?x=/../z',"
           "  'https://a.test/p/r',"
           "  'https://a.test/x',"
           "  'https://a.test/root/a//c'"
           "];"
           "if (sample.every(function(value, index) { return value === expected[index]; })) {"
           "  __ejs_native__.invoke('test', 'report', 'url-relative-normalize-ok');"
           "} else {"
           "  __ejs_native__.invoke('test', 'report', 'url-relative-normalize-failed:' + sample.join('|'));"
           "}"
                         filename:@"wintertc_url_relative_normalize.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"url-relative-normalize-ok")) {
      fprintf(stderr, "WinterTC URL relative normalization failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const httpsURL = new URL('https://example.test:8443/path');"
           "const defaultPortURL = new URL('https://example.test:443/path');"
           "const fileURL = new URL('file:///tmp/example.txt');"
           "const wsURL = new URL('ws://example.test/socket');"
           "if (httpsURL.origin === 'https://example.test:8443' && defaultPortURL.origin === 'https://example.test' && fileURL.origin === 'null' && wsURL.origin === 'ws://example.test') {"
           "  __ejs_native__.invoke('test', 'report', 'url-origin-ok');"
           "} else {"
           "  __ejs_native__.invoke('test', 'report', 'url-origin-failed:' + [httpsURL.origin, defaultPortURL.origin, fileURL.origin, wsURL.origin].join('|'));"
           "}"
                         filename:@"wintertc_url_origin.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"url-origin-ok")) {
      fprintf(stderr, "WinterTC URL origin verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const target = new EventTarget();"
           "let seen = 0;"
           "const listener = { handleEvent: function(event) {"
           "  if (event.type === 'wintertc-object-listener' && event.currentTarget === target) seen += 1;"
           "} };"
           "target.addEventListener('wintertc-object-listener', listener);"
           "target.dispatchEvent(new Event('wintertc-object-listener'));"
           "target.removeEventListener('wintertc-object-listener', listener);"
           "target.dispatchEvent(new Event('wintertc-object-listener'));"
           "if (seen === 1) {"
           "  __ejs_native__.invoke('test', 'report', 'event-object-listener-ok');"
           "} else {"
           "  __ejs_native__.invoke('test', 'report', 'event-object-listener-failed:' + seen);"
           "}"
                         filename:@"wintertc_event_object_listener.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"event-object-listener-ok")) {
      fprintf(stderr, "WinterTC EventTarget object listener failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"let intervalTicks = 0;"
           "const intervalID = setInterval(function() {"
           "  intervalTicks += 1;"
           "  if (intervalTicks === 2) {"
           "    clearInterval(intervalID);"
           "    __ejs_native__.invoke('test', 'report', 'interval-zero-repeat-ok');"
           "  }"
           "}, 0);"
           "setTimeout(function() {"
           "  if (intervalTicks < 2) {"
           "    clearInterval(intervalID);"
           "    __ejs_native__.invoke('test', 'report', 'interval-zero-repeat-failed:' + intervalTicks);"
           "  }"
           "}, 50);"
                         filename:@"wintertc_interval_zero_repeat.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"interval-zero-repeat-ok")) {
      fprintf(stderr, "WinterTC setInterval zero-delay repeat failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           " const savedTimers = __ejs_native__.timers;"
           " let timeoutThrows = false;"
           " let intervalThrows = false;"
           " let microtaskRan = false;"
           " try {"
           "   __ejs_native__.timers = null;"
           "   try { setTimeout(function() {}, 0); } catch (error) { timeoutThrows = String(error.message).indexOf('native timers') >= 0; }"
           "   try { setInterval(function() {}, 0); } catch (error) { intervalThrows = String(error.message).indexOf('native timers') >= 0; }"
           "   await new Promise(function(resolve) { queueMicrotask(function() { microtaskRan = true; resolve(); }); });"
           "   if (timeoutThrows && intervalThrows && microtaskRan) {"
           "     await __ejs_native__.invoke('test', 'report', 'timers-missing-native-failfast-ok');"
           "   } else {"
           "     await __ejs_native__.invoke('test', 'report', 'timers-missing-native-failfast-failed');"
           "   }"
           " } finally {"
           "   __ejs_native__.timers = savedTimers;"
           " }"
           "})().catch(function(error) {"
           " __ejs_native__.invoke('test', 'report', 'timers-missing-native-failfast-error:' + error.message);"
           "});"
                         filename:@"wintertc_timers_missing_native.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"timers-missing-native-failfast-ok")) {
      fprintf(stderr, "WinterTC missing native timers fail-fast verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"new Blob(['hello']).text().then(function(text) {"
           "  const decoded = new TextDecoder().decode(new Uint8Array([226, 156, 147]));"
           "  const encoded = new TextEncoder().encode('ab');"
           "  const replacement = new TextDecoder().decode(new Uint8Array([0xed, 0xa0, 0x80]));"
           "  const loneSurrogate = new TextEncoder().encode('\\ud800');"
           "  if (text === 'hello' && decoded.length === 1 && decoded.charCodeAt(0) === 0x2713 && encoded.byteLength === 2 && replacement.charCodeAt(0) === 0xfffd && loneSurrogate[0] === 0xef && loneSurrogate[1] === 0xbf && loneSurrogate[2] === 0xbd) {"
           "    __ejs_native__.invoke('test', 'report', 'encoding-blob-ok');"
           "  } else {"
           "    __ejs_native__.invoke('test', 'report', 'encoding-blob-failed');"
           "  }"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'encoding-blob-error:' + error.message);"
           "});"
                         filename:@"wintertc_encoding_blob.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"encoding-blob-ok")) {
      fprintf(stderr, "WinterTC encoding/Blob text verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const requestHeaders = new Headers([['X-Test', 'one']]);"
           "requestHeaders.append('x-test', 'two');"
           "const request = new Request('https://example.test/body', { method: 'POST', headers: requestHeaders, body: 'payload' });"
           "const requestClone = request.clone();"
           "const blobRequest = new Request('https://example.test/blob', { method: 'POST', body: new Blob(['blob-payload']) });"
           "const blobRequestClone = new Request(blobRequest);"
           "let streamCloneThrew = false;"
           "try {"
           "  const streamRequest = new Request('https://example.test/stream', { method: 'POST', body: new ReadableStream({ start(controller) { controller.enqueue('x'); controller.close(); } }) });"
           "  new Request(streamRequest);"
           "} catch (error) {"
           "  streamCloneThrew = error instanceof TypeError;"
           "}"
           "const response = Response.json({ ok: true, count: 2 });"
           "const blobResponse = new Response(new Blob(['blob-response']));"
           "const blobResponseClone = blobResponse.clone();"
           "const blobResponseCloneReady = blobResponse.bodyUsed === false && blobResponseClone.bodyUsed === false;"
           "const consumedCloneSource = new Response(new Blob(['used']));"
           "let consumedCloneThrows = false;"
           "const consumedCloneCheck = consumedCloneSource.text().then(function() {"
           "  try {"
           "    consumedCloneSource.clone();"
           "  } catch (error) {"
           "    consumedCloneThrows = error instanceof TypeError;"
           "  }"
           "});"
           "let streamResponseCloneThrew = false;"
           "try {"
           "  const streamResponse = new Response(new ReadableStream({ start(controller) { controller.enqueue('x'); controller.close(); } }));"
           "  streamResponse.clone();"
           "} catch (error) {"
           "  streamResponseCloneThrew = error instanceof TypeError;"
           "}"
           "Promise.all([requestClone.text(), blobRequestClone.text(), response.json(), blobResponse.text(), blobResponseClone.text(), consumedCloneCheck]).then(function(values) {"
            "  const requestText = values[0];"
            "  const blobText = values[1];"
            "  const responseJSON = values[2];"
            "  const blobResponseText = values[3];"
            "  const blobResponseCloneText = values[4];"
           "  const headersOK = request.headers.get('X-Test') === 'one, two' && Array.from(request.headers.keys())[0] === 'x-test';"
           "  const responseOK = response.headers.get('content-type') === 'application/json' && responseJSON.ok === true && responseJSON.count === 2;"
           "  const blobResponseOK = blobResponseCloneReady && blobResponseText === 'blob-response' && blobResponseCloneText === 'blob-response';"
           "  if (request.method === 'POST' && requestText === 'payload' && blobText === 'blob-payload' && request.bodyUsed === false && blobRequest.bodyUsed === false && streamCloneThrew && headersOK && responseOK && blobResponseOK && streamResponseCloneThrew && consumedCloneThrows) {"
            "    __ejs_native__.invoke('test', 'report', 'request-response-body-ok');"
           "  } else {"
            "    __ejs_native__.invoke('test', 'report', 'request-response-body-failed');"
           "  }"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'request-response-body-error:' + error.message);"
           "});"
                         filename:@"wintertc_request_response_body.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"request-response-body-ok")) {
      fprintf(stderr, "WinterTC Request/Response body verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           " let desiredSize;"
           " const stream = new ReadableStream({"
           "   start(controller) {"
           "     desiredSize = controller.desiredSize;"
           "     controller.enqueue('queued');"
           "     controller.close();"
           "   }"
           " });"
           " const reader = stream.getReader();"
           " const first = await reader.read();"
           " const second = await reader.read();"
           " await reader.closed;"
           " let cancelReason = null;"
           " const cancelStream = new ReadableStream({"
           "   cancel(reason) { cancelReason = reason; }"
           " });"
           " const cancelReader = cancelStream.getReader();"
           " await cancelReader.cancel('stop');"
           " await cancelReader.closed;"
           " const afterCancel = await cancelReader.read();"
           " if (desiredSize > 0 && first.value === 'queued' && first.done === false && second.done === true && cancelReason === 'stop' && afterCancel.done === true) {"
           "   __ejs_native__.invoke('test', 'report', 'streams-controller-cancel-ok');"
           " } else {"
           "   __ejs_native__.invoke('test', 'report', 'streams-controller-cancel-failed');"
           " }"
           "})().catch(function(error) {"
           " __ejs_native__.invoke('test', 'report', 'streams-controller-cancel-error:' + error.message);"
           "});"
                         filename:@"wintertc_streams_controller_cancel.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"streams-controller-cancel-ok")) {
      fprintf(stderr, "WinterTC streams controller/cancel verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           "  let headersRejected = false;"
           "  let fetchRejected = false;"
           "  try {"
           "    new Headers({ 'x-test': 'line\\r\\nbreak' });"
           "  } catch (error) {"
           "    headersRejected = error instanceof TypeError;"
           "  }"
           "  try {"
           "    await fetch('https://example.test/invalid-header', { headers: { 'x-test': 'line\\nbreak' } });"
           "  } catch (error) {"
           "    fetchRejected = error instanceof TypeError;"
           "  }"
           "  await __ejs_native__.invoke('test', 'report', headersRejected && fetchRejected ? 'fetch-header-value-reject-ok' : 'fetch-header-value-reject-failed');"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-header-value-reject-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_header_value_reject.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-header-value-reject-ok") ||
        fakeFetchProvider.lastBodyKind.length != 0u) {
      fprintf(stderr, "WinterTC fetch header value rejection verification failed: message=%s bodyKind=%s\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.lastBodyKind.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const stream = new ReadableStream({"
           "  start(controller) {"
           "    setTimeout(function() { controller.enqueue('first'); }, 5);"
           "    setTimeout(function() { controller.close(); }, 10);"
           "  }"
           "});"
           "const reader = stream.getReader();"
           "Promise.all([reader.read(), reader.read()]).then(function(values) {"
           "  const first = values[0];"
           "  const second = values[1];"
           "  if (first.value === 'first' && first.done === false && second.done === true) {"
           "    __ejs_native__.invoke('test', 'report', 'streams-concurrent-read-ok');"
           "  } else {"
           "    __ejs_native__.invoke('test', 'report', 'streams-concurrent-read-failed');"
           "  }"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'streams-concurrent-read-error:' + error.message);"
           "});"
                         filename:@"wintertc_streams_concurrent_read.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"streams-concurrent-read-ok")) {
      fprintf(stderr, "WinterTC streams concurrent read verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           " const stream = new ReadableStream({"
           "   async pull(controller) {"
           "     if (this.count == null) this.count = 0;"
           "     this.count += 1;"
           "     controller.enqueue('chunk-' + this.count);"
           "     if (this.count >= 3) controller.close();"
           "   }"
           " });"
           " const reader = stream.getReader();"
           " const reads = Promise.all([reader.read(), reader.read(), reader.read()]);"
           " const timeout = new Promise(function(resolve) { setTimeout(function() { resolve('timeout'); }, 100); });"
           " const result = await Promise.race([reads, timeout]);"
           " if (result === 'timeout') {"
           "   __ejs_native__.invoke('test', 'report', 'streams-pull-concurrent-read-timeout');"
           "   return;"
           " }"
           " const first = result[0];"
           " const second = result[1];"
           " const third = result[2];"
           " if (first.value === 'chunk-1' && second.value === 'chunk-2' && third.value === 'chunk-3' && first.done === false && second.done === false && third.done === false) {"
           "   __ejs_native__.invoke('test', 'report', 'streams-pull-concurrent-read-ok');"
           " } else {"
           "   __ejs_native__.invoke('test', 'report', 'streams-pull-concurrent-read-failed');"
           " }"
           "})().catch(function(error) {"
           " __ejs_native__.invoke('test', 'report', 'streams-pull-concurrent-read-error:' + error.message);"
           "});"
                         filename:@"wintertc_streams_pull_concurrent_read.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"streams-pull-concurrent-read-ok")) {
      fprintf(stderr, "WinterTC streams pull concurrent read verification failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"fetch('https://example.test/post', { method: 'POST', body: 'abc' })"
           ".then(function(response) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-string-body-ok:' + response.status);"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-string-body-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_string_body.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-string-body-ok:204") ||
        ![fakeFetchProvider.lastBodyKind isEqualToString:@"bytes"] ||
        fakeFetchProvider.lastTransferWasNil ||
        fakeFetchProvider.lastTransferLength != 3 ||
        ![fakeFetchProvider.lastTransferText isEqualToString:@"abc"]) {
      fprintf(stderr, "WinterTC fetch string body transfer failed: message=%s kind=%s nil=%d length=%lu text=%s\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.lastBodyKind.UTF8String,
              fakeFetchProvider.lastTransferWasNil,
              (unsigned long)fakeFetchProvider.lastTransferLength,
              fakeFetchProvider.lastTransferText.UTF8String);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"fetch('https://example.test/empty', { method: 'POST', body: '' })"
           ".then(function(response) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-empty-string-body-ok:' + response.status);"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-empty-string-body-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_empty_string_body.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-empty-string-body-ok:204") ||
        ![fakeFetchProvider.lastBodyKind isEqualToString:@"bytes"] ||
        fakeFetchProvider.lastTransferWasNil ||
        fakeFetchProvider.lastTransferLength != 0) {
      fprintf(stderr, "WinterTC fetch empty string body transfer failed: message=%s kind=%s nil=%d length=%lu\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.lastBodyKind.UTF8String,
              fakeFetchProvider.lastTransferWasNil,
              (unsigned long)fakeFetchProvider.lastTransferLength);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           "  let invalidRejected = false;"
           "  let manualRejected = false;"
           "  let errorRejected = false;"
           "  try {"
           "    new Request('https://example.test/redirect-invalid', { redirect: 'invalid-mode' });"
           "  } catch (error) {"
           "    invalidRejected = error instanceof TypeError;"
           "  }"
           "  try {"
           "    await fetch('https://example.test/redirect-manual', { redirect: 'manual' });"
           "  } catch (error) {"
           "    manualRejected = error instanceof TypeError;"
           "  }"
           "  try {"
           "    await fetch('https://example.test/redirect-error', { redirect: 'error' });"
           "  } catch (error) {"
           "    errorRejected = error instanceof TypeError;"
           "  }"
           "  await __ejs_native__.invoke('test', 'report', invalidRejected && manualRejected && errorRejected ? 'fetch-redirect-mode-ok' : 'fetch-redirect-mode-failed');"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-redirect-mode-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_redirect_mode.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-redirect-mode-ok") ||
        fakeFetchProvider.lastBodyKind.length != 0u) {
      fprintf(stderr, "WinterTC fetch redirect mode validation failed: message=%s bodyKind=%s\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.lastBodyKind.UTF8String);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
	    if (![context evaluateScript:
	          @"const abortController = new AbortController();"
	           "fetch('https://example.test/abort', { signal: abortController.signal })"
           ".then(function(response) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-abort-failed:' + response.status);"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-abort-ok:' + error.name);"
           "});"
	           "setTimeout(function() { abortController.abort(); }, 10);"
	                         filename:@"wintertc_fetch_abort.js"
	                            error:&error] ||
	        !wait_for_report(reportProvider, @"fetch-abort-ok:AbortError") ||
	        !fakeFetchProvider.cancelCalled ||
	        fakeFetchProvider.lastSignalID.length == 0u ||
	        ![fakeFetchProvider.lastSignalID isEqualToString:fakeFetchProvider.lastCancelSignalID]) {
      fprintf(stderr, "WinterTC fetch abort cancel bridging failed: message=%s signal=%s cancelSignal=%s cancelCalled=%d\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.lastSignalID.UTF8String,
              fakeFetchProvider.lastCancelSignalID.UTF8String,
              fakeFetchProvider.cancelCalled);
	      return EXIT_FAILURE;
	    }

	    [reportProvider reset];
	    if (![context evaluateScript:
	          @"const immediateAbortController = new AbortController();"
	           "immediateAbortController.abort();"
	           "fetch('https://example.test/abort-now', { signal: immediateAbortController.signal })"
	           ".then(function(response) {"
	           "  __ejs_native__.invoke('test', 'report', 'fetch-abort-now-failed:' + response.status);"
	           "}).catch(function(error) {"
	           "  __ejs_native__.invoke('test', 'report', 'fetch-abort-now-ok:' + error.name);"
	           "});"
	                         filename:@"wintertc_fetch_abort_now.js"
	                            error:&error] ||
	        !wait_for_report(reportProvider, @"fetch-abort-now-ok:AbortError")) {
	      fprintf(stderr, "WinterTC immediate fetch abort mapping failed: %s\n",
	              reportProvider.lastMessage.UTF8String);
	      return EXIT_FAILURE;
	    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           "  const controller = new AbortController();"
           "  const startedAt = Date.now();"
           "  const slowBody = new ReadableStream({"
           "    async pull(streamController) {"
           "      await new Promise(function(resolve) { setTimeout(resolve, 200); });"
           "      streamController.enqueue(new Uint8Array([65]));"
           "      streamController.close();"
           "    }"
           "  });"
           "  const pending = fetch('https://example.test/abort-body-transfer', {"
           "    method: 'POST',"
           "    signal: controller.signal,"
           "    body: slowBody"
           "  });"
           "  setTimeout(function() { controller.abort('body-transfer-abort'); }, 20);"
           "  let report = 'fetch-abort-body-transfer-failed:resolved';"
           "  try {"
           "    await pending;"
           "  } catch (error) {"
           "    const elapsed = Date.now() - startedAt;"
           "    if (error && error.name === 'AbortError' && elapsed < 180) {"
           "      report = 'fetch-abort-body-transfer-ok';"
           "    } else {"
           "      report = 'fetch-abort-body-transfer-failed:' + (error && error.name ? error.name : String(error)) + ':' + elapsed;"
           "    }"
           "  }"
           "  await __ejs_native__.invoke('test', 'report', report);"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-abort-body-transfer-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_abort_body_transfer.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-abort-body-transfer-ok")) {
      fprintf(stderr, "WinterTC fetch abort during body transfer failed: %s\n",
              reportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"(async function(){"
           "  const response = await fetch('https://example.test/unconsumed-body');"
           "  if (response.status !== 204) throw new Error('unexpected status:' + response.status);"
           "  await new Promise(function(resolve) { setTimeout(resolve, 400); });"
           "  await __ejs_native__.invoke('test', 'report', 'fetch-unconsumed-body-auto-cancel-ok');"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-unconsumed-body-auto-cancel-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_unconsumed_body_auto_cancel.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-unconsumed-body-auto-cancel-ok") ||
        !fakeFetchProvider.cancelCalled) {
      fprintf(stderr, "WinterTC unconsumed body auto cancel failed: message=%s cancelCalled=%d\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.cancelCalled);
      return EXIT_FAILURE;
    }

    [fakeFetchProvider reset];
    [reportProvider reset];
    if (![context evaluateScript:
          @"const fetchRequest = new Request('https://example.test/request-body', {"
           "  method: 'POST',"
           "  headers: { 'x-request-test': 'yes' },"
           "  body: new Uint8Array([65, 66, 67])"
           "});"
           "fetch(fetchRequest).then(function(response) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-request-body-ok:' + response.status);"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'fetch-request-body-error:' + error.message);"
           "});"
                         filename:@"wintertc_fetch_request_body.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"fetch-request-body-ok:204") ||
        ![fakeFetchProvider.lastBodyKind isEqualToString:@"bytes"] ||
        fakeFetchProvider.lastTransferWasNil ||
        fakeFetchProvider.lastTransferLength != 3 ||
        ![fakeFetchProvider.lastTransferText isEqualToString:@"ABC"]) {
      fprintf(stderr, "WinterTC fetch Request body transfer failed: message=%s kind=%s nil=%d length=%lu text=%s\n",
              reportProvider.lastMessage.UTF8String,
              fakeFetchProvider.lastBodyKind.UTF8String,
              fakeFetchProvider.lastTransferWasNil,
              (unsigned long)fakeFetchProvider.lastTransferLength,
              fakeFetchProvider.lastTransferText.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"addEventListener('error', function onError(event) {"
           "  removeEventListener('error', onError);"
           "  __ejs_native__.invoke('test', 'report', 'error:' + event.message);"
           "});"
           "reportError(new Error('report-sentinel'));"
                         filename:@"wintertc_report_error.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"error:report-sentinel")) {
      fprintf(stderr, "WinterTC reportError verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"addEventListener('unhandledrejection', function onUnhandled(event) {"
           "  removeEventListener('unhandledrejection', onUnhandled);"
           "  __ejs_native__.invoke('test', 'report', 'unhandled:' + event.reason.message);"
           "});"
           "Promise.reject(new Error('wintertc-unhandled'));"
                         filename:@"wintertc_unhandled_rejection.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"unhandled:wintertc-unhandled")) {
      fprintf(stderr, "WinterTC unhandledrejection verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"addEventListener('rejectionhandled', function onHandled(event) {"
           "  removeEventListener('rejectionhandled', onHandled);"
           "  __ejs_native__.invoke('test', 'report', 'handled:' + event.reason.message);"
           "});"
           "addEventListener('unhandledrejection', function onUnhandled(event) {"
           "  removeEventListener('unhandledrejection', onUnhandled);"
           "  setTimeout(function() { event.promise.catch(function() {}); }, 0);"
           "});"
           "Promise.reject(new Error('wintertc-late'));"
                         filename:@"wintertc_rejection_handled.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"handled:wintertc-late")) {
      fprintf(stderr, "WinterTC rejectionhandled verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"try {"
           "  crypto.getRandomValues(new Uint8Array(4));"
           "} catch (error) {"
           "  if (String(error.message).indexOf('invalid byte length') >= 0) __ejs_native__.invoke('test', 'report', 'crypto-short-random-ok');"
           "}"
                         filename:@"wintertc_crypto_short_random.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"crypto-short-random-ok")) {
      fprintf(stderr, "WinterTC crypto short random validation failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"let floatRejected = false;"
           "let dataViewRejected = false;"
           "try { crypto.getRandomValues(new Float32Array(1)); } catch (error) { floatRejected = error instanceof TypeError; }"
           "try { crypto.getRandomValues(new DataView(new ArrayBuffer(4))); } catch (error) { dataViewRejected = error instanceof TypeError; }"
           "if (floatRejected && dataViewRejected) {"
           "  __ejs_native__.invoke('test', 'report', 'crypto-view-validation-ok');"
           "}"
                         filename:@"wintertc_crypto_view_validation.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"crypto-view-validation-ok")) {
      fprintf(stderr, "WinterTC crypto view validation failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [reportProvider reset];
    if (![context evaluateScript:
          @"const origin = performance.timeOrigin;"
           "const firstNow = performance.now();"
           "const secondNow = performance.now();"
           "if (origin === 1770000000000 && secondNow >= firstNow) {"
           "  __ejs_native__.invoke('test', 'report', 'performance-clock-ok');"
           "}"
                         filename:@"wintertc_performance_clock.js"
                            error:&error] ||
        !wait_for_report(reportProvider, @"performance-clock-ok")) {
      fprintf(stderr, "WinterTC performance clock verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    WinterTCLocalHTTPServer *streamServer = [[WinterTCLocalHTTPServer alloc] init];
    if (![streamServer start:&error]) {
      fprintf(stderr, "failed to start WinterTC local HTTP server: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *streamBaseURL = [NSString stringWithFormat:@"http://127.0.0.1:%u", streamServer.port];

    EJSContext *defaultProviderContext = [runtime createContextWithID:@"app://tests/wintertc-default-providers"
                                                                error:&error];
    if (defaultProviderContext == nil) {
      fprintf(stderr, "failed to create WinterTC default provider context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *defaultReportProvider = [[TestReportProvider alloc] init];
    if (![defaultProviderContext registerProvider:defaultReportProvider error:&error]) {
      fprintf(stderr, "failed to register default-provider report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSWinterTCInstallOptions *defaultOptions = [[EJSWinterTCInstallOptions alloc] init];
    defaultOptions.installDefaultProviders = YES;
    if (!EJSWinterTCInstallIntoContextWithOptions(defaultProviderContext, defaultOptions, &error)) {
      fprintf(stderr, "failed to install WinterTC default providers: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    EJSContext *providerRollbackContext = [runtime createContextWithID:@"app://tests/wintertc-provider-rollback"
                                                                  error:&error];
    if (providerRollbackContext == nil) {
      fprintf(stderr, "failed to create WinterTC provider rollback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *providerRollbackReport = [[TestReportProvider alloc] init];
    if (![providerRollbackContext registerProvider:providerRollbackReport error:&error]) {
      fprintf(stderr, "failed to register WinterTC provider rollback reporter: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![providerRollbackContext evaluateScript:
          @"Object.defineProperty(globalThis, 'fetch', { value: function legacyFetch() {}, configurable: true, writable: false, enumerable: false });"
                         filename:@"wintertc_provider_rollback_setup.js"
                            error:&error]) {
      fprintf(stderr, "failed to setup WinterTC provider rollback globals: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSWinterTCInstallOptions *providerRollbackOptions = [[EJSWinterTCInstallOptions alloc] init];
    providerRollbackOptions.installDefaultProviders = YES;
    EJSWinterTCAppleTestSetInstallFailProviderIndex(2);
    NSError *providerRollbackError = nil;
    BOOL providerRollbackInstall = EJSWinterTCInstallIntoContextWithOptions(providerRollbackContext, providerRollbackOptions, &providerRollbackError);
    EJSWinterTCAppleTestSetInstallFailProviderIndex(-1);
    if (providerRollbackInstall || providerRollbackError == nil ||
        [providerRollbackError.localizedDescription containsString:@"sentinel"] == NO) {
      fprintf(stderr, "WinterTC provider rollback install should fail with sentinel error\n");
      return EXIT_FAILURE;
    }

    [providerRollbackReport reset];
    if (![providerRollbackContext evaluateScript:
          @"(async function(){"
           " const fetchDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'fetch');"
           " if (!fetchDescriptor || fetchDescriptor.enumerable !== false || fetchDescriptor.writable !== false || fetchDescriptor.value.name !== 'legacyFetch') throw new Error('fetch descriptor rollback mismatch');"
           " if (Object.prototype.hasOwnProperty.call(globalThis, 'WinterTC')) throw new Error('WinterTC global should be removed after provider rollback');"
           " let providerRolledBack = false;"
           " try {"
           "   __ejs_native__.invokeSync('wintertc.clock', 'now', null, null);"
           " } catch (error) {"
           "   providerRolledBack = true;"
           " }"
           " if (!providerRolledBack) throw new Error('default providers were not rolled back');"
           " await __ejs_native__.invoke('test', 'report', 'wintertc:provider-rollback');"
           "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));"
                         filename:@"wintertc_provider_rollback.js"
                            error:&error] ||
        !wait_for_report(providerRollbackReport, @"wintertc:provider-rollback")) {
      fprintf(stderr, "WinterTC provider rollback verification failed: %s / %s\n",
              error.localizedDescription.UTF8String ?: "",
              providerRollbackReport.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }
    [providerRollbackContext invalidate];
#endif

    if (![defaultProviderContext evaluateScript:
          @"const randomBytes = new Uint8Array(8);"
           "crypto.getRandomValues(randomBytes);"
           "const uuid = crypto.randomUUID();"
           "const uuidOK = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid);"
           "const clockOK = performance.timeOrigin > 0 && performance.now() >= 0;"
           "console.log('wintertc default provider smoke');"
           "if (randomBytes.byteLength === 8 && uuidOK && clockOK && WinterTC.apis.indexOf('console') >= 0) {"
           "  __ejs_native__.invoke('test', 'report', 'default-sync-providers-ok');"
           "}"
                         filename:@"wintertc_default_sync_providers.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-sync-providers-ok")) {
      fprintf(stderr, "WinterTC default sync providers verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    if (![defaultProviderContext evaluateScript:
          @"fetch('data:text/plain;charset=utf-8,hello%20wintertc').then(function(response) {"
           "  return response.text().then(function(text) {"
           "    const contentType = response.headers.get('content-type') || '';"
           "    if (response.status === 200 && contentType.indexOf('text/plain') >= 0 && text === 'hello wintertc') {"
           "      __ejs_native__.invoke('test', 'report', 'default-fetch-data-url-ok');"
           "    } else {"
           "      __ejs_native__.invoke('test', 'report', 'default-fetch-data-url-bad:' + response.status + ':' + text + ':' + contentType);"
           "    }"
           "  });"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-data-url-error:' + error.message);"
           "});"
                         filename:@"wintertc_default_fetch_data_url.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-data-url-ok")) {
      fprintf(stderr, "WinterTC default fetch data URL verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    if (![defaultProviderContext evaluateScript:
          @"(async function(){"
           "  const payloads = ["
           "    {"
           "      url: 'https://example.test/native-header-array',"
           "      method: 'GET',"
           "      headers: [['x-test', 'value\\r\\nbreak']]"
           "    },"
           "    {"
           "      url: 'https://example.test/native-header-dict',"
           "      method: 'GET',"
           "      headers: { 'x-test': 'value\\nbreak' }"
           "    }"
           "  ];"
           "  for (const payload of payloads) {"
           "    try {"
           "      await __ejs_native__.invoke('wintertc.fetch', 'start', JSON.stringify(payload), null);"
           "      await __ejs_native__.invoke('test', 'report', 'default-fetch-invalid-header-missing-error');"
           "      return;"
           "    } catch (error) {"
           "      const message = String(error && error.message ? error.message : error);"
           "      if (message.indexOf('Invalid header value') < 0) {"
           "        await __ejs_native__.invoke('test', 'report', 'default-fetch-invalid-header-bad:' + message);"
           "        return;"
           "      }"
           "    }"
           "  }"
           "  await __ejs_native__.invoke('test', 'report', 'default-fetch-invalid-header-ok');"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-invalid-header-error:' + error.message);"
           "});"
                         filename:@"wintertc_default_fetch_invalid_header.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-invalid-header-ok")) {
      fprintf(stderr, "WinterTC default fetch invalid header verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    NSString *redirectFollowFetchScript = [NSString stringWithFormat:
          @"fetch('%@/redirect-once').then(async function(response) {"
           "  const text = await response.text();"
           "  const expectedURL = '%@/redirect-target';"
           "  if (response.status === 200 && text === 'redirect-ok' && response.redirected === true && response.url === expectedURL) {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-follow-ok');"
           "  } else {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-follow-bad:' + response.status + ':' + text + ':' + response.redirected + ':' + response.url);"
           "  }"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-follow-error:' + error.message);"
           "});",
          streamBaseURL,
          streamBaseURL];
    if (![defaultProviderContext evaluateScript:redirectFollowFetchScript
                         filename:@"wintertc_default_fetch_redirect_follow.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-redirect-follow-ok")) {
      fprintf(stderr, "WinterTC default fetch redirect follow verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    if (![defaultProviderContext evaluateScript:
          @"(async function(){"
           "  const payloads = ["
           "    { url: 'https://example.test/redirect-manual', method: 'GET', redirect: 'manual' },"
           "    { url: 'https://example.test/redirect-error', method: 'GET', redirect: 'error' }"
           "  ];"
           "  for (const payload of payloads) {"
           "    try {"
           "      await __ejs_native__.invoke('wintertc.fetch', 'start', JSON.stringify(payload), null);"
           "      await __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-mode-missing-error');"
           "      return;"
           "    } catch (error) {"
           "      const message = String(error && error.message ? error.message : error);"
           "      if (message.indexOf(\"Only redirect mode 'follow' is supported\") < 0) {"
           "        await __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-mode-bad:' + message);"
           "        return;"
           "      }"
           "    }"
           "  }"
           "  await __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-mode-ok');"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-redirect-mode-error:' + error.message);"
           "});"
                         filename:@"wintertc_default_fetch_redirect_mode.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-redirect-mode-ok")) {
      fprintf(stderr, "WinterTC default fetch redirect mode verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    NSString *incrementalFetchScript = [NSString stringWithFormat:
          @"const startAt = performance.now();"
           "fetch('%@/stream-incremental').then(async function(response) {"
           "  const startLatency = performance.now() - startAt;"
           "  const reader = response.body.getReader();"
           "  const first = await reader.read();"
           "  const firstReadLatency = performance.now() - startAt;"
           "  let total = first.value ? first.value.byteLength : 0;"
           "  while (true) {"
           "    const next = await reader.read();"
           "    if (next.done) break;"
           "    total += next.value ? next.value.byteLength : 0;"
           "  }"
           "  if (response.status === 200 && startLatency < 500 && firstReadLatency < 500 && !first.done && total === 131076) {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-http-incremental-ok');"
           "  } else {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-http-incremental-bad:' + startLatency + ':' + firstReadLatency + ':' + first.done + ':' + total);"
           "  }"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-http-incremental-error:' + error.message);"
           "});",
          streamBaseURL];
    if (![defaultProviderContext evaluateScript:incrementalFetchScript
                         filename:@"wintertc_default_fetch_http_incremental.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-http-incremental-ok")) {
      fprintf(stderr, "WinterTC default fetch HTTP incremental streaming verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

#ifdef EJS_TEST
    EJSWinterTCAppleTestSetFetchMaxBufferedBytes(1024u);
#endif
    [defaultReportProvider reset];
    NSString *overflowFetchScript = [NSString stringWithFormat:
          @"fetch('%@/stream-overflow').then(async function(response) {"
           "  await new Promise(function(resolve) { setTimeout(resolve, 100); });"
           "  try {"
           "    await response.text();"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-http-overflow-failed');"
           "  } catch (error) {"
           "    const message = String(error && error.message ? error.message : error);"
           "    if (message.indexOf('exceeded limit') >= 0) {"
           "      __ejs_native__.invoke('test', 'report', 'default-fetch-http-overflow-ok');"
           "    } else {"
           "      __ejs_native__.invoke('test', 'report', 'default-fetch-http-overflow-bad:' + message);"
           "    }"
           "  }"
           "}).catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-http-overflow-start-error:' + error.message);"
           "});",
          streamBaseURL];
    if (![defaultProviderContext evaluateScript:overflowFetchScript
                         filename:@"wintertc_default_fetch_http_overflow.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-http-overflow-ok")) {
      fprintf(stderr, "WinterTC default fetch HTTP overflow limit verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }
#ifdef EJS_TEST
    EJSWinterTCAppleTestSetFetchMaxBufferedBytes(0u);
#endif

    [defaultReportProvider reset];
    NSString *cancelFetchScript = [NSString stringWithFormat:
          @"(async function() {"
           "  const controller = new AbortController();"
           "  const response = await fetch('%@/stream-cancel', { signal: controller.signal });"
           "  const reader = response.body.getReader();"
           "  const first = await reader.read();"
           "  if (first.done || !first.value || first.value.byteLength === 0) {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-http-cancel-bad:first');"
           "    return;"
           "  }"
           "  const pending = reader.read().then(function(result) {"
           "    return result.done ? 'done' : 'value';"
           "  }, function(error) {"
           "    return 'error:' + (error && error.name ? error.name : String(error));"
           "  });"
           "  controller.abort();"
           "  const outcome = await pending;"
           "  if (outcome === 'error:AbortError') {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-http-cancel-ok');"
           "  } else {"
           "    __ejs_native__.invoke('test', 'report', 'default-fetch-http-cancel-bad:' + outcome);"
           "  }"
           "})().catch(function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-fetch-http-cancel-error:' + error.message);"
           "});",
          streamBaseURL];
    if (![defaultProviderContext evaluateScript:cancelFetchScript
                         filename:@"wintertc_default_fetch_http_cancel.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-fetch-http-cancel-ok")) {
      fprintf(stderr, "WinterTC default fetch HTTP cancel wakeup verification failed: %s\n",
              defaultReportProvider.lastMessage.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    if (![defaultProviderContext evaluateScript:
          @"__ejs_native__.invoke('wintertc.console', 'write', JSON.stringify({"
           "  level: 'log',"
           "  args: [{ nested: true }, 7, null, ['x']]"
           "}), null).then(function() {"
           "  __ejs_native__.invoke('test', 'report', 'console-payload-ok');"
           "}, function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'console-payload-error:' + error.message);"
           "});"
                         filename:@"wintertc_console_payload_sanitize.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"console-payload-ok")) {
      fprintf(stderr, "WinterTC console payload sanitize verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [defaultReportProvider reset];
    if (![defaultProviderContext evaluateScript:
          @"function hex(buffer) {"
           "  return Array.prototype.map.call(new Uint8Array(buffer), function(byte) {"
           "    return byte.toString(16).padStart(2, '0');"
           "  }).join('');"
           "}"
           "crypto.subtle.digest('SHA-256', new Uint8Array([97, 98, 99])).then(function(buffer) {"
           "  const actual = hex(buffer);"
           "  const expected = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';"
           "  __ejs_native__.invoke('test', 'report', actual === expected ? 'default-digest-ok' : 'default-digest-bad:' + actual);"
           "}, function(error) {"
           "  __ejs_native__.invoke('test', 'report', 'default-digest-error:' + error.message);"
           "});"
                         filename:@"wintertc_default_digest_provider.js"
                            error:&error] ||
        !wait_for_report(defaultReportProvider, @"default-digest-ok")) {
      fprintf(stderr, "WinterTC default digest provider verification failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSContext *invalidatedContext = [runtime createContextWithID:@"app://tests/wintertc-invalidated" error:&error];
    if (invalidatedContext == nil) {
      fprintf(stderr, "failed to create invalidated-context fixture: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    [invalidatedContext invalidate];
    if (EJSWinterTCInstallIntoContext(invalidatedContext, &error) ||
        error.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "install WinterTC after context invalidate should fail with invalidated error\n");
      return EXIT_FAILURE;
    }

    [streamServer stop];
    [runtime invalidate];
  }

  printf("ejs_wintertc_apple_test PASS\n");
  return EXIT_SUCCESS;
}
