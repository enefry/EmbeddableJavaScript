#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSWebSocketApple.h"

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
    [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"unsupported report method")];
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
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  if (result != 0 || ![provider.lastMessage isEqualToString:expected]) {
    fprintf(stderr, "unexpected report: expected=%s actual=%s\n", expected.UTF8String, provider.lastMessage.UTF8String);
    return NO;
  }
  return YES;
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

static NSString *ws_network_json(BOOL wsEnabled, NSString *defaultRule, NSArray *allowRules) {
  NSDictionary *config = @{
    @"version": @1,
    @"capabilities": @{
      @"ws": @(wsEnabled)
    },
    @"outbound": @{
      @"default": defaultRule ?: @"deny",
      @"allow": allowRules ?: @[]
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *ws_network_json_with_system_proxy(void) {
  NSDictionary *config = @{
    @"version": @1,
    @"capabilities": @{
      @"ws": @YES
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

static NSString *ws_network_json_with_private_network_denial(NSString *host) {
  NSDictionary *config = @{
    @"version": @1,
    @"capabilities": @{
      @"ws": @YES
    },
    @"outbound": @{
      @"default": @"deny",
      @"allow": @[ @{
        @"host": host,
        @"ports": @[ @9 ],
        @"protocols": @[ @"ws" ]
      } ],
      @"denyPrivateNetworks": @YES,
      @"denyLinkLocal": @YES
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *ws_network_json_with_link_local_denial(NSString *host) {
  NSDictionary *config = @{
    @"version": @1,
    @"capabilities": @{
      @"ws": @YES
    },
    @"outbound": @{
      @"default": @"deny",
      @"allow": @[ @{
        @"host": host,
        @"ports": @[ @9 ],
        @"protocols": @[ @"ws" ]
      } ],
      @"denyPrivateNetworks": @NO,
      @"denyLinkLocal": @YES
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

int main(void) {
  @autoreleasepool {
    NSError *error = nil;

#ifdef EJS_TEST
    if (!EJSWebSocketRunMessageLimitSelfTest(&error)) {
      fprintf(stderr, "websocket message limit self-test failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
#endif

    EJSContext *invalidPolicyContext = make_context(@"app://tests/ws/invalid-policy", @"{\"version\":1}", &error);
    if (invalidPolicyContext == nil) {
      fprintf(stderr, "failed to create invalid-policy context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (EJSWebSocketInstallIntoContext(invalidPolicyContext, &error)) {
      fprintf(stderr, "EJSWebSocketInstallIntoContext accepted invalid policy JSON\n");
      return EXIT_FAILURE;
    }
    [invalidPolicyContext.runtime invalidate];

    EJSContext *proxyContext = make_context(@"app://tests/ws/proxy-rejected", ws_network_json_with_system_proxy(), &error);
    if (proxyContext == nil) {
      fprintf(stderr, "failed to create proxy-rejected context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (EJSWebSocketInstallIntoContext(proxyContext, &error)) {
      fprintf(stderr, "EJSWebSocketInstallIntoContext accepted unsupported system proxy policy\n");
      return EXIT_FAILURE;
    }
    [proxyContext.runtime invalidate];

    EJSContext *defaultDenyContext = make_context(@"app://tests/ws/default-deny", nil, &error);
    if (defaultDenyContext == nil) {
      fprintf(stderr, "failed to create default-deny context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *defaultDenyReport = [[TestReportProvider alloc] init];
    if (![defaultDenyContext registerProvider:defaultDenyReport error:&error] ||
        !EJSWebSocketInstallIntoContext(defaultDenyContext, &error)) {
      fprintf(stderr, "failed to install default-deny ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(defaultDenyContext,
                    defaultDenyReport,
                    @"(function(){"
                     " const ws = new WebSocket('ws://127.0.0.1:9');"
                     " ws.onerror = function(){ __ejs_native__.invoke('test', 'report', ws._lastError && ws._lastError.code ? ws._lastError.code : 'missing'); };"
                     "})();",
                    @"ws_default_deny.js",
                    @"EPERM",
                    &error)) {
      return EXIT_FAILURE;
    }
    [defaultDenyContext.runtime invalidate];

    NSString *disabledJSON = ws_network_json(NO, @"allow", @[ @{ @"host": @"127.0.0.1", @"protocols": @[ @"ws" ] } ]);
    EJSContext *disabledContext = make_context(@"app://tests/ws/disabled-capability", disabledJSON, &error);
    if (disabledContext == nil) {
      fprintf(stderr, "failed to create disabled-capability context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *disabledReport = [[TestReportProvider alloc] init];
    if (![disabledContext registerProvider:disabledReport error:&error] ||
        !EJSWebSocketInstallIntoContext(disabledContext, &error)) {
      fprintf(stderr, "failed to install disabled-capability ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(disabledContext,
                    disabledReport,
                    @"(function(){"
                     " const ws = new WebSocket('ws://127.0.0.1:9');"
                     " ws.onerror = function(){ __ejs_native__.invoke('test', 'report', ws._lastError && ws._lastError.code ? ws._lastError.code : 'missing'); };"
                     "})();",
                    @"ws_disabled_capability.js",
                    @"EPERM",
                    &error)) {
      return EXIT_FAILURE;
    }
    [disabledContext.runtime invalidate];

    EJSContext *privateAddressContext = make_context(@"app://tests/ws/private-address-denied",
                                                     ws_network_json_with_private_network_denial(@"127.0.0.1"),
                                                     &error);
    if (privateAddressContext == nil) {
      fprintf(stderr, "failed to create private-address-denied context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *privateAddressReport = [[TestReportProvider alloc] init];
    if (![privateAddressContext registerProvider:privateAddressReport error:&error] ||
        !EJSWebSocketInstallIntoContext(privateAddressContext, &error)) {
      fprintf(stderr, "failed to install private-address-denied ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(privateAddressContext,
                    privateAddressReport,
                    @"(function(){"
                     " const ws = new WebSocket('ws://127.0.0.1:9');"
                     " ws.onerror = function(){ __ejs_native__.invoke('test', 'report', ws._lastError && ws._lastError.code ? ws._lastError.code : 'missing'); };"
                     "})();",
                    @"ws_private_address_denied.js",
                    @"EPERM",
                    &error)) {
      return EXIT_FAILURE;
    }
    [privateAddressContext.runtime invalidate];

    EJSContext *hostnameContext = make_context(@"app://tests/ws/hostname-denied",
                                               ws_network_json_with_private_network_denial(@"localhost"),
                                               &error);
    if (hostnameContext == nil) {
      fprintf(stderr, "failed to create hostname-denied context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *hostnameReport = [[TestReportProvider alloc] init];
    if (![hostnameContext registerProvider:hostnameReport error:&error] ||
        !EJSWebSocketInstallIntoContext(hostnameContext, &error)) {
      fprintf(stderr, "failed to install hostname-denied ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(hostnameContext,
                    hostnameReport,
                    @"(function(){"
                     " const ws = new WebSocket('ws://localhost:9');"
                     " ws.onerror = function(){ __ejs_native__.invoke('test', 'report', ws._lastError && ws._lastError.code ? ws._lastError.code : 'missing'); };"
                     "})();",
                    @"ws_hostname_denied.js",
                    @"EPERM",
                    &error)) {
      return EXIT_FAILURE;
    }
    [hostnameContext.runtime invalidate];

    EJSContext *linkLocalContext = make_context(@"app://tests/ws/link-local-denied",
                                                ws_network_json_with_link_local_denial(@"169.254.1.1"),
                                                &error);
    if (linkLocalContext == nil) {
      fprintf(stderr, "failed to create link-local-denied context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *linkLocalReport = [[TestReportProvider alloc] init];
    if (![linkLocalContext registerProvider:linkLocalReport error:&error] ||
        !EJSWebSocketInstallIntoContext(linkLocalContext, &error)) {
      fprintf(stderr, "failed to install link-local-denied ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(linkLocalContext,
                    linkLocalReport,
                    @"(function(){"
                     " const ws = new WebSocket('ws://169.254.1.1:9');"
                     " ws.onerror = function(){ __ejs_native__.invoke('test', 'report', ws._lastError && ws._lastError.code ? ws._lastError.code : 'missing'); };"
                     "})();",
                    @"ws_link_local_denied.js",
                    @"EPERM",
                    &error)) {
      return EXIT_FAILURE;
    }
    [linkLocalContext.runtime invalidate];

    NSString *allowJSON = ws_network_json(YES, @"allow", @[]);
    EJSContext *shapeContext = make_context(@"app://tests/ws/provider-shape", allowJSON, &error);
    if (shapeContext == nil) {
      fprintf(stderr, "failed to create provider-shape context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *shapeReport = [[TestReportProvider alloc] init];
    if (![shapeContext registerProvider:shapeReport error:&error] ||
        !EJSWebSocketInstallIntoContext(shapeContext, &error)) {
      fprintf(stderr, "failed to install provider-shape ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(shapeContext,
                    shapeReport,
                    @"(function(){"
                     " __ejs_native__.invoke('ejs.ws', 'close', JSON.stringify({})).then(function(){"
                     "   __ejs_native__.invoke('test', 'report', 'unexpected');"
                     " }).catch(function(error){"
                     "   __ejs_native__.invoke('test', 'report', String(error && error.code ? error.code : 0));"
                     " });"
                     "})();",
                    @"ws_provider_shape.js",
                    @"1",
                    &error)) {
      return EXIT_FAILURE;
    }
    [shapeContext.runtime invalidate];

    EJSContext *waiterContext = make_context(@"app://tests/ws/single-waiter", allowJSON, &error);
    if (waiterContext == nil) {
      fprintf(stderr, "failed to create single-waiter context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *waiterReport = [[TestReportProvider alloc] init];
    if (![waiterContext registerProvider:waiterReport error:&error] ||
        !EJSWebSocketInstallIntoContext(waiterContext, &error)) {
      fprintf(stderr, "failed to install single-waiter ws: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!run_script(waiterContext,
                    waiterReport,
                    @"(function(){"
                     " const socketID = 'manual-single-waiter';"
                     " __ejs_native__.invoke('ejs.ws', 'connect', JSON.stringify({ socketID: socketID, url: 'ws://198.51.100.1:9', protocols: [] })).then(function(){"
                     "   __ejs_native__.invoke('ejs.ws', 'nextEvent', JSON.stringify({ socketID: socketID })).catch(function(){});"
                     "   return __ejs_native__.invoke('ejs.ws', 'nextEvent', JSON.stringify({ socketID: socketID }));"
                     " }).then(function(){"
                     "   __ejs_native__.invoke('test', 'report', 'unexpected');"
                     " }).catch(function(error){"
                     "   const message = String(error && error.message ? error.message : '');"
                     "   __ejs_native__.invoke('test', 'report', message.indexOf('already pending') >= 0 ? 'busy' : message);"
                     " });"
                     "})();",
                    @"ws_single_waiter.js",
                    @"busy",
                    &error)) {
      return EXIT_FAILURE;
    }
    [waiterContext.runtime invalidate];
  }
  return EXIT_SUCCESS;
}
