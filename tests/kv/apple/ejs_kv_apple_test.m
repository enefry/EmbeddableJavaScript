#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSKeyValueStoreApple.h"

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
  self.semaphore = dispatch_semaphore_create(0);
  self.lastMessage = @"";
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
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
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

static NSString * kv_json(NSString *defaultPath,
                          NSString *namedPath,
                          NSUInteger maxKeyBytes,
                          NSUInteger maxValueBytes,
                          NSUInteger maxKeysPerList) {
  NSDictionary *config = @{
    @"version": @1,
    @"defaultStore": @"default",
    @"stores": @{
      @"default": @{
        @"path": defaultPath,
        @"permissions": @[ @"read", @"write" ],
        @"createIfMissing": @YES
      },
      @"named": @{
        @"path": namedPath,
        @"permissions": @[ @"read", @"write" ],
        @"createIfMissing": @YES
      },
      @"readonly": @{
        @"path": namedPath,
        @"permissions": @[ @"read" ],
        @"createIfMissing": @YES
      }
    },
    @"limits": @{
      @"maxKeyBytes": @(maxKeyBytes),
      @"maxValueBytes": @(maxValueBytes),
      @"maxKeysPerList": @(maxKeysPerList)
    }
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString * kv_json_from_dictionary(NSDictionary *config) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static EJSContext * make_context(NSString *contextID, NSString *config, EJSRuntime **runtimeOut, NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  configuration.runtimeName = @"ejs_kv_apple_test";
  configuration.contextDefaults = @{
    EJSKeyValueStoreConfigurationKey: config
  };
  EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
  EJSContext *context = [runtime createContextWithID:contextID error:error];
  if (context == nil) {
    [runtime invalidate];
    return nil;
  }
  if (runtimeOut != NULL) {
    *runtimeOut = runtime;
  }
  return context;
}

static BOOL run_script(EJSContext *context,
                       TestReportProvider *reportProvider,
                       NSString *source,
                       NSString *filename,
                       NSString *expected,
                       NSError **error) {
  [reportProvider reset];
  if (![context evaluateScript:source filename:filename error:error]) {
    fprintf(stderr, "%s failed to evaluate: %s\n", filename.UTF8String, (*error).localizedDescription.UTF8String);
    return NO;
  }
  return wait_for_report(reportProvider, expected);
}

int main(void) {
  @autoreleasepool {
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ejs-kv-test-%@", NSUUID.UUID.UUIDString]];
    NSString *defaultStore = [base stringByAppendingPathComponent:@"default"];
    NSString *namedStore = [base stringByAppendingPathComponent:@"named"];
    NSString *config = kv_json(defaultStore, namedStore, 16, 64, 8);

    NSError *error = nil;
#ifdef EJS_TEST
    if (!EJSKeyValueStoreAppleTestRunInternalCoverage([base stringByAppendingPathComponent:@"internal"], &error)) {
      fprintf(stderr, "kv internal coverage helper failed: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    error = nil;
    EJSContext *nilContext = nil;
    if (EJSKeyValueStoreInstallIntoContext(nilContext, &error) || error == nil ||
        [error.localizedDescription containsString:@"Context is required"] == NO) {
      fprintf(stderr, "kv nil context install should fail with context error\n");
      return EXIT_FAILURE;
    }
    error = nil;
#endif
    EJSRuntime *runtime = nil;
    EJSContext *context = make_context(@"app://tests/kv", config, &runtime, &error);
    if (context == nil) {
      fprintf(stderr, "failed to create kv context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error]) {
      fprintf(stderr, "failed to register report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!EJSKeyValueStoreInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install EJSKV: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *basic =
      @"(async function(){"
       " await EJSKV.set('text','hello');"
       " if (!globalThis.EJSStorage) throw new Error('storage facade missing');"
       " const text = new Uint8Array(await EJSKV.get('text'));"
       " if (text.length !== 5 || text[0] !== 104) throw new Error('text bytes failed');"
       " await EJSKV.set('bin', new Uint8Array([1,2,3]).subarray(1));"
       " const bin = new Uint8Array(await EJSKV.get('bin'));"
       " if (bin.length !== 2 || bin[0] !== 2 || bin[1] !== 3) throw new Error('binary failed');"
       " await EJSKV.setJSON('json', { ok: true, n: 7 });"
       " const json = await EJSKV.getJSON('json');"
       " if (!json.ok || json.n !== 7) throw new Error('json failed');"
       " if (!(await EJSKV.has('bin'))) throw new Error('has failed');"
       " if (!(await EJSKV.delete('bin')) || await EJSKV.has('bin')) throw new Error('delete failed');"
       " await EJSKV.set('name','store', { store: 'named' });"
       " if (await EJSKV.get('name') !== null) throw new Error('store isolation failed');"
       " try { await EJSKV.set('x','y', { store: 'missing' }); throw new Error('missing store accepted'); } catch (e) { if (!String(e.message).includes('store')) throw e; }"
       " try { await EJSKV.set('x','y', { store: 'readonly' }); throw new Error('readonly accepted'); } catch (e) { if (!String(e.message).includes('write')) throw e; }"
       " try { await EJSKV.set('this-key-is-too-long','x'); throw new Error('key limit accepted'); } catch (e) { if (!String(e.message).includes('maxKeyBytes')) throw e; }"
       " try { await EJSKV.set('large', new Uint8Array(128)); throw new Error('value limit accepted'); } catch (e) { if (!String(e.message).includes('maxValueBytes')) throw e; }"
       " await __ejs_native__.invoke('test','report','kv:basic');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";

    if (!run_script(context, reportProvider, basic, @"kv_basic.js", @"kv:basic", &error)) {
      return EXIT_FAILURE;
    }

    NSString *nativeEdges =
      @"(async function(){"
       " const text = (value) => typeof value === 'string' ? value : String.fromCharCode.apply(null, new Uint8Array(value));"
       " const parse = async (promise) => JSON.parse(text(await promise));"
       " const invoke = (method, request, transfer) => __ejs_native__.invoke('ejs.kv', method, JSON.stringify(request), transfer === undefined ? null : transfer);"
       " const expectReject = async (promise, needle) => {"
       "   let rejected = false;"
       "   try { await promise; } catch (e) {"
       "     rejected = true;"
       "     if (String(e && (e.message || e)).indexOf(needle) === -1) throw e;"
       "   }"
       "   if (!rejected) throw new Error('missing rejection: ' + needle);"
       " };"
       " await expectReject(__ejs_native__.invoke('ejs.kv', 'unsupportedMethod', '{}', null), 'Unsupported ejs.kv method');"
       " await expectReject(__ejs_native__.invoke('ejs.kv', 'get', '[]', null), 'JSON object');"
       " await expectReject(invoke('get', { key: '' }), 'key must be');"
       " await expectReject(invoke('keys', { store: '' }), 'store must be');"
       " await expectReject(invoke('set', { key: 'miss' }), 'transfer buffer');"
       " await invoke('set', { key: 'empty' }, new Uint8Array([]).buffer);"
       " const empty = new Uint8Array(await invoke('get', { key: 'empty' }));"
       " if (empty.length !== 0) throw new Error('empty value length mismatch');"
       " const missingDelete = await parse(invoke('delete', { key: 'missing-delete' }));"
       " if (missingDelete.deleted !== false) throw new Error('missing delete result mismatch');"
       " const missingHas = await parse(invoke('has', { key: 'missing-has' }));"
       " if (missingHas.exists !== false) throw new Error('missing has result mismatch');"
       " await __ejs_native__.invoke('test','report','kv:native-edges');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context, reportProvider, nativeEdges, @"kv_native_edges.js", @"kv:native-edges", &error)) {
      return EXIT_FAILURE;
    }
    [runtime invalidate];

    EJSRuntime *runtime2 = nil;
    EJSContext *context2 = make_context(@"app://tests/kv-persist", config, &runtime2, &error);
    if (context2 == nil) {
      fprintf(stderr, "failed to create kv persistence context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider2 = [[TestReportProvider alloc] init];
    if (![context2 registerProvider:reportProvider2 error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(context2, &error)) {
      fprintf(stderr, "failed to install persistence context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *persist =
      @"(async function(){"
       " const text = new Uint8Array(await EJSKV.get('text'));"
       " if (text[0] !== 104) throw new Error('default persistence failed');"
       " const named = new Uint8Array(await EJSKV.get('name', { store: 'named' }));"
       " if (named[0] !== 115) throw new Error('named persistence failed');"
       " await __ejs_native__.invoke('test','report','kv:persist');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context2, reportProvider2, persist, @"kv_persist.js", @"kv:persist", &error)) {
      return EXIT_FAILURE;
    }
    [runtime2 invalidate];

    NSString *poisonDefaultStore = [base stringByAppendingPathComponent:@"poison-default"];
    NSString *poisonNamedStore = [base stringByAppendingPathComponent:@"poison-named"];
    NSString *poisonConfig = kv_json(poisonDefaultStore, poisonNamedStore, 16, 64, 8);
    EJSRuntime *poisonRuntime = nil;
    EJSContext *poisonContext = make_context(@"app://tests/kv-poison-manifest", poisonConfig, &poisonRuntime, &error);
    if (poisonContext == nil) {
      fprintf(stderr, "failed to create poisoned-manifest context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *poisonReportProvider = [[TestReportProvider alloc] init];
    if (![poisonContext registerProvider:poisonReportProvider error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(poisonContext, &error)) {
      fprintf(stderr, "failed to install poisoned-manifest context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (![[NSFileManager defaultManager] createDirectoryAtPath:poisonDefaultStore
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&error]) {
      fprintf(stderr, "failed to create poisoned-manifest store: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *outsidePath = [base stringByAppendingPathComponent:@"outside.txt"];
    NSString *outsideContent = @"outside-intact";
    if (![outsideContent writeToFile:outsidePath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
      fprintf(stderr, "failed to write outside sentinel file: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSDictionary *poisonManifest = @{ @"keys": @{ @"poison": @"../../outside.txt" } };
    NSData *poisonManifestData = [NSJSONSerialization dataWithJSONObject:poisonManifest options:0 error:&error];
    if (poisonManifestData == nil ||
        ![poisonManifestData writeToFile:[poisonDefaultStore stringByAppendingPathComponent:@"manifest.json"]
                                 options:NSDataWritingAtomic
                                   error:&error]) {
      fprintf(stderr, "failed to write poisoned manifest: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *poisonScript =
      @"(async function(){"
       " if (await EJSKV.get('poison') !== null) throw new Error('manifest should be ignored');"
       " if (await EJSKV.delete('poison')) throw new Error('manifest delete should be ignored');"
       " await EJSKV.set('poison', 'safe');"
       " const value = new Uint8Array(await EJSKV.get('poison'));"
       " if (value.length !== 4 || value[0] !== 115) throw new Error('sqlite value missing after manifest poison');"
       " await EJSKV.clear();"
       " if (await EJSKV.get('poison') !== null) throw new Error('sqlite clear failed');"
       " await __ejs_native__.invoke('test','report','kv:poison-manifest');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(poisonContext,
                    poisonReportProvider,
                    poisonScript,
                    @"kv_poison_manifest.js",
                    @"kv:poison-manifest",
                    &error)) {
      return EXIT_FAILURE;
    }

    NSString *outsideAfter = [NSString stringWithContentsOfFile:outsidePath
                                                       encoding:NSUTF8StringEncoding
                                                          error:&error];
    if (![outsideAfter isEqualToString:outsideContent]) {
      fprintf(stderr, "outside sentinel content changed: expected=%s actual=%s\n",
              outsideContent.UTF8String,
              outsideAfter.UTF8String ?: "");
      return EXIT_FAILURE;
    }
    [poisonRuntime invalidate];

    EJSRuntime *raceRuntimeA = nil;
    EJSRuntime *raceRuntimeB = nil;
    EJSContext *raceContextA = make_context(@"app://tests/kv-race-a", config, &raceRuntimeA, &error);
    EJSContext *raceContextB = make_context(@"app://tests/kv-race-b", config, &raceRuntimeB, &error);
    if (raceContextA == nil || raceContextB == nil) {
      fprintf(stderr, "failed to create race contexts: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *raceReportA = [[TestReportProvider alloc] init];
    TestReportProvider *raceReportB = [[TestReportProvider alloc] init];
    if (![raceContextA registerProvider:raceReportA error:&error] ||
        ![raceContextB registerProvider:raceReportB error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(raceContextA, &error) ||
        !EJSKeyValueStoreInstallIntoContext(raceContextB, &error)) {
      fprintf(stderr, "failed to install race contexts: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *raceScriptA =
      @"(async function(){"
       " for (let i = 0; i < 80; i++) { await EJSKV.set('race', 'A' + i); }"
       " await __ejs_native__.invoke('test','report','kv:race-a');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    NSString *raceScriptB =
      @"(async function(){"
       " for (let i = 0; i < 80; i++) { await EJSKV.set('race', 'B' + i); }"
       " await __ejs_native__.invoke('test','report','kv:race-b');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    __block NSError *raceEvalErrorA = nil;
    __block NSError *raceEvalErrorB = nil;
    __block BOOL raceEvalA = NO;
    __block BOOL raceEvalB = NO;
    dispatch_group_t raceGroup = dispatch_group_create();
    dispatch_group_async(raceGroup, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      raceEvalA = [raceContextA evaluateScript:raceScriptA filename:@"kv_race_a.js" error:&raceEvalErrorA];
    });
    dispatch_group_async(raceGroup, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      raceEvalB = [raceContextB evaluateScript:raceScriptB filename:@"kv_race_b.js" error:&raceEvalErrorB];
    });
    dispatch_group_wait(raceGroup, DISPATCH_TIME_FOREVER);
    if (!raceEvalA || !raceEvalB ||
        !wait_for_report(raceReportA, @"kv:race-a") ||
        !wait_for_report(raceReportB, @"kv:race-b")) {
      fprintf(stderr, "kv race scripts failed: A=%d B=%d errA=%s errB=%s\n",
              raceEvalA,
              raceEvalB,
              raceEvalErrorA.localizedDescription.UTF8String ?: "",
              raceEvalErrorB.localizedDescription.UTF8String ?: "");
      return EXIT_FAILURE;
    }
    [raceRuntimeA invalidate];
    [raceRuntimeB invalidate];

    EJSRuntime *raceVerifyRuntime = nil;
    EJSContext *raceVerifyContext = make_context(@"app://tests/kv-race-verify", config, &raceVerifyRuntime, &error);
    if (raceVerifyContext == nil) {
      fprintf(stderr, "failed to create race verify context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *raceVerifyReport = [[TestReportProvider alloc] init];
    if (![raceVerifyContext registerProvider:raceVerifyReport error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(raceVerifyContext, &error)) {
      fprintf(stderr, "failed to install race verify context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *raceVerifyScript =
      @"(async function(){"
       " const value = await EJSKV.get('race');"
       " if (value == null) throw new Error('race key missing after concurrent writes');"
       " const keys = await EJSKV.keys();"
       " if (keys.indexOf('race') < 0) throw new Error('race key missing from sqlite store');"
       " await __ejs_native__.invoke('test','report','kv:race-verify');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(raceVerifyContext, raceVerifyReport, raceVerifyScript, @"kv_race_verify.js", @"kv:race-verify", &error)) {
      return EXIT_FAILURE;
    }
    [raceVerifyRuntime invalidate];

    NSString *smallConfig = kv_json([base stringByAppendingPathComponent:@"small"],
                                    [base stringByAppendingPathComponent:@"small-named"],
                                    16,
                                    16,
                                    1);
    EJSRuntime *runtime3 = nil;
    EJSContext *context3 = make_context(@"app://tests/kv-limits", smallConfig, &runtime3, &error);
    if (context3 == nil) {
      fprintf(stderr, "failed to create limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider3 = [[TestReportProvider alloc] init];
    if (![context3 registerProvider:reportProvider3 error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(context3, &error)) {
      fprintf(stderr, "failed to install limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *limits =
      @"(async function(){"
       " await EJSKV.set('a','1');"
       " await EJSKV.set('b','2');"
       " try { await EJSKV.keys(); throw new Error('keys limit accepted'); } catch (e) { if (!String(e.message).includes('maxKeysPerList')) throw e; }"
       " await __ejs_native__.invoke('test','report','kv:limits');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context3, reportProvider3, limits, @"kv_limits.js", @"kv:limits", &error)) {
      return EXIT_FAILURE;
    }
    [runtime3 invalidate];

    NSString *storageConfig = kv_json([base stringByAppendingPathComponent:@"storage-default"],
                                      [base stringByAppendingPathComponent:@"storage-named"],
                                      128,
                                      1024,
                                      100);
    EJSRuntime *runtime4 = nil;
    EJSContext *context4 = make_context(@"app://tests/kv-storage", storageConfig, &runtime4, &error);
    if (context4 == nil) {
      fprintf(stderr, "failed to create storage facade context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider4 = [[TestReportProvider alloc] init];
    if (![context4 registerProvider:reportProvider4 error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(context4, &error)) {
      fprintf(stderr, "failed to install storage facade context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *storage =
      @"(async function(){"
       " if (!globalThis.EJSKV || !globalThis.EJSStorage) throw new Error('storage bundle globals missing');"
       " await EJSStorage.local.setItem('a', 12);"
       " if (await EJSStorage.local.getItem('a') !== '12') throw new Error('storage local string failed');"
       " await EJSStorage.local.setItem('bool', true);"
       " if (await EJSStorage.local.getItem('bool') !== 'true') throw new Error('storage local bool coercion failed');"
       " await EJSStorage.local.setItem('nil', null);"
       " if (await EJSStorage.local.getItem('nil') !== 'null') throw new Error('storage local null coercion failed');"
       " await EJSStorage.local.setItem('undef', undefined);"
       " if (await EJSStorage.local.getItem('undef') !== 'undefined') throw new Error('storage local undefined coercion failed');"
       " await EJSStorage.local.setItem('objLocal', { ok: true });"
       " if (await EJSStorage.local.getItem('objLocal') !== '[object Object]') throw new Error('storage local object coercion failed');"
       " await EJSStorage.local.setItem('b', 'bee');"
       " if (await EJSStorage.local.length() !== 6) throw new Error('storage length failed');"
       " if (await EJSStorage.local.key(0) !== 'a') throw new Error('storage key failed');"
       " if (await EJSStorage.local.key(-1) !== null) throw new Error('storage negative key failed');"
       " if (await EJSStorage.local.key(100) !== null) throw new Error('storage missing key failed');"
       " await EJSStorage.local.removeItem('a');"
       " if (await EJSStorage.local.getItem('a') !== null) throw new Error('storage remove failed');"
       " await EJSStorage.json.set('obj', { ok: true, n: 9 });"
       " const obj = await EJSStorage.json.get('obj');"
       " if (!obj.ok || obj.n !== 9) throw new Error('storage json failed');"
       " await EJSStorage.json.remove('obj');"
       " if (await EJSStorage.json.get('obj') !== null) throw new Error('storage json remove failed');"
       " await EJSStorage.local.clear();"
       " if (await EJSStorage.local.length() !== 0) throw new Error('storage clear failed');"
       " await __ejs_native__.invoke('test','report','kv:storage');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context4, reportProvider4, storage, @"kv_storage_facade.js", @"kv:storage", &error)) {
      return EXIT_FAILURE;
    }
    [runtime4 invalidate];

    NSString *accessDefaultStore = [base stringByAppendingPathComponent:@"access-default"];
    NSString *writeOnlyStore = [base stringByAppendingPathComponent:@"write-only"];
    NSString *noCreateStore = [base stringByAppendingPathComponent:@"no-create"];
    NSString *fileStorePath = [base stringByAppendingPathComponent:@"file-store"];
    if (![@"not-a-directory" writeToFile:fileStorePath
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:&error]) {
      fprintf(stderr, "failed to create kv file-store sentinel: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *accessConfig = kv_json_from_dictionary(@{
      @"version": @1,
      @"defaultStore": @"default",
      @"stores": @{
        @"default": @{
          @"path": accessDefaultStore,
          @"permissions": @[ @"read", @"write" ],
          @"createIfMissing": @YES
        },
        @"writeOnly": @{
          @"path": writeOnlyStore,
          @"permissions": @[ @"write" ],
          @"createIfMissing": @YES
        },
        @"noCreate": @{
          @"path": noCreateStore,
          @"permissions": @[ @"read", @"write" ],
          @"createIfMissing": @NO
        },
        @"fileStore": @{
          @"path": fileStorePath,
          @"permissions": @[ @"read", @"write" ],
          @"createIfMissing": @NO
        }
      },
      @"limits": @{
        @"maxKeyBytes": @64,
        @"maxValueBytes": @256,
        @"maxKeysPerList": @16
      }
    });
    EJSRuntime *accessRuntime = nil;
    EJSContext *accessContext = make_context(@"app://tests/kv-access-edges", accessConfig, &accessRuntime, &error);
    if (accessContext == nil) {
      fprintf(stderr, "failed to create kv access context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *accessReport = [[TestReportProvider alloc] init];
    if (![accessContext registerProvider:accessReport error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(accessContext, &error)) {
      fprintf(stderr, "failed to install kv access context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *accessEdges =
      @"(async function(){"
       " const expectReject = async (promise, needle) => {"
       "   let rejected = false;"
       "   try { await promise; } catch (e) {"
       "     rejected = true;"
       "     if (String(e && (e.message || e)).indexOf(needle) === -1) throw e;"
       "   }"
       "   if (!rejected) throw new Error('missing rejection: ' + needle);"
       " };"
       " await expectReject(EJSKV.get('probe', { store: 'writeOnly' }), 'allow reads');"
       " await expectReject(EJSKV.set('probe', 'value', { store: 'noCreate' }), 'createIfMissing');"
       " await expectReject(EJSKV.set('probe', 'value', { store: 'fileStore' }), 'not a directory');"
       " const keys = await EJSKV.keys();"
       " if (keys.length !== 0) throw new Error('empty keys mismatch');"
       " await __ejs_native__.invoke('test','report','kv:access-edges');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(accessContext, accessReport, accessEdges, @"kv_access_edges.js", @"kv:access-edges", &error)) {
      return EXIT_FAILURE;
    }
    [accessRuntime invalidate];

    NSString *wideStore = [base stringByAppendingPathComponent:@"wide-value"];
    NSString *wideConfig = kv_json(wideStore,
                                   [base stringByAppendingPathComponent:@"wide-value-named"],
                                   64,
                                   128,
                                   16);
    EJSRuntime *wideRuntime = nil;
    EJSContext *wideContext = make_context(@"app://tests/kv-wide-value", wideConfig, &wideRuntime, &error);
    if (wideContext == nil) {
      fprintf(stderr, "failed to create kv wide-value context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *wideReport = [[TestReportProvider alloc] init];
    if (![wideContext registerProvider:wideReport error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(wideContext, &error)) {
      fprintf(stderr, "failed to install kv wide-value context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *wideWrite =
      @"(async function(){"
       " await EJSKV.set('wide', new Uint8Array(32));"
       " await __ejs_native__.invoke('test','report','kv:wide-write');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(wideContext, wideReport, wideWrite, @"kv_wide_write.js", @"kv:wide-write", &error)) {
      return EXIT_FAILURE;
    }
    [wideRuntime invalidate];

    NSString *narrowConfig = kv_json(wideStore,
                                     [base stringByAppendingPathComponent:@"wide-value-named"],
                                     64,
                                     8,
                                     16);
    EJSRuntime *narrowRuntime = nil;
    EJSContext *narrowContext = make_context(@"app://tests/kv-narrow-value", narrowConfig, &narrowRuntime, &error);
    if (narrowContext == nil) {
      fprintf(stderr, "failed to create kv narrow-value context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *narrowReport = [[TestReportProvider alloc] init];
    if (![narrowContext registerProvider:narrowReport error:&error] ||
        !EJSKeyValueStoreInstallIntoContext(narrowContext, &error)) {
      fprintf(stderr, "failed to install kv narrow-value context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *narrowRead =
      @"(async function(){"
       " try { await EJSKV.get('wide'); }"
       " catch (e) {"
       "   if (String(e && (e.message || e)).indexOf('maxValueBytes') !== -1) {"
       "     await __ejs_native__.invoke('test','report','kv:narrow-read');"
       "     return;"
       "   }"
       "   throw e;"
       " }"
       " throw new Error('wide value read should fail');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(narrowContext, narrowReport, narrowRead, @"kv_narrow_read.js", @"kv:narrow-read", &error)) {
      return EXIT_FAILURE;
    }
    [narrowRuntime invalidate];

#ifdef EJS_TEST
    EJSRuntime *rollbackRuntime = nil;
    EJSContext *rollbackContext = make_context(@"app://tests/kv-install-rollback", config, &rollbackRuntime, &error);
    if (rollbackContext == nil) {
      fprintf(stderr, "failed to create kv rollback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *rollbackReportProvider = [[TestReportProvider alloc] init];
    if (![rollbackContext registerProvider:rollbackReportProvider error:&error]) {
      fprintf(stderr, "failed to register kv rollback report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![rollbackContext evaluateScript:
          @"Object.defineProperty(globalThis, 'EJSKV', { value: { marker: 'pre-kv' }, configurable: true, writable: false, enumerable: false });"
           "Object.defineProperty(globalThis, 'EJSStorage', { value: { marker: 'pre-storage' }, configurable: true, writable: true, enumerable: false });"
                         filename:@"kv_rollback_setup.js"
                            error:&error]) {
      fprintf(stderr, "failed to setup kv rollback globals: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSKeyValueStoreAppleTestSetInstallFailScriptIndex(1);
    NSError *rollbackInstallError = nil;
    BOOL rollbackInstallResult = EJSKeyValueStoreInstallIntoContext(rollbackContext, &rollbackInstallError);
    EJSKeyValueStoreAppleTestSetInstallFailScriptIndex(-1);
    if (rollbackInstallResult || rollbackInstallError == nil ||
        [rollbackInstallError.localizedDescription containsString:@"sentinel"] == NO) {
      fprintf(stderr, "kv rollback install should fail with sentinel error\n");
      return EXIT_FAILURE;
    }

    if (!run_script(rollbackContext,
                    rollbackReportProvider,
                    @"(async function(){"
                     " const kvDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'EJSKV');"
                     " const storageDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'EJSStorage');"
                     " if (!kvDescriptor || kvDescriptor.enumerable !== false || kvDescriptor.writable !== false || !kvDescriptor.value || kvDescriptor.value.marker !== 'pre-kv') throw new Error('kv descriptor rollback mismatch');"
                     " if (!storageDescriptor || storageDescriptor.enumerable !== false || !storageDescriptor.value || storageDescriptor.value.marker !== 'pre-storage') throw new Error('storage descriptor rollback mismatch');"
                     " let providerRolledBack = false;"
                     " try {"
                     "   await __ejs_native__.invoke('ejs.kv', 'has', JSON.stringify({ key: 'probe' }), null);"
                     " } catch (error) {"
                     "   providerRolledBack = true;"
                     " }"
                     " if (!providerRolledBack) throw new Error('kv provider rollback missing');"
                     " await __ejs_native__.invoke('test', 'report', 'kv:install-rollback');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"kv_install_rollback.js",
                    @"kv:install-rollback",
                    &error)) {
      return EXIT_FAILURE;
    }
    [rollbackRuntime invalidate];
#endif

    [[NSFileManager defaultManager] removeItemAtPath:base error:nil];
    return EXIT_SUCCESS;
  }
}
