#import <Foundation/Foundation.h>

#import "../../platform/apple/include/EJSApplePlatform.h"
#import "../../platform/apple/src/EJSAppleInstallTransactionInternal.h"
#import "../../tools/apple/EJSAppleCLISupport.h"

@interface EJSCLITestProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithModuleID:(NSString *)moduleID;
@end

@implementation EJSCLITestProvider

- (instancetype)initWithModuleID:(NSString *)moduleID {
  self = [super init];
  if (self != nil) {
    _moduleID = [moduleID copy] ?: @"";
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
  [responder finishWithData:nil
                      error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                 @"test provider does not implement async methods")];
  return [[EJSImmediateOperation alloc] init];
}

@end

static NSString *EJSCLITestMakePath(NSString *prefix, NSString *extension) {
  NSString *filename = [NSString stringWithFormat:@"%@-%@.%@",
                                                  prefix,
                                                  NSUUID.UUID.UUIDString,
                                                  extension];
  return [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
}

static NSString *EJSCLITestWriteScript(NSString *source, NSMutableArray<NSString *> *temporaryPaths) {
  NSString *path = EJSCLITestMakePath(@"ejs-cli-test", @"js");
  NSError *error = nil;
  if (![source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
    fprintf(stderr, "failed to write CLI test script: %s\n", error.localizedDescription.UTF8String);
    return nil;
  }
  [temporaryPaths addObject:path];
  return path;
}

static int EJSCLITestRun(NSArray<NSString *> *arguments, EJSCLIRunOptions *options) {
  NSUInteger count = arguments.count;
  const char **argv = calloc(count > 0u ? count : 1u, sizeof(char *));
  if (argv == NULL) {
    return EXIT_FAILURE;
  }

  for (NSUInteger index = 0; index < count; ++index) {
    argv[index] = arguments[index].UTF8String;
  }

  int result = EJSCLIRunMain((int)count, argv, options);
  free(argv);
  return result;
}

static BOOL EJSCLITestExpectCode(const char *name, int actual, int expected) {
  if (actual != expected) {
    fprintf(stderr, "%s should return %d, got %d\n", name, expected, actual);
    return NO;
  }
  return YES;
}

static BOOL EJSCLITestExpectFailure(const char *name, int actual) {
  if (actual == EXIT_SUCCESS) {
    fprintf(stderr, "%s should fail\n", name);
    return NO;
  }
  return YES;
}

static BOOL EJSCLITestEvaluate(EJSContext *context, NSString *source) {
  NSError *error = nil;
  if (![context evaluateScript:source filename:@"ejs_cli_transaction_test.js" error:&error]) {
    fprintf(stderr, "transaction helper script failed: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

static EJSContext *EJSCLITestCreateContext(EJSRuntime **runtimeOut) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  configuration.runtimeName = @"ejs_apple_cli_test";
  EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];

  NSError *error = nil;
  EJSContext *context = [runtime createContextWithID:NSUUID.UUID.UUIDString error:&error];
  if (context == nil) {
    fprintf(stderr, "failed to create transaction helper context: %s\n", error.localizedDescription.UTF8String);
    [runtime invalidate];
    return nil;
  }

  if (runtimeOut != NULL) {
    *runtimeOut = runtime;
  }
  return context;
}

static BOOL EJSCLITestRunCLIArgumentBranches(NSMutableArray<NSString *> *temporaryPaths) {
  EJSCLIRunOptions *options = [[EJSCLIRunOptions alloc] init];
  NSString *featureScript = EJSCLITestWriteScript(
      @"const native = globalThis.__ejs_native__;\n"
       "if (!native || typeof native.invoke !== 'function') throw new Error('missing native bridge');\n"
       "await native.invoke('ejs.cli', 'log', '', null);\n"
       "await native.invoke('ejs.cli', 'log', 'hello from cli test', null);\n"
       "let rejected = false;\n"
       "try { await native.invoke('ejs.cli', 'unknown', '', null); } catch (error) { rejected = true; }\n"
       "if (!rejected) throw new Error('unsupported ejs.cli method should reject');\n"
       "rejected = false;\n"
       "try { await native.invoke('ejs.process', 'unknown', '', null); } catch (error) { rejected = true; }\n"
       "if (!rejected) throw new Error('unsupported ejs.process async method should reject');\n"
       "rejected = false;\n"
       "try { native.invokeSync('ejs.process', 'unknown', '{}', null); } catch (error) { rejected = true; }\n"
       "if (!rejected) throw new Error('unsupported ejs.process sync method should reject');\n"
       "if (process.argv[2] !== 'alpha' || process.argv[3] !== '--beta') throw new Error('argv mismatch');\n"
       "if (typeof process.cwd() !== 'string' || process.cwd().length === 0) throw new Error('cwd mismatch');\n"
       "if (!process.env() || typeof process.env() !== 'object') throw new Error('env object mismatch');\n"
       "if (process.env('__EJS_CLI_TEST_MISSING_ENV__') !== undefined) throw new Error('missing env mismatch');\n"
       "if (typeof process.pid !== 'number' || process.pid <= 0) throw new Error('pid mismatch');\n"
       "await process.stdout.write('');\n"
       "await process.stdout.write(new Uint8Array([79, 75]));\n"
       "await process.stderr.write('stderr branch');\n"
       "await process.stdout.write(new ArrayBuffer(0));\n"
       "await native.invoke('ejs.cli', 'finish', JSON.stringify({ ok: true, argv: process.argv.slice(2) }), null);\n",
      temporaryPaths);
  if (featureScript == nil) {
    return NO;
  }

  if (!EJSCLITestExpectCode("feature script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout", @"2", featureScript, @"alpha", @"--beta" ],
                                          options),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *plainFinishScript = EJSCLITestWriteScript(
      @"await __ejs_native__.invoke('ejs.cli', 'finish', 'plain result', null);\n",
      temporaryPaths);
  if (plainFinishScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("plain finish script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", plainFinishScript ], options),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *failScript = EJSCLITestWriteScript(
      @"await __ejs_native__.invoke('ejs.cli', 'fail', 'expected failure', null);\n",
      temporaryPaths);
  if (failScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("ejs.cli fail script",
                               EJSCLITestRun(@[ @"ejs_apple_cli", failScript ], options))) {
    return NO;
  }

  NSString *throwScript = EJSCLITestWriteScript(@"throw new Error('expected throw');\n", temporaryPaths);
  if (throwScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("throwing script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", throwScript ], options),
                            1)) {
    return NO;
  }

  NSString *negativeExitScript = EJSCLITestWriteScript(
      @"await process.exit(-2, 'negative exit branch');\n",
      temporaryPaths);
  if (negativeExitScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("negative process.exit script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", negativeExitScript ], options),
                            254)) {
    return NO;
  }

  NSString *successMessageScript = EJSCLITestWriteScript(
      @"await process.exit(0, 'success exit branch');\n",
      temporaryPaths);
  if (successMessageScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("success message process.exit script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", successMessageScript ], options),
                            EXIT_SUCCESS)) {
    return NO;
  }
  if (!EJSCLITestExpectCode("timeout equals success script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout=2", successMessageScript ], options),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *emptyFinishScript = EJSCLITestWriteScript(
      @"await __ejs_native__.invoke('ejs.cli', 'finish', '', null);\n",
      temporaryPaths);
  if (emptyFinishScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("empty finish script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", emptyFinishScript ], options),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *emptyProcessExitScript = EJSCLITestWriteScript(
      @"await __ejs_native__.invoke('ejs.process', 'exit', '', null);\n",
      temporaryPaths);
  if (emptyProcessExitScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("empty process exit payload script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", emptyProcessExitScript ], options),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *timeoutScript = EJSCLITestWriteScript(@"await new Promise(() => {});\n", temporaryPaths);
  if (timeoutScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("timed out script",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout=0.001", timeoutScript ], options))) {
    return NO;
  }

  EJSCLIRunOptions *zeroTimeoutOptions = [[EJSCLIRunOptions alloc] init];
  zeroTimeoutOptions.timeoutSeconds = 0.0;
  if (!EJSCLITestExpectFailure("zero run option timeout",
                               EJSCLITestRun(@[ @"ejs_apple_cli", successMessageScript ], zeroTimeoutOptions))) {
    return NO;
  }

  NSString *syntaxErrorScript = EJSCLITestWriteScript(@"function () {\n", temporaryPaths);
  if (syntaxErrorScript == nil) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("syntax error script",
                               EJSCLITestRun(@[ @"ejs_apple_cli", syntaxErrorScript ], options))) {
    return NO;
  }

  if (!EJSCLITestExpectCode("help option",
                            EJSCLITestRun(@[ @"ejs_apple_cli", @"--help" ], options),
                            EXIT_SUCCESS)) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("missing script",
                               EJSCLITestRun(@[ @"ejs_apple_cli" ], options))) {
    return NO;
  }
  const char *emptyArgv[] = { NULL };
  if (!EJSCLITestExpectFailure("missing script with argc zero", EJSCLIRunMain(0, emptyArgv, options))) {
    return NO;
  }

  const char *nullArgumentArgv[] = { "ejs_apple_cli", NULL };
  if (!EJSCLITestExpectFailure("null argument script path",
                               EJSCLIRunMain(2, nullArgumentArgv, options))) {
    return NO;
  }

  if (!EJSCLITestExpectFailure("timeout missing value",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout" ], options))) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("timeout separate invalid value",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout", @"0", featureScript ], options))) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("timeout empty value",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout=", featureScript ], options))) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("timeout infinite value",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout=1e309", featureScript ], options))) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("timeout overflow value",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--timeout=10000000000000000000", featureScript ],
                                             options))) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("separator without script",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--" ], options))) {
    return NO;
  }
  if (!EJSCLITestExpectCode("separator with script",
                            EJSCLITestRun(@[ @"ejs_apple_cli", @"--", successMessageScript, @"after-separator" ],
                                          options),
                            EXIT_SUCCESS)) {
    return NO;
  }
  if (!EJSCLITestExpectFailure("unknown option",
                               EJSCLITestRun(@[ @"ejs_apple_cli", @"--unknown-option", featureScript ], options))) {
    return NO;
  }

  NSString *missingScript = EJSCLITestMakePath(@"ejs-cli-missing", @"js");
  if (!EJSCLITestExpectFailure("missing script file",
                               EJSCLITestRun(@[ @"ejs_apple_cli", missingScript ], options))) {
    return NO;
  }

  return YES;
}

static NSString *EJSCLITestCurrentExecutablePath(void) {
  NSString *executablePath = NSProcessInfo.processInfo.arguments.firstObject ?: @"";
  if (executablePath.length == 0u) {
    return @"";
  }
  if (!executablePath.isAbsolutePath) {
    executablePath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:executablePath];
  }
  return executablePath.stringByStandardizingPath;
}

static NSString *EJSCLITestFindSiblingCLI(void) {
  NSString *executablePath = EJSCLITestCurrentExecutablePath();
  if (executablePath.length == 0u) {
    return nil;
  }

  NSString *directory = executablePath.stringByDeletingLastPathComponent;
  NSArray<NSString *> *candidates = @[
    [[directory stringByAppendingPathComponent:@"../tools/apple/ejs_apple_cli"] stringByStandardizingPath],
    [[directory stringByAppendingPathComponent:@"../tools/apple/Debug/ejs_apple_cli"] stringByStandardizingPath],
    [[directory stringByAppendingPathComponent:@"../../tools/apple/Debug/ejs_apple_cli"] stringByStandardizingPath],
    [[directory stringByAppendingPathComponent:@"../tools/apple/Release/ejs_apple_cli"] stringByStandardizingPath],
    [[directory stringByAppendingPathComponent:@"../../tools/apple/Release/ejs_apple_cli"] stringByStandardizingPath]
  ];

  NSFileManager *fileManager = [NSFileManager defaultManager];
  for (NSString *candidate in candidates) {
    if ([fileManager isExecutableFileAtPath:candidate]) {
      return candidate;
    }
  }
  return nil;
}

static int EJSCLITestRunTaskWithOutput(NSString *launchPath,
                                       NSArray<NSString *> *arguments,
                                       NSString **stdoutOut,
                                       NSString **stderrOut) {
  NSTask *task = [[NSTask alloc] init];
  NSPipe *stdoutPipe = [NSPipe pipe];
  NSPipe *stderrPipe = [NSPipe pipe];
  task.executableURL = [NSURL fileURLWithPath:launchPath];
  task.arguments = arguments;
  task.standardOutput = stdoutPipe;
  task.standardError = stderrPipe;

  NSError *error = nil;
  if (![task launchAndReturnError:&error]) {
    fprintf(stderr, "failed to launch sibling CLI: %s\n", error.localizedDescription.UTF8String);
    return EXIT_FAILURE;
  }
  [task waitUntilExit];
  NSData *stdoutData = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
  NSData *stderrData = [stderrPipe.fileHandleForReading readDataToEndOfFile];
  if (stdoutOut != NULL) {
    *stdoutOut = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
  }
  if (stderrOut != NULL) {
    *stderrOut = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
  }
  return task.terminationStatus;
}

static int EJSCLITestRunTask(NSString *launchPath, NSArray<NSString *> *arguments) {
  return EJSCLITestRunTaskWithOutput(launchPath, arguments, NULL, NULL);
}

static BOOL EJSCLITestRunSiblingCLIMainIfAvailable(NSMutableArray<NSString *> *temporaryPaths) {
  NSString *cliPath = EJSCLITestFindSiblingCLI();
  if (cliPath.length == 0u) {
    return YES;
  }

  if (!EJSCLITestExpectCode("sibling CLI --help",
                            EJSCLITestRunTask(cliPath, @[ @"--help" ]),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *scriptPath = EJSCLITestWriteScript(@"await process.exit(0, 'sibling cli run');\n", temporaryPaths);
  if (scriptPath == nil) {
    return NO;
  }
  if (!EJSCLITestExpectCode("sibling CLI script",
                            EJSCLITestRunTask(cliPath, @[ @"--timeout=2", scriptPath ]),
                            EXIT_SUCCESS)) {
    return NO;
  }

  NSString *referenceErrorScript = EJSCLITestWriteScript(@"JSON.stringify({ headers });\n", temporaryPaths);
  if (referenceErrorScript == nil) {
    return NO;
  }
  NSString *stderrText = nil;
  int status = EJSCLITestRunTaskWithOutput(cliPath, @[ @"--timeout=2", referenceErrorScript ], NULL, &stderrText);
  if (!EJSCLITestExpectFailure("sibling CLI reference error script", status)) {
    return NO;
  }
  if ([stderrText rangeOfString:@"ReferenceError"].location == NSNotFound ||
      [stderrText rangeOfString:@"headers"].location == NSNotFound) {
    fprintf(stderr, "sibling CLI reference error output should include error message, got: %s\n",
            stderrText.UTF8String);
    return NO;
  }

  return YES;
}

#ifdef EJS_TEST
static BOOL EJSCLITestRunInjectedCLIFailureBranches(NSMutableArray<NSString *> *temporaryPaths) {
  NSString *scriptPath = EJSCLITestWriteScript(@"await process.exit(0, 'injected failure script');\n", temporaryPaths);
  if (scriptPath == nil) {
    return NO;
  }

  NSArray<NSString *> *failurePoints = @[
    @"runtime",
    @"context",
    @"register-cli",
    @"register-process",
    @"wintertc",
    @"cli-wintertc",
    @"fs",
    @"system",
    @"fswatch",
    @"path",
    @"buffer",
    @"kv",
    @"sqlite",
    @"hashing",
    @"uuid",
    @"worker",
    @"process-bootstrap",
    @"modules-bootstrap"
  ];

  for (NSString *failurePoint in failurePoints) {
    EJSCLIRunOptions *options = [[EJSCLIRunOptions alloc] init];
    options.timeoutSeconds = 2.0;
    options.testFailurePoint = failurePoint;
    NSString *name = [NSString stringWithFormat:@"injected CLI failure %@", failurePoint];
    if (!EJSCLITestExpectFailure(name.UTF8String,
                                 EJSCLITestRun(@[ @"ejs_apple_cli", scriptPath ], options))) {
      return NO;
    }
  }

  return YES;
}
#endif

static BOOL EJSCLITestRunTransactionInvalidBranches(void) {
  NSError *error = nil;
  if (EJSAppleInstallTransactionBegin(NULL, nil, nil, &error) || error == nil) {
    fprintf(stderr, "transaction begin should reject missing context\n");
    return NO;
  }

  error = nil;
  if (EJSAppleInstallTransactionEvaluateRollbackScript(NULL, @"rollback", &error) || error == nil) {
    fprintf(stderr, "transaction rollback script should reject missing transaction\n");
    return NO;
  }

  error = nil;
  if (EJSAppleInstallTransactionRegisterProvider(NULL, nil, &error) || error == nil) {
    fprintf(stderr, "transaction provider registration should reject invalid arguments\n");
    return NO;
  }

  if (!EJSAppleInstallTransactionRollback(NULL, &error)) {
    fprintf(stderr, "transaction rollback should accept NULL transaction\n");
    return NO;
  }

  EJSAppleInstallTransaction inactive = {0};
  if (!EJSAppleInstallTransactionRollback(&inactive, &error)) {
    fprintf(stderr, "inactive transaction rollback should succeed\n");
    return NO;
  }

  if (!EJSAppleInstallTransactionCommit(NULL, &error) ||
      !EJSAppleInstallTransactionCommit(&inactive, &error)) {
    fprintf(stderr, "inactive transaction commit should succeed\n");
    return NO;
  }

  error = nil;
  EJSAppleInstallTransactionRollbackPreservingError(&inactive, &error);
  if (error != nil) {
    fprintf(stderr, "rollback preserving error should leave successful rollback error empty\n");
    return NO;
  }

  NSError *emptyMessageError = EJSAppleInstallTransactionError(nil);
  if (emptyMessageError.userInfo.count != 0u) {
    fprintf(stderr, "empty transaction error should not attach userInfo\n");
    return NO;
  }

  return YES;
}

static BOOL EJSCLITestRunTransactionSuccessBranches(void) {
  EJSRuntime *runtime = nil;
  EJSContext *context = EJSCLITestCreateContext(&runtime);
  if (context == nil) {
    return NO;
  }

  BOOL ok = NO;
  NSError *error = nil;
  EJSAppleInstallTransaction transaction = {0};
  EJSCLITestProvider *provider = nil;

  if (!EJSCLITestEvaluate(context,
                          @"Object.defineProperty(globalThis, 'EJSTxnExisting', { value: 7, configurable: true, writable: true });"
                           "delete globalThis.EJSTxnMissing;")) {
    goto cleanup;
  }

  if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSTxnExisting", @"EJSTxnMissing" ], &error)) {
    fprintf(stderr, "transaction begin should succeed: %s\n", error.localizedDescription.UTF8String);
    goto cleanup;
  }

  provider = [[EJSCLITestProvider alloc] initWithModuleID:@"ejs.test.transaction"];
  if (!EJSAppleInstallTransactionRegisterProvider(&transaction, provider, &error)) {
    fprintf(stderr, "transaction provider registration should succeed: %s\n", error.localizedDescription.UTF8String);
    goto cleanup;
  }

  if (!EJSCLITestEvaluate(context,
                          @"globalThis.EJSTxnExisting = 99;"
                           "globalThis.EJSTxnMissing = 42;")) {
    goto cleanup;
  }

  if (!EJSAppleInstallTransactionRollback(&transaction, &error)) {
    fprintf(stderr, "transaction rollback should succeed: %s\n", error.localizedDescription.UTF8String);
    goto cleanup;
  }

  if (!EJSCLITestEvaluate(context,
                          @"if (globalThis.EJSTxnExisting !== 7) throw new Error('existing global was not restored');"
                           "if (Object.prototype.hasOwnProperty.call(globalThis, 'EJSTxnMissing')) {"
                           "  throw new Error('new global was not removed');"
                           "}")) {
    goto cleanup;
  }

  if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSTxnCommit" ], &error)) {
    fprintf(stderr, "transaction begin before commit should succeed: %s\n", error.localizedDescription.UTF8String);
    goto cleanup;
  }

  if (!EJSCLITestEvaluate(context, @"globalThis.EJSTxnCommit = 1;")) {
    goto cleanup;
  }
  if (!EJSAppleInstallTransactionCommit(&transaction, &error)) {
    fprintf(stderr, "transaction commit should succeed: %s\n", error.localizedDescription.UTF8String);
    goto cleanup;
  }
  if (!EJSAppleInstallTransactionRollback(&transaction, &error)) {
    fprintf(stderr, "rollback after commit should be inactive and succeed\n");
    goto cleanup;
  }

  ok = YES;

cleanup:
  [runtime invalidate];
  return ok;
}

static BOOL EJSCLITestRunTransactionRollbackFailureBranches(void) {
  EJSAppleInstallTransaction nullErrorTransaction = {0};
  nullErrorTransaction.active = YES;
  nullErrorTransaction.snapshotKey = @"missing-context-snapshot";
  nullErrorTransaction.registeredProviderModuleIDs = [NSMutableArray array];
  EJSAppleInstallTransactionRollbackPreservingError(&nullErrorTransaction, NULL);

  EJSAppleInstallTransaction nilPrimaryTransaction = {0};
  nilPrimaryTransaction.active = YES;
  nilPrimaryTransaction.snapshotKey = @"missing-context-snapshot";
  nilPrimaryTransaction.registeredProviderModuleIDs = [NSMutableArray array];
  NSError *error = nil;
  EJSAppleInstallTransactionRollbackPreservingError(&nilPrimaryTransaction, &error);
  if (error == nil) {
    fprintf(stderr, "rollback preserving error should surface rollback error without primary error\n");
    return NO;
  }

  EJSAppleInstallTransaction primaryTransaction = {0};
  primaryTransaction.active = YES;
  primaryTransaction.snapshotKey = @"missing-context-snapshot";
  primaryTransaction.registeredProviderModuleIDs = [NSMutableArray array];
  NSError *primaryError = [NSError errorWithDomain:@"EJSCLITestDomain"
                                              code:17
                                          userInfo:@{ NSLocalizedDescriptionKey: @"primary" }];
  error = primaryError;
  EJSAppleInstallTransactionRollbackPreservingError(&primaryTransaction, &error);
  if (error == nil ||
      ![error.domain isEqualToString:primaryError.domain] ||
      error.code != primaryError.code ||
      error.userInfo[NSUnderlyingErrorKey] == nil) {
    fprintf(stderr, "rollback preserving error should attach rollback error to primary error\n");
    return NO;
  }

  return YES;
}

int main(void) {
  @autoreleasepool {
    NSMutableArray<NSString *> *temporaryPaths = [NSMutableArray array];
    BOOL ok = EJSCLITestRunCLIArgumentBranches(temporaryPaths);
    ok = ok && EJSCLITestRunSiblingCLIMainIfAvailable(temporaryPaths);
#ifdef EJS_TEST
    ok = ok && EJSCLITestRunInjectedCLIFailureBranches(temporaryPaths);
#endif
    ok = ok && EJSCLITestRunTransactionInvalidBranches();
    ok = ok && EJSCLITestRunTransactionSuccessBranches();
    ok = ok && EJSCLITestRunTransactionRollbackFailureBranches();

    for (NSString *path in temporaryPaths) {
      [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }

    if (!ok) {
      return EXIT_FAILURE;
    }
    printf("ejs_apple_cli_test PASS\n");
    return EXIT_SUCCESS;
  }
}
