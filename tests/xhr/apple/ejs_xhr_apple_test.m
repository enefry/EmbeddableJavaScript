#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSXHRApple.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

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

@interface XHRLocalHTTPServer : NSObject
@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, assign, readonly) BOOL streamLargeSawEarlyClose;
@property (nonatomic, assign, readonly) BOOL streamLargeFinishedWriting;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

@implementation XHRLocalHTTPServer {
  int _listenFD;
  dispatch_queue_t _queue;
  dispatch_group_t _group;
  atomic_bool _running;
  atomic_bool _streamLargeSawEarlyClose;
  atomic_bool _streamLargeFinishedWriting;
  uint16_t _port;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _listenFD = -1;
    _queue = dispatch_queue_create("dev.ejs.tests.xhr.fixture", DISPATCH_QUEUE_SERIAL);
    _group = dispatch_group_create();
    _running = false;
    _streamLargeSawEarlyClose = false;
    _streamLargeFinishedWriting = false;
    _port = 0;
  }
  return self;
}

- (uint16_t)port {
  return _port;
}

- (BOOL)streamLargeSawEarlyClose {
  return atomic_load(&_streamLargeSawEarlyClose);
}

- (BOOL)streamLargeFinishedWriting {
  return atomic_load(&_streamLargeFinishedWriting);
}

static BOOL write_all(int fd, const void *bytes, size_t length) {
  const uint8_t *cursor = (const uint8_t *)bytes;
  size_t remaining = length;
  while (remaining > 0u) {
    ssize_t wrote = write(fd, cursor, remaining);
    if (wrote <= 0) {
      return NO;
    }
    cursor += (size_t)wrote;
    remaining -= (size_t)wrote;
  }
  return YES;
}

- (void)respondToClient:(int)clientFD
                   path:(NSString *)path
          requestHeader:(NSString *)headerValue
                   body:(NSString *)requestBody {
  if ([path isEqualToString:@"/slow"]) {
    usleep(300 * 1000);
  }
  if ([path isEqualToString:@"/stream-large"]) {
    atomic_store(&_streamLargeSawEarlyClose, false);
    atomic_store(&_streamLargeFinishedWriting, false);
    NSString *headers = [NSString stringWithFormat:
      @"HTTP/1.1 200 OK\r\n"
       "Content-Type: text/plain\r\n"
       "Content-Length: %d\r\n"
       "Connection: close\r\n"
       "X-Echo-Header: %@\r\n"
       "\r\n",
       1024 * 64,
       headerValue ?: @""];
    if (!write_all(clientFD, headers.UTF8String, strlen(headers.UTF8String))) {
      atomic_store(&_streamLargeSawEarlyClose, true);
      return;
    }
    uint8_t chunk[1024];
    memset(chunk, 'x', sizeof(chunk));
    for (int i = 0; i < 64; ++i) {
      if (!write_all(clientFD, chunk, sizeof(chunk))) {
        atomic_store(&_streamLargeSawEarlyClose, true);
        return;
      }
      usleep(2 * 1000);
    }
    atomic_store(&_streamLargeFinishedWriting, true);
    return;
  }
  NSString *body = [NSString stringWithFormat:@"ok:%@", requestBody ?: @""];
  NSString *contentType = @"text/plain";
  if ([path isEqualToString:@"/slow"]) {
    body = @"slow-body";
  } else if ([path isEqualToString:@"/large"]) {
    body = @"too-large";
  } else if ([path isEqualToString:@"/utf8"]) {
    body = [NSString stringWithFormat:@"utf8-%C-%C%C", (unichar)0x00e9, (unichar)0x4f60, (unichar)0x597d];
  } else if ([path isEqualToString:@"/json"] || [path isEqualToString:@"/invalid-json"]) {
    contentType = @"application/json";
    body = [path isEqualToString:@"/json"] ? @"{\"ok\":true,\"from\":\"fixture\"}" : @"{broken";
  } else if ([path isEqualToString:@"/binary"]) {
    static const uint8_t binaryBytes[] = { 0x00, 0xff, 0x22, 0x0a };
    NSData *binaryData = [NSData dataWithBytes:binaryBytes length:sizeof(binaryBytes)];
    NSString *headers = [NSString stringWithFormat:
      @"HTTP/1.1 200 OK\r\n"
       "Content-Type: application/octet-stream\r\n"
       "Content-Length: %lu\r\n"
       "Connection: close\r\n"
       "X-Echo-Header: %@\r\n"
       "\r\n",
       (unsigned long)binaryData.length,
       headerValue ?: @""];
    write_all(clientFD, headers.UTF8String, strlen(headers.UTF8String));
    write_all(clientFD, binaryData.bytes, binaryData.length);
    return;
  }
  NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  NSString *headers = [NSString stringWithFormat:
    @"HTTP/1.1 200 OK\r\n"
     "Content-Type: %@\r\n"
     "Content-Length: %lu\r\n"
     "Connection: close\r\n"
     "X-Echo-Header: %@\r\n"
     "\r\n",
     contentType,
     (unsigned long)bodyData.length,
     headerValue ?: @""];
  write_all(clientFD, headers.UTF8String, strlen(headers.UTF8String));
  write_all(clientFD, bodyData.bytes, bodyData.length);
}

- (void)handleClient:(int)clientFD {
  NSMutableData *requestData = [[NSMutableData alloc] init];
  const NSUInteger maxHeaderBytes = 64u * 1024u;
  ssize_t headerEnd = -1;
  while (requestData.length < maxHeaderBytes) {
    uint8_t buffer[1024];
    ssize_t count = recv(clientFD, buffer, sizeof(buffer), 0);
    if (count <= 0) {
      return;
    }
    [requestData appendBytes:buffer length:(NSUInteger)count];
    NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange range = [requestData rangeOfData:marker options:0 range:NSMakeRange(0, requestData.length)];
    if (range.location != NSNotFound) {
      headerEnd = (ssize_t)(range.location + range.length);
      break;
    }
  }
  if (headerEnd <= 0) {
    return;
  }

  NSData *headerBytes = [requestData subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)];
  NSString *headerText = [[NSString alloc] initWithData:headerBytes encoding:NSUTF8StringEncoding] ?: @"";
  NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
  NSString *requestLine = lines.count > 0 ? lines[0] : @"";
  NSArray<NSString *> *requestLineParts = [requestLine componentsSeparatedByString:@" "];
  NSString *path = requestLineParts.count > 1 ? requestLineParts[1] : @"/";
  NSString *echoHeader = @"";
  NSInteger contentLength = 0;
  for (NSString *line in lines) {
    NSString *lower = line.lowercaseString;
    if ([lower hasPrefix:@"x-test-header:"]) {
      echoHeader = [[line componentsSeparatedByString:@":"] count] >= 2
        ? [[[line componentsSeparatedByString:@":"] subarrayWithRange:NSMakeRange(1, [[line componentsSeparatedByString:@":"] count] - 1)] componentsJoinedByString:@":"]
        : @"";
      echoHeader = [echoHeader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    } else if ([lower hasPrefix:@"content-length:"]) {
      NSString *value = [[line componentsSeparatedByString:@":"] count] >= 2
        ? [[[line componentsSeparatedByString:@":"] subarrayWithRange:NSMakeRange(1, [[line componentsSeparatedByString:@":"] count] - 1)] componentsJoinedByString:@":"]
        : @"0";
      contentLength = value.integerValue;
    }
  }

  NSMutableData *bodyData = [[NSMutableData alloc] init];
  NSUInteger alreadyBuffered = requestData.length > (NSUInteger)headerEnd ? requestData.length - (NSUInteger)headerEnd : 0u;
  if (alreadyBuffered > 0u) {
    [bodyData appendData:[requestData subdataWithRange:NSMakeRange((NSUInteger)headerEnd, alreadyBuffered)]];
  }
  while ((NSInteger)bodyData.length < contentLength) {
    uint8_t buffer[1024];
    ssize_t count = recv(clientFD, buffer, sizeof(buffer), 0);
    if (count <= 0) {
      break;
    }
    [bodyData appendBytes:buffer length:(NSUInteger)count];
  }
  NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] ?: @"";
  [self respondToClient:clientFD path:path requestHeader:echoHeader body:body];
}

- (BOOL)start:(NSError **)error {
  if (_listenFD >= 0) {
    return YES;
  }
  _listenFD = socket(AF_INET, SOCK_STREAM, 0);
  if (_listenFD < 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    return NO;
  }

  int yes = 1;
  setsockopt(_listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(_listenFD, (const struct sockaddr *)&address, sizeof(address)) != 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    close(_listenFD);
    _listenFD = -1;
    return NO;
  }
  if (listen(_listenFD, 16) != 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    close(_listenFD);
    _listenFD = -1;
    return NO;
  }
  socklen_t length = sizeof(address);
  if (getsockname(_listenFD, (struct sockaddr *)&address, &length) != 0) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    close(_listenFD);
    _listenFD = -1;
    return NO;
  }
  _port = ntohs(address.sin_port);
  _running = true;

  dispatch_group_enter(_group);
  dispatch_async(_queue, ^{
    while (atomic_load(&self->_running)) {
      int clientFD = accept(self->_listenFD, NULL, NULL);
      if (clientFD < 0) {
        if (errno == EINTR) {
          continue;
        }
        break;
      }
      int noSigPipe = 1;
      (void)setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
      @autoreleasepool {
        [self handleClient:clientFD];
      }
      close(clientFD);
    }
    dispatch_group_leave(self->_group);
  });

  return YES;
}

- (void)stop {
  if (_listenFD < 0) {
    return;
  }
  atomic_store(&_running, false);
  shutdown(_listenFD, SHUT_RDWR);
  close(_listenFD);
  _listenFD = -1;
  dispatch_group_wait(_group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
}

@end

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  if (result != 0 || ![provider.lastMessage isEqualToString:expected]) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n", expected.UTF8String, provider.lastMessage.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL wait_for_stream_large_terminal(XHRLocalHTTPServer *server) {
  for (int i = 0; i < 200; ++i) {
    if (server.streamLargeSawEarlyClose || server.streamLargeFinishedWriting) {
      return YES;
    }
    usleep(5 * 1000);
  }
  return NO;
}

static NSString *xhr_network_json_with_limits_and_flags(BOOL xhrEnabled,
                                                        NSString *host,
                                                        NSInteger port,
                                                        NSDictionary *limits,
                                                        BOOL denyPrivateNetworks) {
  NSMutableDictionary *allowRule = [@{
    @"host": host,
    @"protocols": @[ @"xhr" ]
  } mutableCopy];
  if (port > 0) {
    allowRule[@"ports"] = @[ @(port) ];
  }

  NSMutableDictionary *config = [@{
    @"version": @1,
    @"capabilities": @{
      @"dns": @NO,
      @"tcpConnect": @NO,
      @"tcpListen": @NO,
      @"udp": @NO,
      @"xhr": @(xhrEnabled),
      @"ws": @NO
    },
    @"outbound": @{
      @"default": @"deny",
      @"allow": host.length > 0 ? @[ allowRule ] : @[],
      @"denyPrivateNetworks": @(denyPrivateNetworks),
      @"denyLinkLocal": @YES
    }
  } mutableCopy];
  if (limits != nil) {
    config[@"limits"] = limits;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *xhr_network_json_with_limits(BOOL xhrEnabled, NSString *host, NSInteger port, NSDictionary *limits) {
  return xhr_network_json_with_limits_and_flags(xhrEnabled, host, port, limits, NO);
}

static NSString *xhr_network_json(BOOL xhrEnabled, NSString *host, NSInteger port) {
  return xhr_network_json_with_limits(xhrEnabled, host, port, nil);
}

static NSString *xhr_network_json_with_system_proxy(void) {
  NSDictionary *config = @{
    @"version": @1,
    @"capabilities": @{
      @"xhr": @YES
    },
    @"outbound": @{
      @"default": @"allow",
      @"allow": @[]
    },
    @"http": @{
      @"useSystemProxy": @YES
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static EJSContext *make_context(NSString *contextID, NSString *networkJSON, NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  if (networkJSON != nil) {
    configuration.contextDefaults = @{ @"ejs.network": networkJSON };
  }
  EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
  return [runtime createContextWithID:contextID error:error];
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
    XHRLocalHTTPServer *server = [[XHRLocalHTTPServer alloc] init];
    NSError *error = nil;
    if (![server start:&error]) {
      fprintf(stderr, "failed to start xhr local fixture: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSContext *proxyContext = make_context(@"app://tests/xhr/proxy-rejected", xhr_network_json_with_system_proxy(), &error);
    if (proxyContext == nil) {
      fprintf(stderr, "failed to create proxy-rejected context: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    if (EJSXHRInstallIntoContext(proxyContext, &error)) {
      fprintf(stderr, "EJSXHRInstallIntoContext accepted unsupported system proxy policy\n");
      [server stop];
      return EXIT_FAILURE;
    }
    [proxyContext.runtime invalidate];

    EJSContext *defaultDenyContext = make_context(@"app://tests/xhr/default-deny", nil, &error);
    if (defaultDenyContext == nil) {
      fprintf(stderr, "failed to create default-deny context: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    TestReportProvider *defaultReport = [[TestReportProvider alloc] init];
    if (![defaultDenyContext registerProvider:defaultReport error:&error] ||
        !EJSXHRInstallIntoContext(defaultDenyContext, &error)) {
      fprintf(stderr, "failed to install default-deny xhr: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    NSString *denyURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/policy", server.port];
    if (!run_script(defaultDenyContext,
                    defaultReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing'); };"
                       " xhr.send();"
                       "})();", denyURL],
                    @"xhr_default_deny.js",
                    @"EPERM",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }
    [defaultDenyContext.runtime invalidate];

    NSString *disabledJSON = xhr_network_json(NO, @"127.0.0.1", server.port);
    EJSContext *disabledContext = make_context(@"app://tests/xhr/disabled-capability", disabledJSON, &error);
    if (disabledContext == nil) {
      fprintf(stderr, "failed to create disabled-capability context: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    TestReportProvider *disabledReport = [[TestReportProvider alloc] init];
    if (![disabledContext registerProvider:disabledReport error:&error] ||
        !EJSXHRInstallIntoContext(disabledContext, &error)) {
      fprintf(stderr, "failed to install disabled-capability xhr: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    if (!run_script(disabledContext,
                    disabledReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing'); };"
                       " xhr.send();"
                       "})();", denyURL],
                    @"xhr_disabled_capability.js",
                    @"EPERM",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }
    [disabledContext.runtime invalidate];

    NSString *resolvedDenyJSON = xhr_network_json_with_limits_and_flags(YES, @"localhost", server.port, nil, YES);
    EJSContext *resolvedDenyContext = make_context(@"app://tests/xhr/resolved-deny", resolvedDenyJSON, &error);
    if (resolvedDenyContext == nil) {
      fprintf(stderr, "failed to create resolved-deny context: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    TestReportProvider *resolvedDenyReport = [[TestReportProvider alloc] init];
    if (![resolvedDenyContext registerProvider:resolvedDenyReport error:&error] ||
        !EJSXHRInstallIntoContext(resolvedDenyContext, &error)) {
      fprintf(stderr, "failed to install resolved-deny xhr: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    NSString *localhostURL = [NSString stringWithFormat:@"http://localhost:%hu/rebind", server.port];
    if (!run_script(resolvedDenyContext,
                    resolvedDenyReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing'); };"
                       " xhr.send();"
                       "})();", localhostURL],
                    @"xhr_resolved_deny.js",
                    @"EPERM",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }
    [resolvedDenyContext.runtime invalidate];

    NSString *allowJSON = xhr_network_json(YES, @"127.0.0.1", server.port);
    EJSContext *successContext = make_context(@"app://tests/xhr/success", allowJSON, &error);
    if (successContext == nil) {
      fprintf(stderr, "failed to create success context: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    TestReportProvider *successReport = [[TestReportProvider alloc] init];
    if (![successContext registerProvider:successReport error:&error] ||
        !EJSXHRInstallIntoContext(successContext, &error)) {
      fprintf(stderr, "failed to install success xhr: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *successURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/success", server.port];
    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " const states = [];"
                       " xhr.onreadystatechange = function(){ states.push(xhr.readyState); };"
                       " xhr.open('POST', '%@');"
                       " xhr.setRequestHeader('X-Test-Header', 'client-ok');"
                       " xhr.onload = function(){"
                       "   const header = xhr.getResponseHeader('x-echo-header') || '';"
                       "   const headers = xhr.getAllResponseHeaders().toLowerCase().indexOf('x-echo-header: client-ok') >= 0 ? 'headers-ok' : 'headers-bad';"
                       "   const tail = states.length > 0 ? states[states.length - 1] : 0;"
                       "   __ejs_native__.invoke('test', 'report', 'ok:' + xhr.status + ':' + header + ':' + xhr.responseText + ':' + headers + ':' + tail);"
                       " };"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', 'error:' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'unknown')); };"
                       " xhr.send('hello');"
                       "})();", successURL],
                    @"xhr_success.js",
                    @"ok:200:client-ok:ok:hello:headers-ok:4",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.setRequestHeader('Authorization', 'secret');"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing'); };"
                       " xhr.send();"
                       "})();", successURL],
                    @"xhr_forbidden_header.js",
                    @"EPERM",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *utf8URL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/utf8", server.port];
    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.onload = function(){ __ejs_native__.invoke('test', 'report', xhr.responseText === 'utf8-\\u00e9-\\u4f60\\u597d' ? 'utf8-ok' : ('utf8-bad:' + xhr.responseText)); };"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', 'error:' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'unknown')); };"
                       " xhr.send();"
                       "})();", utf8URL],
                    @"xhr_utf8.js",
                    @"utf8-ok",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *binaryURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/binary", server.port];
    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " const events = [];"
                       " let progressLoaded = -1;"
                       " let progressTotal = -1;"
                       " let progressComputable = false;"
                       " let progressReadyState = -1;"
                       " xhr.responseType = 'arraybuffer';"
                       " xhr.addEventListener('loadstart', function(){ events.push('loadstart'); });"
                       " xhr.addEventListener('progress', function(event){ events.push('progress'); progressLoaded = event.loaded; progressTotal = event.total; progressComputable = event.lengthComputable; progressReadyState = xhr.readyState; });"
                       " xhr.addEventListener('load', function(){ events.push('load'); });"
                       " xhr.addEventListener('loadend', function(){ events.push('loadend');"
                       "   const bytes = xhr.response instanceof ArrayBuffer ? Array.from(new Uint8Array(xhr.response)).join(',') : 'bad';"
                       "   const textMode = xhr.responseText === '' ? 'empty' : 'not-empty';"
                       "   __ejs_native__.invoke('test', 'report', 'array:' + bytes + ':' + textMode + ':' + events.join(',') + ':' + progressLoaded + ':' + progressTotal + ':' + (progressComputable ? '1' : '0') + ':' + progressReadyState);"
                       " });"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', 'error:' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'unknown')); };"
                       " xhr.open('GET', '%@');"
                       " xhr.send();"
                       "})();", binaryURL],
                    @"xhr_arraybuffer.js",
                    @"array:0,255,34,10:empty:loadstart,progress,load,loadend:4:4:1:3",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *jsonURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/json", server.port];
    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.responseType = 'json';"
                       " xhr.onload = function(){"
                       "   const ok = xhr.response && xhr.response.ok === true && xhr.response.from === 'fixture';"
                       "   __ejs_native__.invoke('test', 'report', 'json:' + (ok ? 'ok' : 'bad') + ':' + xhr.responseText);"
                       " };"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', 'error:' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'unknown')); };"
                       " xhr.open('GET', '%@');"
                       " xhr.send();"
                       "})();", jsonURL],
                    @"xhr_json.js",
                    @"json:ok:{\"ok\":true,\"from\":\"fixture\"}",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *invalidJSONURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/invalid-json", server.port];
    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " const events = [];"
                       " const states = [];"
                       " xhr.responseType = 'json';"
                       " xhr.onreadystatechange = function(){ states.push(xhr.readyState); };"
                       " xhr.addEventListener('loadstart', function(){ events.push('loadstart'); });"
                       " xhr.addEventListener('error', function(){ events.push('error'); });"
                       " xhr.addEventListener('load', function(){ events.push('load'); });"
                       " xhr.addEventListener('loadend', function(){ events.push('loadend'); __ejs_native__.invoke('test', 'report', states.join(',') + ':' + events.join(',') + ':' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing')); });"
                       " xhr.open('GET', '%@');"
                       " xhr.send();"
                       "})();", invalidJSONURL],
                    @"xhr_invalid_json.js",
                    @"1,2,3,4:loadstart,error,loadend:EINTERNAL",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *cancelBeforeRegisterURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/cancel-before-register", server.port];
    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " const events = [];"
                       " xhr.addEventListener('abort', function(){ events.push('abort'); });"
                       " xhr.addEventListener('loadend', function(){ events.push('loadend'); __ejs_native__.invoke('test', 'report', events.join(',') + ':' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing')); });"
                       " xhr.open('GET', '%@');"
                       " xhr.send();"
                       "})();", cancelBeforeRegisterURL],
                    @"xhr_cancel_before_register.js",
                    @"abort,loadend:ECANCELLED",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *limitJSON = xhr_network_json_with_limits(YES, @"127.0.0.1", server.port, @{ @"maxBodyBytes": @4 });
    EJSContext *limitContext = make_context(@"app://tests/xhr/body-limit", limitJSON, &error);
    if (limitContext == nil) {
      fprintf(stderr, "failed to create body-limit context: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    TestReportProvider *limitReport = [[TestReportProvider alloc] init];
    if (![limitContext registerProvider:limitReport error:&error] ||
        !EJSXHRInstallIntoContext(limitContext, &error)) {
      fprintf(stderr, "failed to install body-limit xhr: %s\n", error.localizedDescription.UTF8String);
      [server stop];
      return EXIT_FAILURE;
    }
    NSString *largeURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/large", server.port];
    if (!run_script(limitContext,
                    limitReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing'); };"
                       " xhr.send();"
                       "})();", largeURL],
                    @"xhr_body_limit.js",
                    @"EPERM",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    NSString *streamLargeURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/stream-large", server.port];
    if (!run_script(limitContext,
                    limitReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.open('GET', '%@');"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing'); };"
                       " xhr.send();"
                       "})();", streamLargeURL],
                    @"xhr_body_limit_streaming.js",
                    @"EPERM",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }
    if (!wait_for_stream_large_terminal(server)) {
      fprintf(stderr, "streaming body-limit fixture did not reach a terminal write state\n");
      [server stop];
      return EXIT_FAILURE;
    }
    if (![server streamLargeSawEarlyClose]) {
      fprintf(stderr, "streaming body-limit request did not terminate early on fixture side\n");
      [server stop];
      return EXIT_FAILURE;
    }
    [limitContext.runtime invalidate];

    NSString *slowURL = [NSString stringWithFormat:@"http://127.0.0.1:%hu/slow", server.port];
    if (!run_script(successContext,
                    successReport,
                    @"(function(){"
                     " const xhr = new XMLHttpRequest();"
                     " const events = [];"
                     " xhr.addEventListener('abort', function(){ events.push('abort'); });"
                     " xhr.addEventListener('loadend', function(){ events.push('loadend'); });"
                     " xhr.open('GET', 'http://127.0.0.1/opened');"
                     " xhr.abort();"
                     " __ejs_native__.invoke('test', 'report', 'opened-abort:' + xhr.readyState + ':' + events.join(','));"
                     "})();",
                    @"xhr_opened_abort.js",
                    @"opened-abort:0:",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " xhr.timeout = 50;"
                       " xhr.open('GET', '%@');"
                       " xhr.ontimeout = function(){ __ejs_native__.invoke('test', 'report', 'timeout:' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'missing')); };"
                       " xhr.onerror = function(){ __ejs_native__.invoke('test', 'report', 'error:' + (xhr._lastError && xhr._lastError.code ? xhr._lastError.code : 'unknown')); };"
                       " xhr.send();"
                       "})();", slowURL],
                    @"xhr_timeout.js",
                    @"timeout:ETIMEOUT",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    if (!run_script(successContext,
                    successReport,
                    [NSString stringWithFormat:
                      @"(function(){"
                       " const xhr = new XMLHttpRequest();"
                       " const events = [];"
                       " xhr.addEventListener('abort', function(){ events.push('abort'); });"
                       " xhr.addEventListener('loadend', function(){ events.push('loadend'); });"
                       " xhr.open('GET', '%@');"
                       " xhr.send();"
                       " xhr.abort();"
                       " Promise.resolve().then(function(){"
                       "   __ejs_native__.invoke('test', 'report', events.join(',') + ':' + xhr.readyState + ':' + xhr.status);"
                       " });"
                       "})();", slowURL],
                    @"xhr_abort.js",
                    @"abort,loadend:0:0",
                    &error)) {
      [server stop];
      return EXIT_FAILURE;
    }

    [successContext.runtime invalidate];
    [server stop];
  }
  return EXIT_SUCCESS;
}
