#import "EJSAppleCLISupport.h"

#import "EJSApplePlatform.h"
#import "EJSFileSystemApple.h"
#import "EJSWinterTCApple.h"
#import "EJSSystemApple.h"
#import "EJSFSWatchApple.h"
#import "EJSPathApple.h"
#import "EJSBufferApple.h"
#import "EJSKeyValueStoreApple.h"
#import "EJSSQLiteApple.h"
#import "EJSHashingApple.h"
#import "EJSUUIDApple.h"
#import "EJSWorkerApple.h"
#import "EJSNetApple.h"
#import "EJSXHRApple.h"
#import "EJSWebSocketApple.h"
#import "EJSIPAddrApple.h"

#include <limits.h>
#include <math.h>

@interface EJSCLICompletionProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@property (nonatomic, strong, readonly) dispatch_semaphore_t semaphore;
@property (nonatomic, copy) NSString *result;
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, assign, readonly) BOOL exitRequested;
@property (nonatomic, assign, readonly) int exitCode;
@property (nonatomic, copy, readonly) NSString *exitMessage;
- (void)completeWithResult:(NSString *)result failed:(BOOL)failed;
- (void)requestExitWithCode:(int)exitCode message:(NSString *)message;
@end

@interface EJSCLIProcessProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithCompletionProvider:(EJSCLICompletionProvider *)completionProvider
                                 arguments:(NSArray<NSString *> *)arguments NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation EJSCLIRunOptions

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _runtimeName = @"ejs_apple_cli";
        _contextID = @"app://tools/ejs-apple-cli";
        _timeoutSeconds = 5.0;
        _daemonMode = NO;
    }
    return self;
}

@end

static NSString *EJSCLIStringFromData(NSData *data) {
    if (data.length == 0u) {
        return @"";
    }
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static NSData *EJSCLIDataFromString(NSString *string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
}

static NSDictionary *EJSCLIJSONObjectFromData(NSData *data) {
    if (data.length == 0u) {
        return @{};
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : @{};
}

static NSData *EJSCLIJSONData(id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return [NSData data];
    }
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] ?: [NSData data];
}

static NSData *EJSCLIJSONDictionaryData(NSDictionary *object) {
    return EJSCLIJSONData(object);
}

static NSString *EJSCLIFSConfigurationJSON(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *cwd = fileManager.currentDirectoryPath ?: @".";
    NSString *tmp = NSTemporaryDirectory() ?: @"/tmp";
    NSDictionary *configuration = @{
        @"version": @1,
        @"defaultRoot": @"cwd",
        @"roots": @{
            @"cwd": @{
                @"path": [cwd stringByStandardizingPath],
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @NO
            },
            @"tmp": @{
                @"path": [tmp stringByStandardizingPath],
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @YES
            }
        },
        @"limits": @{
            @"maxReadBytes": @(8ull * 1024ull * 1024ull),
            @"maxWriteBytes": @(8ull * 1024ull * 1024ull)
        },
        @"pathPolicy": @{
            @"allowAbsolutePath": @NO,
            @"allowParentTraversal": @NO,
            @"allowSymlinkEscape": @NO
        }
    };

    NSData *data = EJSCLIJSONData(configuration);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *EJSCLIFSWATCHConfigurationJSON(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *cwd = fileManager.currentDirectoryPath ?: @".";
    NSString *tmp = NSTemporaryDirectory() ?: @"/tmp";
    NSDictionary *configuration = @{
        @"version": @1,
        @"defaultRoot": @"cwd",
        @"roots": @{
            @"cwd": @{
                @"path": [cwd stringByStandardizingPath]
            },
            @"tmp": @{
                @"path": [tmp stringByStandardizingPath]
            }
        },
        @"pathPolicy": @{
            @"allowAbsolutePath": @NO,
            @"allowParentTraversal": @NO,
            @"allowSymlinkEscape": @NO
        }
    };

    NSData *data = EJSCLIJSONData(configuration);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *EJSCLIKVConfigurationJSON(void) {
    NSString *tmp = NSTemporaryDirectory() ?: @"/tmp";
    NSString *defaultStore = [tmp stringByAppendingPathComponent:@"ejs_cli_kv_default"];
    NSDictionary *configuration = @{
        @"version": @1,
        @"defaultStore": @"default",
        @"stores": @{
            @"default": @{
                @"path": [defaultStore stringByStandardizingPath],
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @YES
            }
        },
        @"limits": @{
            @"maxKeyBytes": @(1024),
            @"maxValueBytes": @(1024 * 1024),
            @"maxKeysPerList": @(1000)
        }
    };
    NSData *data = EJSCLIJSONData(configuration);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *EJSCLISQLiteConfigurationJSON(void) {
    NSString *tmp = NSTemporaryDirectory() ?: @"/tmp";
    NSString *mainDB = [tmp stringByAppendingPathComponent:@"ejs_cli_sqlite_main.sqlite"];
    NSDictionary *configuration = @{
        @"version": @1,
        @"databases": @{
            @"main": @{
                @"path": [mainDB stringByStandardizingPath],
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @YES
            }
        },
        @"limits": @{
            @"maxRows": @(1000),
            @"maxStatementBytes": @(8192),
            @"maxBlobBytes": @(1024 * 1024),
            @"maxTextBytes": @(1024 * 1024),
            @"maxResponseBytes": @(10 * 1024 * 1024)
        }
    };
    NSData *data = EJSCLIJSONData(configuration);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

    static NSString *EJSCLINetConfigurationJSON(void) {
    NSDictionary *configuration = @{
        @"version": @1,
        @"capabilities": @{
            @"dns": @YES,
            @"tcpConnect": @YES,
            @"tcpListen": @YES,
            @"udp": @YES
        },
        @"outbound": @{
            @"denyPrivateNetworks": @NO,
            @"denyLinkLocal": @NO,
            @"default": @"allow"
        },
        @"inbound": @{
            @"default": @"allow"
        }
    };
    NSData *data = EJSCLIJSONData(configuration);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *EJSCLIWorkerConfigurationJSON(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *cwd = fileManager.currentDirectoryPath ?: @".";
    NSString *echoSource =
        @"onmessage = function(event) {"
         "  if (event.data && event.data.op === 'close') { close(); return; }"
         "  postMessage({ echo: event.data, selfIsGlobal: self === globalThis });"
         "};";
    NSDictionary *configuration = @{
        @"version": @1,
        @"defaultRoot": @"cwd",
        @"roots": @{
            @"cwd": @{
                @"path": [cwd stringByStandardizingPath],
                @"permissions": @[ @"read" ]
            }
        },
        @"inlineScripts": @{
            @"inline-echo": @{
                @"source": echoSource,
                @"type": @"classic"
            }
        },
        @"pathPolicy": @{
            @"allowAbsolutePath": @NO,
            @"allowParentTraversal": @NO,
            @"allowSymlinkEscape": @NO
        },
        @"limits": @{
            @"maxWorkers": @(4),
            @"maxQueuedMessages": @(64),
            @"maxMessageBytes": @(1024 * 1024),
            @"maxSourceBytes": @(1024 * 1024),
            @"startupTimeoutMs": @(5000),
            @"terminationTimeoutMs": @(2000)
        }
    };
    NSData *data = EJSCLIJSONData(configuration);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static void EJSCLIPrintNSString(NSString *string) {
    printf("%s\n", string.UTF8String ?: "");
}

static void EJSCLIPrintResult(NSString *rawResult) {
    NSData *data = EJSCLIDataFromString(rawResult);
    id json = data.length > 0u ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (json != nil && [NSJSONSerialization isValidJSONObject:json]) {
        NSData *prettyData = [NSJSONSerialization dataWithJSONObject:json
                                                             options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                               error:nil];
        NSString *pretty = prettyData != nil ? [[NSString alloc] initWithData:prettyData encoding:NSUTF8StringEncoding] : nil;
        if (pretty.length > 0u) {
            EJSCLIPrintNSString(pretty);
            return;
        }
    }
    EJSCLIPrintNSString(rawResult);
}

@implementation EJSCLICompletionProvider {
    BOOL _completed;
    BOOL _exitRequested;
    int _exitCode;
    NSString *_exitMessage;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.cli";
        _semaphore = dispatch_semaphore_create(0);
        _result = @"";
        _failed = NO;
        _completed = NO;
        _exitRequested = NO;
        _exitCode = EXIT_SUCCESS;
        _exitMessage = @"";
    }
    return self;
}

- (BOOL)exitRequested {
    @synchronized (self) {
        return _exitRequested;
    }
}

- (int)exitCode {
    @synchronized (self) {
        return _exitCode;
    }
}

- (NSString *)exitMessage {
    @synchronized (self) {
        return _exitMessage;
    }
}

- (void)completeWithResult:(NSString *)result failed:(BOOL)failed {
    BOOL shouldSignal = NO;
    @synchronized (self) {
        if (!_completed) {
            _completed = YES;
            self.result = result ?: @"";
            self.failed = failed;
            shouldSignal = YES;
        }
    }
    if (shouldSignal) {
        dispatch_semaphore_signal(self.semaphore);
    }
}

- (void)requestExitWithCode:(int)exitCode message:(NSString *)message {
    BOOL shouldSignal = NO;
    @synchronized (self) {
        if (!_completed) {
            _completed = YES;
            _exitRequested = YES;
            _exitCode = exitCode;
            _exitMessage = message ?: @"";
            shouldSignal = YES;
        }
    }
    if (shouldSignal) {
        dispatch_semaphore_signal(self.semaphore);
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)transferBuffer;
    (void)context;

    NSString *message = EJSCLIStringFromData(payload);
    if ([methodID isEqualToString:@"log"]) {
        printf("[js] %s\n", message.UTF8String ?: "");
        [responder finishWithData:nil error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"finish"] || [methodID isEqualToString:@"fail"]) {
        [self completeWithResult:message failed:[methodID isEqualToString:@"fail"]];
        [responder finishWithData:nil error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    [responder finishWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                   @"Unsupported ejs.cli method")];
    return [[EJSImmediateOperation alloc] init];
}

@end

@implementation EJSCLIProcessProvider {
    EJSCLICompletionProvider *_completionProvider;
    NSArray<NSString *> *_arguments;
}

- (instancetype)initWithCompletionProvider:(EJSCLICompletionProvider *)completionProvider
                                 arguments:(NSArray<NSString *> *)arguments {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.process";
        _completionProvider = completionProvider;
        _arguments = [arguments copy] ?: @[];
    }
    return self;
}

static int EJSCLIExitCodeFromPayload(NSData *payload) {
    NSDictionary *request = EJSCLIJSONObjectFromData(payload);
    id codeValue = request[@"code"];
    long long rawCode = [codeValue respondsToSelector:@selector(longLongValue)] ? [codeValue longLongValue] : 0;
    long long normalized = rawCode % 256;
    if (normalized < 0) {
        normalized += 256;
    }
    return (int)normalized;
}

static NSString *EJSCLIExitMessageFromPayload(NSData *payload) {
    NSDictionary *request = EJSCLIJSONObjectFromData(payload);
    id message = request[@"message"];
    return [message isKindOfClass:[NSString class]] ? message : @"";
}

static NSData *EJSCLIProcessWriteData(NSData *payload, NSData *transferBuffer) {
    return transferBuffer != nil ? transferBuffer : (payload ?: [NSData data]);
}

static NSData *EJSCLIProcessWriteResponse(NSData *data) {
    return EJSCLIJSONDictionaryData(@{
        @"ok": @YES,
        @"bytesWritten": @(data.length)
    });
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;

    if ([methodID isEqualToString:@"exit"]) {
        [_completionProvider requestExitWithCode:EJSCLIExitCodeFromPayload(payload)
                                         message:EJSCLIExitMessageFromPayload(payload)];
        [responder finishWithData:EJSCLIJSONDictionaryData(@{ @"ok": @YES }) error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"stdout.write"] || [methodID isEqualToString:@"stderr.write"]) {
        NSData *data = EJSCLIProcessWriteData(payload, transferBuffer);
        FILE *stream = [methodID isEqualToString:@"stderr.write"] ? stderr : stdout;
        if (data.length > 0u) {
            fwrite(data.bytes, 1u, data.length, stream);
        }
        fflush(stream);
        [responder finishWithData:EJSCLIProcessWriteResponse(data) error:nil];
        return [[EJSImmediateOperation alloc] init];
    }

    [responder finishWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                   @"Unsupported ejs.process async method")];
    return [[EJSImmediateOperation alloc] init];
}

- (NSData *)invokeSyncMethod:(NSString *)methodID
                     payload:(NSData *)payload
              transferBuffer:(NSData *)transferBuffer
                     context:(EJSContext *)context
                       error:(NSError **)error {
    (void)transferBuffer;
    (void)context;

    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if ([methodID isEqualToString:@"argv"]) {
        return EJSCLIJSONDictionaryData(@{ @"argv": _arguments });
    }

    if ([methodID isEqualToString:@"cwd"]) {
        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath] ?: @"";
        return EJSCLIJSONDictionaryData(@{ @"cwd": cwd });
    }

    if ([methodID isEqualToString:@"env"]) {
        NSDictionary *request = EJSCLIJSONObjectFromData(payload);
        id name = request[@"name"];
        NSDictionary<NSString *, NSString *> *environment = processInfo.environment ?: @{};
        if ([name isKindOfClass:[NSString class]]) {
            NSString *value = environment[name] ?: @"";
            return EJSCLIJSONDictionaryData(@{
                @"name": name,
                @"value": value,
                @"exists": @(environment[name] != nil)
            });
        }
        return EJSCLIJSONDictionaryData(@{ @"env": environment });
    }

    if ([methodID isEqualToString:@"pid"]) {
        return EJSCLIJSONDictionaryData(@{ @"pid": @(processInfo.processIdentifier) });
    }

    if (error != NULL) {
        *error = EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                      @"Unsupported ejs.process sync method");
    }
    return nil;
}

@end

static void EJSCLIPrintUsage(const char *toolName) {
    printf("Usage: %s [--timeout seconds] [-d|--daemon] <script.js> [args...]\n", toolName);
    printf("\n");
    printf("Runs a JavaScript file in the Apple EJS runtime with WinterTC defaults and CLI process helpers.\n");
    printf("Use process.exit(code), process.stdout.write(value), process.stderr.write(value), process.argv,\n");
    printf("process.cwd(), process.env(name), and process.pid from JavaScript.\n");
    printf("Use WinterTC globals such as fetch, crypto, URL, TextEncoder, setTimeout, and performance.\n");
    printf("Default fetch supports data:, http:, and https: URLs.\n");
    printf("Use EJS.* for installed modules: fs, system, fswatch, path, buffer, kv, storage, sqlite, hashing, uuid,\n");
    printf("net, ws, xhr, ipaddr, and worker.\n");
    printf("Use EJSFS.promises, EJS.fs, or fs for sandboxed file APIs.\n");
}

static NSString *EJSCLIWinterTCBootstrapSource(void) {
    return
        @"(function() {"
         "  const winterTC = globalThis.WinterTC;"
         "  if (!winterTC || typeof winterTC !== 'object') return;"
         "  if (!globalThis.EJS || typeof globalThis.EJS !== 'object') {"
         "    Object.defineProperty(globalThis, 'EJS', { configurable: true, writable: true, value: {} });"
         "  }"
         "  Object.defineProperty(globalThis.EJS, 'WinterTC', { configurable: true, enumerable: true, writable: true, value: winterTC });"
         "  Object.defineProperty(globalThis.EJS, 'winterTC', { configurable: true, enumerable: true, writable: true, value: winterTC });"
         "})();";
}

static NSString *EJSCLIProcessBootstrapSource(void) {
    return
        @"(function() {"
         "  const native = globalThis.__ejs_native__;"
         "  if (!native || typeof native.invoke !== 'function' || typeof native.invokeSync !== 'function') return;"
         "  function decode(buffer) { return new TextDecoder().decode(buffer || new ArrayBuffer(0)); }"
         "  function sync(method, payload) {"
         "    const raw = native.invokeSync('ejs.process', method, JSON.stringify(payload || {}), null);"
         "    const text = decode(raw);"
         "    return text ? JSON.parse(text) : {};"
         "  }"
         "  function invokeWrite(method, value) {"
         "    if (value instanceof ArrayBuffer) {"
         "      return native.invoke('ejs.process', method, '', new Uint8Array(value));"
         "    }"
         "    if (ArrayBuffer.isView(value) && value.buffer instanceof ArrayBuffer) {"
         "      return native.invoke('ejs.process', method, '', value);"
         "    }"
         "    return native.invoke('ejs.process', method, String(value), null);"
         "  }"
         "  const processObject = {"
         "    get argv() { return sync('argv').argv || []; },"
         "    get pid() { return sync('pid').pid || 0; },"
         "    cwd() { return sync('cwd').cwd || ''; },"
         "    env(name) {"
         "      if (name === undefined) return sync('env').env || {};"
         "      const result = sync('env', { name: String(name) });"
         "      return result.exists ? result.value : undefined;"
         "    },"
         "    exit(code, message) {"
         "      return native.invoke('ejs.process', 'exit', JSON.stringify({ code: code === undefined ? 0 : Number(code), message: message || '' }), null);"
         "    },"
         "    stdout: { write(value) { return invokeWrite('stdout.write', value); } },"
         "    stderr: { write(value) { return invokeWrite('stderr.write', value); } }"
         "  };"
         "  if (!globalThis.EJS || typeof globalThis.EJS !== 'object') {"
         "    Object.defineProperty(globalThis, 'EJS', { configurable: true, writable: true, value: {} });"
         "  }"
         "  Object.defineProperty(globalThis.EJS, 'process', { configurable: true, enumerable: true, writable: true, value: processObject });"
         "  if (globalThis.process === undefined) {"
         "    Object.defineProperty(globalThis, 'process', { configurable: true, enumerable: true, writable: true, value: processObject });"
         "  }"
         "})();";
}

static NSString *EJSCLIModulesBootstrapSource(void) {
    return
        @"(function() {"
         "  if (!globalThis.EJS || typeof globalThis.EJS !== 'object') {"
         "    Object.defineProperty(globalThis, 'EJS', { configurable: true, writable: true, value: {} });"
         "  }"
         "  const mappings = ["
         "    ['fs', 'EJSFS'],"
         "    ['system', 'EJSSystem'],"
         "    ['fswatch', 'EJSFSWatch'],"
         "    ['path', 'EJSPath'],"
         "    ['buffer', 'EJSBinary'],"
         "    ['binary', 'EJSBinary'],"
         "    ['kv', 'EJSKV'],"
         "    ['storage', 'EJSStorage'],"
         "    ['sqlite', 'EJSSQLite'],"
         "    ['hashing', 'EJSHashing'],"
         "    ['uuid', 'EJSUUID'],"
         "    ['net', 'EJSNet'],"
         "    ['ws', 'EJSWebSocket'],"
         "    ['xhr', 'EJSXHR'],"
         "    ['ipaddr', 'EJSIPAddr'],"
         "    ['worker', 'EJSWorker']"
         "  ];"
         "  for (const [name, globalName] of mappings) {"
         "    const value = globalThis[globalName];"
         "    if (value && typeof value === 'object') {"
         "      Object.defineProperty(globalThis.EJS, name, { configurable: true, enumerable: true, writable: true, value });"
         "    }"
         "  }"
         "  if (globalThis.EJSFS && globalThis.fs === undefined) {"
         "    Object.defineProperty(globalThis, 'fs', { configurable: true, enumerable: true, writable: true, value: globalThis.EJSFS });"
         "  }"
         "})();";
}

static NSString *EJSCLIWrappedUserScriptSource(NSString *source, BOOL daemonMode) {
    if (daemonMode) {
        return [NSString stringWithFormat:
            @"(async function() {\n"
             "%@\n"
             "})().catch(function(error) {\n"
             "  function formatError(error) {\n"
             "    const text = String(error);\n"
             "    const stack = error && error.stack ? String(error.stack) : '';\n"
             "    if (!stack || stack === text || stack.indexOf(text) === 0) return stack || text;\n"
             "    return text + '\\n' + stack;\n"
             "  }\n"
             "  return EJS.process.stderr.write(formatError(error) + '\\n');\n"
             "});",
            source ?: @""];
    }

    return [NSString stringWithFormat:
        @"(async function() {\n"
         "%@\n"
         "})().then(function() {\n"
         "  return EJS.process.exit(0);\n"
         "}, function(error) {\n"
         "  function formatError(error) {\n"
         "    const text = String(error);\n"
         "    const stack = error && error.stack ? String(error.stack) : '';\n"
         "    if (!stack || stack === text || stack.indexOf(text) === 0) return stack || text;\n"
         "    return text + '\\n' + stack;\n"
         "  }\n"
         "  const message = formatError(error);\n"
         "  return EJS.process.stderr.write(message + '\\n').then(function() {\n"
         "    return EJS.process.exit(1);\n"
         "  }, function() {\n"
         "    return EJS.process.exit(1);\n"
         "  });\n"
         "});",
        source ?: @""];
}

static BOOL EJSCLISecondsToDispatchDeltaNs(NSTimeInterval seconds, int64_t *deltaNanoseconds) {
    if (deltaNanoseconds == NULL) {
        return NO;
    }
    if (seconds <= 0.0 || !isfinite(seconds)) {
        return NO;
    }

    const long double maxSeconds =
        ((long double)INT64_MAX) / ((long double)NSEC_PER_SEC);
    if ((long double)seconds > maxSeconds) {
        return NO;
    }

    long double nsValue = (long double)seconds * (long double)NSEC_PER_SEC;
    if (nsValue > (long double)INT64_MAX) {
        return NO;
    }

    int64_t converted = (int64_t)nsValue;
    if (converted <= 0) {
        converted = 1;
    }
    *deltaNanoseconds = converted;
    return YES;
}

static BOOL EJSCLIParseTimeout(NSString *text, NSTimeInterval *timeout) {
    if (text.length == 0u || timeout == NULL) {
        return NO;
    }

    double value = text.doubleValue;
    int64_t ignoredDelta = 0;
    if (value <= 0.0 || !isfinite(value) ||
        !EJSCLISecondsToDispatchDeltaNs((NSTimeInterval)value, &ignoredDelta)) {
        return NO;
    }

    *timeout = (NSTimeInterval)value;
    return YES;
}

static BOOL EJSCLIShouldInjectFailure(EJSCLIRunOptions *options, NSString *point, NSError **error) {
#ifdef EJS_TEST
    if (options.testFailurePoint.length > 0u && [options.testFailurePoint isEqualToString:point]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"EJSCLITestFailureDomain"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"injected CLI failure: %@", point ?: @"unknown"] }];
        }
        return YES;
    }
#else
    (void)options;
    (void)point;
    (void)error;
#endif
    return NO;
}

int EJSCLIRunMain(int argc, const char *argv[], EJSCLIRunOptions *options) {
    @autoreleasepool {
        NSString *toolName = argc > 0 && argv[0] != NULL ? [[NSString alloc] initWithUTF8String:argv[0]] : @"ejs_apple_cli";
        NSString *scriptPath = nil;
        NSTimeInterval timeoutSeconds = options.timeoutSeconds;
        BOOL daemonMode = options.daemonMode;
        NSMutableArray<NSString *> *scriptArguments = [NSMutableArray array];

        for (int index = 1; index < argc; ++index) {
            NSString *argument = argv[index] != NULL ? ([[NSString alloc] initWithUTF8String:argv[index]] ?: @"") : @"";
            if (scriptPath == nil) {
                if ([argument isEqualToString:@"-h"] || [argument isEqualToString:@"--help"]) {
                    EJSCLIPrintUsage(toolName.lastPathComponent.UTF8String);
                    return EXIT_SUCCESS;
                }
                if ([argument isEqualToString:@"--timeout"]) {
                    if (index + 1 >= argc) {
                        fprintf(stderr, "--timeout requires a value\n");
                        return EXIT_FAILURE;
                    }
                    NSString *timeoutText = [[NSString alloc] initWithUTF8String:argv[++index]];
                    if (!EJSCLIParseTimeout(timeoutText, &timeoutSeconds)) {
                        fprintf(stderr, "invalid --timeout value: %s\n", timeoutText.UTF8String);
                        return EXIT_FAILURE;
                    }
                    continue;
                }
                if ([argument hasPrefix:@"--timeout="]) {
                    NSString *timeoutText = [argument substringFromIndex:[@"--timeout=" length]];
                    if (!EJSCLIParseTimeout(timeoutText, &timeoutSeconds)) {
                        fprintf(stderr, "invalid --timeout value: %s\n", timeoutText.UTF8String);
                        return EXIT_FAILURE;
                    }
                    continue;
                }
                if ([argument isEqualToString:@"-d"] || [argument isEqualToString:@"--daemon"]) {
                    daemonMode = YES;
                    continue;
                }
                if ([argument isEqualToString:@"--"]) {
                    if (index + 1 >= argc) {
                        fprintf(stderr, "missing script path\n");
                        return EXIT_FAILURE;
                    }
                    scriptPath = [[NSString alloc] initWithUTF8String:argv[++index]];
                    continue;
                }
                if ([argument hasPrefix:@"-"]) {
                    fprintf(stderr, "unknown option: %s\n", argument.UTF8String);
                    EJSCLIPrintUsage(toolName.lastPathComponent.UTF8String);
                    return EXIT_FAILURE;
                }
                scriptPath = argument;
            } else {
                [scriptArguments addObject:argument];
            }
        }

        if (scriptPath.length == 0u) {
            fprintf(stderr, "missing script path\n");
            EJSCLIPrintUsage(toolName.lastPathComponent.UTF8String);
            return EXIT_FAILURE;
        }

        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:scriptPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:&error];
        if (source == nil) {
            fprintf(stderr, "failed to read script %s: %s\n",
                    scriptPath.UTF8String,
                    error.localizedDescription.UTF8String);
            return EXIT_FAILURE;
        }

        EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
        configuration.runtimeName = options.runtimeName;
        configuration.runtimeVersion = @"1.0.0";
        configuration.memoryLimitBytes = 64u * 1024u * 1024u;
        configuration.maxStackSize = 512u * 1024u;
        configuration.contextDefaults = @{
            EJSFileSystemConfigurationKey: EJSCLIFSConfigurationJSON(),
            EJSFSWatchConfigurationKey: EJSCLIFSWATCHConfigurationJSON(),
            EJSKeyValueStoreConfigurationKey: EJSCLIKVConfigurationJSON(),
            EJSSQLiteConfigurationKey: EJSCLISQLiteConfigurationJSON(),
            EJSNetworkConfigurationKey: EJSCLINetConfigurationJSON(),
            EJSWorkerConfigurationKey: EJSCLIWorkerConfigurationJSON()
        };

        EJSRuntime *runtime = EJSCLIShouldInjectFailure(options, @"runtime", &error)
            ? nil
            : [[EJSRuntime alloc] initWithConfiguration:configuration];
        if (runtime == nil) {
            fprintf(stderr, "failed to create Apple EJSRuntime\n");
            return EXIT_FAILURE;
        }

        EJSContext *context = EJSCLIShouldInjectFailure(options, @"context", &error)
            ? nil
            : [runtime createContextWithID:options.contextID error:&error];
        if (context == nil) {
            fprintf(stderr, "failed to create Apple EJSContext: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        EJSCLICompletionProvider *completionProvider = [[EJSCLICompletionProvider alloc] init];
        if (EJSCLIShouldInjectFailure(options, @"register-cli", &error) ||
            ![context registerProvider:completionProvider error:&error]) {
            fprintf(stderr, "failed to register ejs.cli provider: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:scriptArguments.count + 2u];
        [arguments addObject:toolName ?: @"ejs_apple_cli"];
        [arguments addObject:scriptPath];
        [arguments addObjectsFromArray:scriptArguments];

        EJSCLIProcessProvider *processProvider = [[EJSCLIProcessProvider alloc] initWithCompletionProvider:completionProvider
                                                                                                 arguments:arguments];
        if (EJSCLIShouldInjectFailure(options, @"register-process", &error) ||
            ![context registerProvider:processProvider error:&error]) {
            fprintf(stderr, "failed to register ejs.process provider: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        EJSWinterTCInstallOptions *installOptions = [[EJSWinterTCInstallOptions alloc] init];
        installOptions.installDefaultProviders = YES;
        if (EJSCLIShouldInjectFailure(options, @"wintertc", &error) ||
            !EJSWinterTCInstallIntoContextWithOptions(context, installOptions, &error)) {
            fprintf(stderr, "failed to install WinterTC: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"cli-wintertc", &error) ||
            ![context evaluateScript:EJSCLIWinterTCBootstrapSource()
                            filename:@"ejs_cli_wintertc_bootstrap.js"
                               error:&error]) {
            fprintf(stderr, "failed to install CLI WinterTC helpers: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"fs", &error) ||
            !EJSFileSystemInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSFS: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"system", &error) ||
            !EJSSystemInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSSystem: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"ipaddr", &error) ||
            !EJSIPAddrInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSIPAddr: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"fswatch", &error) ||
            !EJSFSWatchInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSFSWatch: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"path", &error) ||
            !EJSPathInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSPath: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"buffer", &error) ||
            !EJSBufferInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSBuffer: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"kv", &error) ||
            !EJSKeyValueStoreInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSKV: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"sqlite", &error) ||
            !EJSSQLiteInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSSQLite: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"hashing", &error) ||
            !EJSHashingInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSHashing: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"uuid", &error) ||
            !EJSUUIDInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSUUID: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"worker", &error) ||
            !EJSWorkerInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSWorker: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"ws", &error) ||
            !EJSWebSocketInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSWebSocket: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"xhr", &error) ||
            !EJSXHRInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSXHR: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"net", &error) ||
            !EJSNetInstallIntoContext(context, &error)) {
            fprintf(stderr, "failed to install EJSNet: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"process-bootstrap", &error) ||
            ![context evaluateScript:EJSCLIProcessBootstrapSource()
                            filename:@"ejs_cli_process_bootstrap.js"
                               error:&error]) {
            fprintf(stderr, "failed to install CLI process helpers: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (EJSCLIShouldInjectFailure(options, @"modules-bootstrap", &error) ||
            ![context evaluateScript:EJSCLIModulesBootstrapSource()
                            filename:@"ejs_cli_modules_bootstrap.js"
                               error:&error]) {
            fprintf(stderr, "failed to install CLI module helpers: %s\n", error.localizedDescription.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        options.daemonMode = daemonMode;
        NSString *filename = scriptPath.lastPathComponent.length > 0u ? scriptPath.lastPathComponent : @"ejs_cli_script.js";
        NSString *wrappedSource = EJSCLIWrappedUserScriptSource(source, options.daemonMode);
        if (![context evaluateScript:wrappedSource filename:filename error:&error]) {
            NSString *errorDetails = error.userInfo[@"stack"] ?: error.localizedDescription;
            fprintf(stderr, "failed to evaluate %s: %s\n",
                    scriptPath.UTF8String,
                    error.localizedDescription.UTF8String);
            if (errorDetails != error.localizedDescription && errorDetails.length > 0u) {
                fprintf(stderr, "error details:\n%s\n", errorDetails.UTF8String);
            }
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        int64_t timeoutDeltaNs = 0;
        if (!options.daemonMode && !EJSCLISecondsToDispatchDeltaNs(timeoutSeconds, &timeoutDeltaNs)) {
            fprintf(stderr, "invalid --timeout value after normalization: %.17g\n", timeoutSeconds);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        dispatch_time_t deadline = options.daemonMode
            ? DISPATCH_TIME_FOREVER
            : dispatch_time(DISPATCH_TIME_NOW, timeoutDeltaNs);
        long waitResult = dispatch_semaphore_wait(completionProvider.semaphore, deadline);
        if (!options.daemonMode && waitResult != 0) {
            fprintf(stderr, "timed out waiting for script completion from %s\n", scriptPath.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        if (completionProvider.exitRequested) {
            NSString *exitMessage = completionProvider.exitMessage;
            if (exitMessage.length > 0u) {
                FILE *stream = completionProvider.exitCode == EXIT_SUCCESS ? stdout : stderr;
                fprintf(stream, "%s\n", exitMessage.UTF8String);
                fflush(stream);
            }
            [runtime invalidate];
            return completionProvider.exitCode;
        }

        if (completionProvider.failed) {
            fprintf(stderr, "JavaScript job failed:\n%s\n", completionProvider.result.UTF8String);
            [runtime invalidate];
            return EXIT_FAILURE;
        }

        EJSCLIPrintResult(completionProvider.result);
        [runtime invalidate];
        return EXIT_SUCCESS;
    }
}
