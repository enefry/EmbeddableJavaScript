#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSNetApple.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
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

@interface TCPEchoServer : NSObject
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (atomic, assign) BOOL ok;
@end

@implementation TCPEchoServer
@end

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
  long result = dispatch_semaphore_wait(provider.semaphore,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
  if (result != 0 || ![provider.lastMessage isEqualToString:expected]) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n", expected.UTF8String, provider.lastMessage.UTF8String);
    return NO;
  }
  return YES;
}

static NSString *network_json_with_sections_and_limits(BOOL dns,
                                                       BOOL tcpConnect,
                                                       BOOL tcpListen,
                                                       BOOL udp,
                                                       NSArray<NSDictionary *> *outboundAllow,
                                                       NSArray<NSDictionary *> *inboundAllow,
                                                       NSDictionary *limits) {
  NSMutableDictionary *config = [@{
    @"version": @1,
    @"capabilities": @{
      @"dns": @(dns),
      @"tcpConnect": @(tcpConnect),
      @"tcpListen": @(tcpListen),
      @"udp": @(udp),
      @"xhr": @NO,
      @"ws": @NO
    },
    @"outbound": @{
      @"default": @"deny",
      @"allow": outboundAllow ?: @[],
      @"denyPrivateNetworks": @NO,
      @"denyLinkLocal": @NO
    },
    @"inbound": @{
      @"default": @"deny",
      @"allow": inboundAllow ?: @[]
    }
  } mutableCopy];
  if (limits != nil) {
    config[@"limits"] = limits;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *network_json_with_sections(BOOL dns,
                                            BOOL tcpConnect,
                                            BOOL tcpListen,
                                            BOOL udp,
                                            NSArray<NSDictionary *> *outboundAllow,
                                            NSArray<NSDictionary *> *inboundAllow) {
  return network_json_with_sections_and_limits(dns, tcpConnect, tcpListen, udp, outboundAllow, inboundAllow, nil);
}

static NSString *network_json_with_tcp(BOOL dns, BOOL tcpConnect, NSString *host, NSNumber *port) {
  NSMutableDictionary *rule = [@{
    @"host": host,
    @"protocols": @[ @"tcp" ]
  } mutableCopy];
  if (port != nil) {
    rule[@"ports"] = @[ port ];
  }
  return network_json_with_sections(dns, tcpConnect, NO, NO, @[ rule ], @[]);
}

static NSString *network_json(BOOL dns, NSString *host) {
  NSDictionary *hostRule = @{
    @"host": host,
    @"protocols": @[ @"dns" ]
  };
  NSDictionary *loopbackRule = @{
    @"cidr": @"127.0.0.0/8",
    @"protocols": @[ @"dns" ]
  };
  return network_json_with_sections(dns, NO, NO, NO, @[ hostRule, loopbackRule ], @[]);
}

static NSString *tcp_network_json(NSString *host, NSInteger port) {
  return network_json_with_tcp(NO, YES, host, @(port));
}

static NSString *tcp_server_network_json(BOOL tcpConnect,
                                         NSNumber *connectPort,
                                         BOOL tcpListen,
                                         NSNumber *listenPortStart,
                                         NSNumber *listenPortEnd) {
  NSMutableArray<NSDictionary *> *outboundAllow = [[NSMutableArray alloc] init];
  if (tcpConnect) {
    NSMutableDictionary *rule = [@{
      @"host": @"127.0.0.1",
      @"protocols": @[ @"tcp" ]
    } mutableCopy];
    if (connectPort != nil) {
      rule[@"ports"] = @[ connectPort ];
    }
    [outboundAllow addObject:rule];
  }
  NSMutableArray<NSDictionary *> *inboundAllow = [[NSMutableArray alloc] init];
  if (tcpListen) {
    NSMutableDictionary *rule = [@{
      @"address": @"127.0.0.1",
      @"protocols": @[ @"tcp" ]
    } mutableCopy];
    if (listenPortStart != nil && listenPortEnd != nil) {
      rule[@"portRange"] = @[ listenPortStart, listenPortEnd ];
    }
    [inboundAllow addObject:rule];
  }
  return network_json_with_sections(NO, tcpConnect, tcpListen, NO, outboundAllow, inboundAllow);
}

static NSString *udp_network_json(BOOL udpEnabled,
                                  NSArray<NSDictionary *> *outboundAllow,
                                  NSArray<NSDictionary *> *inboundAllow) {
  return network_json_with_sections(NO, NO, NO, udpEnabled, outboundAllow ?: @[], inboundAllow ?: @[]);
}

static NSString *udp_network_json_with_limits(BOOL udpEnabled,
                                              NSArray<NSDictionary *> *outboundAllow,
                                              NSArray<NSDictionary *> *inboundAllow,
                                              NSDictionary *limits) {
  return network_json_with_sections_and_limits(NO, NO, NO, udpEnabled, outboundAllow ?: @[], inboundAllow ?: @[], limits);
}

static TCPEchoServer *start_tcp_echo_server(NSInteger *portOut) {
  int listenFD = socket(AF_INET, SOCK_STREAM, 0);
  if (listenFD < 0) {
    fprintf(stderr, "server socket failed: %s\n", strerror(errno));
    return nil;
  }

  int yes = 1;
  setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(listenFD, (const struct sockaddr *)&address, sizeof(address)) != 0) {
    fprintf(stderr, "server bind failed: %s\n", strerror(errno));
    close(listenFD);
    return nil;
  }
  if (listen(listenFD, 1) != 0) {
    fprintf(stderr, "server listen failed: %s\n", strerror(errno));
    close(listenFD);
    return nil;
  }

  socklen_t addressLength = sizeof(address);
  if (getsockname(listenFD, (struct sockaddr *)&address, &addressLength) != 0) {
    fprintf(stderr, "server getsockname failed: %s\n", strerror(errno));
    close(listenFD);
    return nil;
  }

  TCPEchoServer *server = [[TCPEchoServer alloc] init];
  server.done = dispatch_semaphore_create(0);
  server.ok = NO;
  *portOut = ntohs(address.sin_port);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      fd_set readSet;
      FD_ZERO(&readSet);
      FD_SET(listenFD, &readSet);
      struct timeval timeout;
      timeout.tv_sec = 5;
      timeout.tv_usec = 0;
      int selected = select(listenFD + 1, &readSet, NULL, NULL, &timeout);
      if (selected > 0) {
        int clientFD = accept(listenFD, NULL, NULL);
        if (clientFD >= 0) {
          unsigned char input[4] = { 0 };
          size_t received = 0;
          while (received < sizeof(input)) {
            ssize_t count = recv(clientFD, input + received, sizeof(input) - received, 0);
            if (count <= 0) {
              break;
            }
            received += (size_t)count;
          }
          if (received == sizeof(input) && memcmp(input, "ping", sizeof(input)) == 0) {
            const unsigned char output[4] = { 'p', 'o', 'n', 'g' };
            ssize_t sent = send(clientFD, output, sizeof(output), 0);
            server.ok = sent == (ssize_t)sizeof(output);
          }
          close(clientFD);
        }
      }
      close(listenFD);
      dispatch_semaphore_signal(server.done);
    }
  });

  return server;
}

static NSInteger reserve_and_release_loopback_tcp_port(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
    close(fd);
    return -1;
  }
  if (listen(fd, 1) != 0) {
    close(fd);
    return -1;
  }
  socklen_t addressLength = sizeof(address);
  if (getsockname(fd, (struct sockaddr *)&address, &addressLength) != 0) {
    close(fd);
    return -1;
  }
  NSInteger port = ntohs(address.sin_port);
  close(fd);
  return port;
}

static EJSContext *make_context(NSString *contextID, NSString *configJSON, NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  if (configJSON != nil) {
    configuration.contextDefaults = @{ EJSNetworkConfigurationKey: configJSON };
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

static BOOL expect_invalid_policy_fails_install_with_config(NSString *contextID, NSString *configJSON) {
  NSError *error = nil;
  EJSContext *context = make_context(contextID, configJSON, &error);
  if (context == nil) {
    fprintf(stderr, "failed to create invalid-policy context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  error = nil;
  if (EJSNetInstallIntoContext(context, &error)) {
    fprintf(stderr, "EJSNetInstallIntoContext accepted invalid policy\n");
    return NO;
  }
  if (error == nil ||
      ![error.domain isEqualToString:EJSRuntimeErrorDomain] ||
      error.code != EJSRuntimeErrorCodeInvalidArgument) {
    fprintf(stderr, "unexpected invalid-policy error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  [context.runtime invalidate];
  return YES;
}

static BOOL expect_invalid_policy_fails_install(void) {
  return expect_invalid_policy_fails_install_with_config(
           @"app://tests/net/invalid-policy-dns-string",
           @"{\"version\":1,\"capabilities\":{\"dns\":\"yes\"},\"outbound\":{\"default\":\"deny\"}}") &&
         expect_invalid_policy_fails_install_with_config(
           @"app://tests/net/invalid-policy-tcp-listen-number",
           @"{\"version\":1,\"capabilities\":{\"dns\":false,\"tcpListen\":2},\"outbound\":{\"default\":\"deny\"}}") &&
         expect_invalid_policy_fails_install_with_config(
           @"app://tests/net/invalid-policy-deny-private-string",
           @"{\"version\":1,\"capabilities\":{\"dns\":false},\"outbound\":{\"default\":\"deny\",\"denyPrivateNetworks\":\"no\"}}") &&
         expect_invalid_policy_fails_install_with_config(
           @"app://tests/net/invalid-policy-inbound-string",
           @"{\"version\":1,\"capabilities\":{\"dns\":false},\"outbound\":{\"default\":\"deny\"},\"inbound\":\"deny\"}") &&
         expect_invalid_policy_fails_install_with_config(
           @"app://tests/net/invalid-policy-max-datagram",
           @"{\"version\":1,\"capabilities\":{\"dns\":false},\"outbound\":{\"default\":\"deny\"},\"limits\":{\"maxDatagramBytes\":0}}");
}

int main(void) {
  @autoreleasepool {
    if (!expect_invalid_policy_fails_install()) {
      return EXIT_FAILURE;
    }

    NSError *error = nil;
#ifdef EJS_TEST
    if (!EJSNetRunOperationCancellationSelfTest(&error)) {
      fprintf(stderr, "operation cancellation self-test failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
#endif

    EJSContext *defaultDenyContext = make_context(@"app://tests/net/default-deny", nil, &error);
    if (defaultDenyContext == nil) {
      fprintf(stderr, "failed to create default-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *defaultReport = [[TestReportProvider alloc] init];
    if (![defaultDenyContext registerProvider:defaultReport error:&error] ||
        !EJSNetInstallIntoContext(defaultDenyContext, &error)) {
      fprintf(stderr, "failed to install default-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(defaultDenyContext,
                    defaultReport,
                    @"(async function(){"
                     " try { await EJSNet.lookup('localhost'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.module); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'default-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_default_deny.js",
                    @"EJSNetworkError:EPERM:net",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(defaultDenyContext,
                    defaultReport,
                    @"(async function(){"
                     " try { await EJSNet.tcp.connect({ host: '127.0.0.1', port: 1, family: 4 }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'tcp-default-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_tcp_default_deny.js",
                    @"EJSNetworkError:EPERM:1",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(defaultDenyContext,
                    defaultReport,
                    @"(async function(){"
                     " try { await EJSNet.tcp.listen({ host: '127.0.0.1', port: 0, family: 4, backlog: 16, reuseAddress: true }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'listen-default-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_listen_default_deny.js",
                    @"EJSNetworkError:EPERM:0",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(defaultDenyContext,
                    defaultReport,
                    @"(async function(){"
                     " try { await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'udp-default-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_udp_default_deny.js",
                    @"EJSNetworkError:EPERM:0",
                    &error)) {
      return EXIT_FAILURE;
    }
    [defaultDenyContext.runtime invalidate];

    EJSContext *context = make_context(@"app://tests/net/lookup", network_json(YES, @"localhost"), &error);
    if (context == nil) {
      fprintf(stderr, "failed to create lookup context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error] ||
        !EJSNetInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const addresses = await EJSNet.lookup('localhost', { all: true });"
                     " const ok = Array.isArray(addresses) && addresses.length > 0 &&"
                     "   addresses.every((entry) => typeof entry.address === 'string' && (entry.family === 4 || entry.family === 6));"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'lookup-ok' : 'lookup-bad:' + JSON.stringify(addresses));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_lookup.js",
                    @"lookup-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSNet.lookup('blocked.invalid'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.host); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'policy-denied-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_policy_denied.js",
                    @"EJSNetworkError:EPERM:blocked.invalid",
                    &error)) {
      return EXIT_FAILURE;
    }

    [context.runtime invalidate];

    EJSContext *resolverFailContext = make_context(@"app://tests/net/lookup-resolver-fail",
                                                   network_json(YES, @"resolver-fail.invalid"),
                                                   &error);
    if (resolverFailContext == nil) {
      fprintf(stderr, "failed to create resolver-fail context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *resolverFailReport = [[TestReportProvider alloc] init];
    if (![resolverFailContext registerProvider:resolverFailReport error:&error] ||
        !EJSNetInstallIntoContext(resolverFailContext, &error)) {
      fprintf(stderr, "failed to install resolver-fail EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(resolverFailContext,
                    resolverFailReport,
                    @"(async function(){"
                     " try { await EJSNet.lookup('resolver-fail.invalid', { family: 4 }); }"
                     " catch (e) {"
                     "   const hasNative = typeof e.nativeDomain === 'string' && e.nativeDomain.length > 0 && Number.isInteger(e.nativeCode);"
                     "   const ok = e.code === 'EDNS' && e.host === 'resolver-fail.invalid' && e.family === 4 && hasNative;"
                     "   await __ejs_native__.invoke('test', 'report', ok ? 'lookup-resolver-fail-ok' : ('lookup-resolver-fail-bad:' + e.code + ':' + e.host + ':' + e.family + ':' + e.nativeDomain + ':' + e.nativeCode));"
                     "   return;"
                     " }"
                     " await __ejs_native__.invoke('test', 'report', 'lookup-resolver-fail-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_lookup_resolver_fail.js",
                    @"lookup-resolver-fail-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    [resolverFailContext.runtime invalidate];

    EJSContext *portDenyContext = make_context(@"app://tests/net/tcp-port-deny",
                                               tcp_network_json(@"127.0.0.1", 2),
                                               &error);
    if (portDenyContext == nil) {
      fprintf(stderr, "failed to create tcp port-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *portDenyReport = [[TestReportProvider alloc] init];
    if (![portDenyContext registerProvider:portDenyReport error:&error] ||
        !EJSNetInstallIntoContext(portDenyContext, &error)) {
      fprintf(stderr, "failed to install port-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(portDenyContext,
                    portDenyReport,
                    @"(async function(){"
                     " try { await EJSNet.tcp.connect({ host: '127.0.0.1', port: 1, family: 4, timeoutMs: 100 }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'tcp-port-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_tcp_port_deny.js",
                    @"EJSNetworkError:EPERM:1",
                    &error)) {
      return EXIT_FAILURE;
    }
    [portDenyContext.runtime invalidate];

    NSInteger refusedPort = reserve_and_release_loopback_tcp_port();
    if (refusedPort <= 0) {
      fprintf(stderr, "failed to reserve loopback port for tcp-refused test\n");
      return EXIT_FAILURE;
    }

    EJSContext *tcpRefusedContext = make_context(@"app://tests/net/tcp-refused",
                                                 tcp_network_json(@"127.0.0.1", refusedPort),
                                                 &error);
    if (tcpRefusedContext == nil) {
      fprintf(stderr, "failed to create tcp-refused context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *tcpRefusedReport = [[TestReportProvider alloc] init];
    if (![tcpRefusedContext registerProvider:tcpRefusedReport error:&error] ||
        !EJSNetInstallIntoContext(tcpRefusedContext, &error)) {
      fprintf(stderr, "failed to install tcp-refused EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *tcpRefusedSource = [NSString stringWithFormat:
      @"(async function(){"
       " try { await EJSNet.tcp.connect({ host: '127.0.0.1', port: %ld, family: 4, timeoutMs: 300 }); }"
       " catch (e) {"
       "   const hasNative = e.nativeDomain === 'NSPOSIXErrorDomain' && Number.isInteger(e.nativeCode);"
       "   const ok = e.code === 'ECONNREFUSED' && e.host === '127.0.0.1' && e.port === %ld && hasNative;"
       "   await __ejs_native__.invoke('test', 'report', ok ? 'tcp-refused-ok' : ('tcp-refused-bad:' + e.code + ':' + e.host + ':' + e.port + ':' + e.nativeDomain + ':' + e.nativeCode));"
       "   return;"
       " }"
       " await __ejs_native__.invoke('test', 'report', 'tcp-refused-missing-error');"
       "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
      (long)refusedPort,
      (long)refusedPort];
    if (!run_script(tcpRefusedContext,
                    tcpRefusedReport,
                    tcpRefusedSource,
                    @"net_tcp_refused.js",
                    @"tcp-refused-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    [tcpRefusedContext.runtime invalidate];

    EJSContext *listenPortDenyContext = make_context(@"app://tests/net/listen-port-deny",
                                                     tcp_server_network_json(NO, nil, YES, @2, @2),
                                                     &error);
    if (listenPortDenyContext == nil) {
      fprintf(stderr, "failed to create listen port-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *listenPortDenyReport = [[TestReportProvider alloc] init];
    if (![listenPortDenyContext registerProvider:listenPortDenyReport error:&error] ||
        !EJSNetInstallIntoContext(listenPortDenyContext, &error)) {
      fprintf(stderr, "failed to install listen port-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(listenPortDenyContext,
                    listenPortDenyReport,
                    @"(async function(){"
                     " try { await EJSNet.tcp.listen({ host: '127.0.0.1', port: 1, family: 4, backlog: 8 }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'listen-port-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_listen_port_deny.js",
                    @"EJSNetworkError:EPERM:1",
                    &error)) {
      return EXIT_FAILURE;
    }
    [listenPortDenyContext.runtime invalidate];

    EJSContext *listenAssignedDenyContext = make_context(@"app://tests/net/listen-assigned-deny",
                                                         tcp_server_network_json(NO, nil, YES, @1, @1),
                                                         &error);
    if (listenAssignedDenyContext == nil) {
      fprintf(stderr, "failed to create listen assigned-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *listenAssignedDenyReport = [[TestReportProvider alloc] init];
    if (![listenAssignedDenyContext registerProvider:listenAssignedDenyReport error:&error] ||
        !EJSNetInstallIntoContext(listenAssignedDenyContext, &error)) {
      fprintf(stderr, "failed to install listen assigned-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(listenAssignedDenyContext,
                    listenAssignedDenyReport,
                    @"(async function(){"
                     " try { await EJSNet.tcp.listen({ host: '127.0.0.1', port: 0, family: 4, backlog: 8 }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'listen-assigned-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_listen_assigned_deny.js",
                    @"EJSNetworkError:EPERM:0",
                    &error)) {
      return EXIT_FAILURE;
    }
    [listenAssignedDenyContext.runtime invalidate];

    NSInteger tcpPort = 0;
    TCPEchoServer *server = start_tcp_echo_server(&tcpPort);
    if (server == nil || tcpPort <= 0) {
      return EXIT_FAILURE;
    }
    EJSContext *tcpContext = make_context(@"app://tests/net/tcp-loopback",
                                          tcp_network_json(@"127.0.0.1", tcpPort),
                                          &error);
    if (tcpContext == nil) {
      fprintf(stderr, "failed to create tcp context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *tcpReport = [[TestReportProvider alloc] init];
    if (![tcpContext registerProvider:tcpReport error:&error] ||
        !EJSNetInstallIntoContext(tcpContext, &error)) {
      fprintf(stderr, "failed to install tcp EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *tcpSource = [NSString stringWithFormat:
      @"(async function(){"
       " const socket = await EJSNet.tcp.connect({ host: '127.0.0.1', port: %ld, family: 4, noDelay: true, timeoutMs: 3000 });"
       " await socket.write(new Uint8Array([112, 105, 110, 103]));"
       " const data = await socket.read({ maxBytes: 4 });"
       " await socket.shutdown();"
       " await socket.close();"
       " await socket.close();"
       " const text = String.fromCharCode.apply(null, data);"
       " const ok = text === 'pong' && socket.localAddress.port > 0 && socket.remoteAddress.port === %ld;"
       " await __ejs_native__.invoke('test', 'report', ok ? 'tcp-ok' : 'tcp-bad:' + text + ':' + JSON.stringify(socket.remoteAddress));"
       "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
      (long)tcpPort,
      (long)tcpPort];
    if (!run_script(tcpContext,
                    tcpReport,
                    tcpSource,
                    @"net_tcp_loopback.js",
                    @"tcp-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    long serverDone = dispatch_semaphore_wait(server.done,
                                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (serverDone != 0 || !server.ok) {
      fprintf(stderr, "tcp echo server did not complete successfully\n");
      return EXIT_FAILURE;
    }
    [tcpContext.runtime invalidate];

    EJSContext *tcpServerContext = make_context(@"app://tests/net/tcp-server-loopback",
                                                tcp_server_network_json(YES, nil, YES, @1024, @65535),
                                                &error);
    if (tcpServerContext == nil) {
      fprintf(stderr, "failed to create tcp server context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *tcpServerReport = [[TestReportProvider alloc] init];
    if (![tcpServerContext registerProvider:tcpServerReport error:&error] ||
        !EJSNetInstallIntoContext(tcpServerContext, &error)) {
      fprintf(stderr, "failed to install tcp server EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(tcpServerContext,
                    tcpServerReport,
                    @"(async function(){"
                     " const listener = await EJSNet.tcp.listen({ host: '127.0.0.1', port: 0, family: 4, backlog: 8, reuseAddress: true });"
                     " let code = 'missing';"
                     " try { await listener.accept({ timeoutMs: 1 }); } catch (e) { code = e.code; }"
                     " await listener.close();"
                     " await __ejs_native__.invoke('test', 'report', code === 'ETIMEOUT' ? 'accept-timeout-ok' : ('accept-timeout-bad:' + code));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_tcp_accept_timeout.js",
                    @"accept-timeout-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(tcpServerContext,
                    tcpServerReport,
                    @"(async function(){"
                     " const listener = await EJSNet.tcp.listen({ host: '127.0.0.1', port: 0, family: 4, backlog: 8, reuseAddress: true });"
                     " const pending = listener.accept({ timeoutMs: 3000 });"
                     " await listener.close();"
                     " let code = 'missing';"
                     " try { await pending; } catch (e) { code = e.code; }"
                     " await __ejs_native__.invoke('test', 'report', code === 'ECANCELLED' ? 'accept-cancel-ok' : ('accept-cancel-bad:' + code));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_tcp_accept_cancel.js",
                    @"accept-cancel-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(tcpServerContext,
                    tcpServerReport,
                    @"(async function(){"
                     " const listener = await EJSNet.tcp.listen({ host: '127.0.0.1', port: 0, family: 4, backlog: 8, reuseAddress: true });"
                     " const port = listener.localAddress.port;"
                     " const acceptedPromise = listener.accept({ timeoutMs: 3000 });"
                     " const client = await EJSNet.tcp.connect({ host: '127.0.0.1', port, family: 4, timeoutMs: 3000, noDelay: true });"
                     " const accepted = await acceptedPromise;"
                     " await client.write(new Uint8Array([112, 105, 110, 103]));"
                     " const inbound = await accepted.read({ maxBytes: 4 });"
                     " await accepted.write(inbound);"
                     " const echoed = await client.read({ maxBytes: 4 });"
                     " await client.shutdown();"
                     " await client.close();"
                     " await client.close();"
                     " await accepted.close();"
                     " await accepted.close();"
                     " await listener.close();"
                     " await listener.close();"
                     " let code = 'missing';"
                     " try { await listener.accept({ timeoutMs: 1 }); } catch (e) { code = e.code; }"
                     " const text = String.fromCharCode.apply(null, echoed);"
                     " const ok = port > 0 && text === 'ping' && accepted.remoteAddress.port > 0 && code === 'ECANCELLED';"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'tcp-server-ok' : ('tcp-server-bad:' + text + ':' + code + ':' + JSON.stringify(accepted.remoteAddress)));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_tcp_server_loopback.js",
                    @"tcp-server-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    [tcpServerContext.runtime invalidate];

    NSDictionary *udpOutboundAllow = @{
      @"host": @"127.0.0.1",
      @"protocols": @[ @"udp" ],
      @"portRange": @[ @1024, @65535 ]
    };
    NSDictionary *udpInboundAllow = @{
      @"address": @"127.0.0.1",
      @"protocols": @[ @"udp" ],
      @"portRange": @[ @1024, @65535 ]
    };

    EJSContext *udpInboundDenyContext = make_context(@"app://tests/net/udp-inbound-deny",
                                                     udp_network_json(YES,
                                                                      @[ udpOutboundAllow ],
                                                                      @[ @{ @"address": @"127.0.0.1", @"protocols": @[ @"udp" ], @"ports": @[ @2 ] } ]),
                                                     &error);
    if (udpInboundDenyContext == nil) {
      fprintf(stderr, "failed to create udp inbound-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpInboundDenyReport = [[TestReportProvider alloc] init];
    if (![udpInboundDenyContext registerProvider:udpInboundDenyReport error:&error] ||
        !EJSNetInstallIntoContext(udpInboundDenyContext, &error)) {
      fprintf(stderr, "failed to install udp inbound-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpInboundDenyContext,
                    udpInboundDenyReport,
                    @"(async function(){"
                     " try { await EJSNet.udp.bind({ host: '127.0.0.1', port: 1, family: 4, reuseAddress: true }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'udp-bind-port-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_udp_bind_port_deny.js",
                    @"EJSNetworkError:EPERM:1",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpInboundDenyContext.runtime invalidate];

    EJSContext *udpAssignedDenyContext = make_context(@"app://tests/net/udp-assigned-deny",
                                                      udp_network_json(YES,
                                                                       @[ udpOutboundAllow ],
                                                                       @[ @{ @"address": @"127.0.0.1", @"protocols": @[ @"udp" ], @"ports": @[ @1 ] } ]),
                                                      &error);
    if (udpAssignedDenyContext == nil) {
      fprintf(stderr, "failed to create udp assigned-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpAssignedDenyReport = [[TestReportProvider alloc] init];
    if (![udpAssignedDenyContext registerProvider:udpAssignedDenyReport error:&error] ||
        !EJSNetInstallIntoContext(udpAssignedDenyContext, &error)) {
      fprintf(stderr, "failed to install udp assigned-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpAssignedDenyContext,
                    udpAssignedDenyReport,
                    @"(async function(){"
                     " try { await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.port); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'udp-bind-assigned-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"net_udp_bind_assigned_deny.js",
                    @"EJSNetworkError:EPERM:0",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpAssignedDenyContext.runtime invalidate];

    EJSContext *udpLoopbackContext = make_context(@"app://tests/net/udp-loopback",
                                                  udp_network_json(YES, @[ udpOutboundAllow ], @[ udpInboundAllow ]),
                                                  &error);
    if (udpLoopbackContext == nil) {
      fprintf(stderr, "failed to create udp loopback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpLoopbackReport = [[TestReportProvider alloc] init];
    if (![udpLoopbackContext registerProvider:udpLoopbackReport error:&error] ||
        !EJSNetInstallIntoContext(udpLoopbackContext, &error)) {
      fprintf(stderr, "failed to install udp loopback EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpLoopbackContext,
                    udpLoopbackReport,
                    @"(async function(){"
                     " const sender = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " const receiver = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " await sender.send(new Uint8Array([112, 105, 110, 103]), { host: '127.0.0.1', port: receiver.localAddress.port, family: 4 });"
                     " const packet = await receiver.recv({ maxBytes: 8, timeoutMs: 3000 });"
                     " await sender.close();"
                     " await sender.close();"
                     " await receiver.close();"
                     " await receiver.close();"
                     " let code = 'missing';"
                     " try { await receiver.recv({ maxBytes: 1, timeoutMs: 1 }); } catch (e) { code = e.code; }"
                     " const text = String.fromCharCode.apply(null, packet.data);"
                     " const ok = text === 'ping' && packet.remoteAddress.port === sender.localAddress.port && code === 'ECANCELLED';"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'udp-loopback-ok' : ('udp-loopback-bad:' + text + ':' + code + ':' + JSON.stringify(packet.remoteAddress)));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_loopback.js",
                    @"udp-loopback-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(udpLoopbackContext,
                    udpLoopbackReport,
                    @"(async function(){"
                     " const socket = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " let code = 'missing';"
                     " try { await socket.recv({ maxBytes: 1, timeoutMs: 1 }); } catch (e) { code = e.code; }"
                     " await socket.close();"
                     " await __ejs_native__.invoke('test', 'report', code === 'ETIMEOUT' ? 'udp-timeout-ok' : ('udp-timeout-bad:' + code));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_timeout.js",
                    @"udp-timeout-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    if (!run_script(udpLoopbackContext,
                    udpLoopbackReport,
                    @"(async function(){"
                     " const socket = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " const pending = socket.recv({ maxBytes: 8, timeoutMs: 3000 });"
                     " await socket.close();"
                     " await socket.close();"
                     " let code = 'missing';"
                     " try { await pending; } catch (e) { code = e.code; }"
                     " await __ejs_native__.invoke('test', 'report', code === 'ECANCELLED' ? 'udp-cancel-ok' : ('udp-cancel-bad:' + code));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_cancel.js",
                    @"udp-cancel-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpLoopbackContext.runtime invalidate];

    EJSContext *udpSendDenyContext = make_context(@"app://tests/net/udp-send-deny",
                                                  udp_network_json(YES,
                                                                   @[ @{ @"host": @"127.0.0.1", @"protocols": @[ @"tcp" ], @"portRange": @[ @1, @65535 ] } ],
                                                                   @[ udpInboundAllow ]),
                                                  &error);
    if (udpSendDenyContext == nil) {
      fprintf(stderr, "failed to create udp send-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpSendDenyReport = [[TestReportProvider alloc] init];
    if (![udpSendDenyContext registerProvider:udpSendDenyReport error:&error] ||
        !EJSNetInstallIntoContext(udpSendDenyContext, &error)) {
      fprintf(stderr, "failed to install udp send-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpSendDenyContext,
                    udpSendDenyReport,
                    @"(async function(){"
                     " const socket = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " try {"
                     "   await socket.send(new Uint8Array([1]), { host: '127.0.0.1', port: socket.localAddress.port, family: 4 });"
                     " } catch (e) {"
                     "   await socket.close();"
                     "   await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.operation);"
                     "   return;"
                     " }"
                     " await socket.close();"
                     " await __ejs_native__.invoke('test', 'report', 'udp-send-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_send_deny.js",
                    @"EJSNetworkError:EPERM:send",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpSendDenyContext.runtime invalidate];

    EJSContext *udpNoPortDenyContext = make_context(@"app://tests/net/udp-no-port-deny",
                                                    udp_network_json(YES,
                                                                     @[ @{ @"host": @"127.0.0.1", @"protocols": @[ @"udp" ] } ],
                                                                     @[ udpInboundAllow ]),
                                                    &error);
    if (udpNoPortDenyContext == nil) {
      fprintf(stderr, "failed to create udp no-port-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpNoPortDenyReport = [[TestReportProvider alloc] init];
    if (![udpNoPortDenyContext registerProvider:udpNoPortDenyReport error:&error] ||
        !EJSNetInstallIntoContext(udpNoPortDenyContext, &error)) {
      fprintf(stderr, "failed to install udp no-port-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpNoPortDenyContext,
                    udpNoPortDenyReport,
                    @"(async function(){"
                     " const socket = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " try {"
                     "   await socket.send(new Uint8Array([1]), { host: '127.0.0.1', port: socket.localAddress.port, family: 4 });"
                     " } catch (e) {"
                     "   await socket.close();"
                     "   await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.operation);"
                     "   return;"
                     " }"
                     " await socket.close();"
                     " await __ejs_native__.invoke('test', 'report', 'udp-no-port-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_no_port_deny.js",
                    @"EJSNetworkError:EPERM:send",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpNoPortDenyContext.runtime invalidate];

    EJSContext *udpResolvedDenyContext = make_context(@"app://tests/net/udp-resolved-deny",
                                                      udp_network_json(YES,
                                                                       @[ @{ @"host": @"localhost", @"protocols": @[ @"udp" ], @"portRange": @[ @1024, @65535 ] } ],
                                                                       @[ udpInboundAllow ]),
                                                      &error);
    if (udpResolvedDenyContext == nil) {
      fprintf(stderr, "failed to create udp resolved-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpResolvedDenyReport = [[TestReportProvider alloc] init];
    if (![udpResolvedDenyContext registerProvider:udpResolvedDenyReport error:&error] ||
        !EJSNetInstallIntoContext(udpResolvedDenyContext, &error)) {
      fprintf(stderr, "failed to install udp resolved-deny EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpResolvedDenyContext,
                    udpResolvedDenyReport,
                    @"(async function(){"
                     " const socket = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " try {"
                     "   await socket.send(new Uint8Array([1]), { host: 'localhost', port: socket.localAddress.port, family: 4 });"
                     " } catch (e) {"
                     "   await socket.close();"
                     "   await __ejs_native__.invoke('test', 'report', e.name + ':' + e.code + ':' + e.operation);"
                     "   return;"
                     " }"
                     " await socket.close();"
                     " await __ejs_native__.invoke('test', 'report', 'udp-resolved-deny-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_resolved_deny.js",
                    @"EJSNetworkError:EPERM:send",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpResolvedDenyContext.runtime invalidate];

    EJSContext *udpLimitContext = make_context(@"app://tests/net/udp-limit",
                                               udp_network_json_with_limits(YES,
                                                                            @[ udpOutboundAllow ],
                                                                            @[ udpInboundAllow ],
                                                                            @{ @"maxDatagramBytes": @4 }),
                                               &error);
    if (udpLimitContext == nil) {
      fprintf(stderr, "failed to create udp limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *udpLimitReport = [[TestReportProvider alloc] init];
    if (![udpLimitContext registerProvider:udpLimitReport error:&error] ||
        !EJSNetInstallIntoContext(udpLimitContext, &error)) {
      fprintf(stderr, "failed to install udp limit EJSNet: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(udpLimitContext,
                    udpLimitReport,
                    @"(async function(){"
                     " const socket = await EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 4, reuseAddress: true });"
                     " let sendCode = 'missing';"
                     " try { await socket.send(new Uint8Array([1, 2, 3, 4, 5]), { host: '127.0.0.1', port: socket.localAddress.port, family: 4 }); } catch (e) { sendCode = e.code; }"
                     " let recvCode = 'missing';"
                     " try { await socket.recv({ maxBytes: 5, timeoutMs: 1 }); } catch (e) { recvCode = e.code; }"
                     " await socket.close();"
                     " await __ejs_native__.invoke('test', 'report', (sendCode === 'EINVAL' && recvCode === 'EINVAL') ? 'udp-limit-ok' : ('udp-limit-bad:' + sendCode + ':' + recvCode));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.name + ':' + e.code + ':' + e.message));",
                    @"net_udp_limit.js",
                    @"udp-limit-ok",
                    &error)) {
      return EXIT_FAILURE;
    }
    [udpLimitContext.runtime invalidate];
  }

  printf("ejs_net_apple_test PASS\n");
  return EXIT_SUCCESS;
}
