#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSSQLiteApple.h"

#include <sqlite3.h>

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

static NSString * sqlite_json_with_limits(NSString *mainPath,
                                          NSString *readonlyPath,
                                          NSUInteger maxRows,
                                          NSNumber *maxTextBytes,
                                          NSNumber *maxResponseBytes) {
  NSMutableDictionary *limits = [@{
    @"maxRows": @(maxRows),
    @"maxStatementBytes": @4096,
    @"maxBlobBytes": @128
  } mutableCopy];
  if (maxTextBytes != nil) {
    limits[@"maxTextBytes"] = maxTextBytes;
  }
  if (maxResponseBytes != nil) {
    limits[@"maxResponseBytes"] = maxResponseBytes;
  }
  NSDictionary *config = @{
    @"version": @1,
    @"databases": @{
      @"main": @{
        @"path": mainPath,
        @"permissions": @[ @"read", @"write" ],
        @"createIfMissing": @YES
      },
      @"readonly": @{
        @"path": readonlyPath,
        @"permissions": @[ @"read" ],
        @"createIfMissing": @NO
      }
    },
    @"limits": limits
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString * sqlite_json(NSString *mainPath, NSString *readonlyPath, NSUInteger maxRows) {
  return sqlite_json_with_limits(mainPath, readonlyPath, maxRows, nil, nil);
}

static EJSContext * make_context(NSString *contextID, NSString *config, EJSRuntime **runtimeOut, NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  configuration.runtimeName = @"ejs_sqlite_apple_test";
  configuration.contextDefaults = @{
    EJSSQLiteConfigurationKey: config
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

static BOOL write_readonly_fixture(NSString *path) {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *directory = [path stringByDeletingLastPathComponent];
  if (![fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
    return NO;
  }

  sqlite3 *db = NULL;
  if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
    if (db != NULL) {
      sqlite3_close(db);
    }
    return NO;
  }
  char *errmsg = NULL;
  int rc = sqlite3_exec(db,
                        "CREATE TABLE fixture (id INTEGER PRIMARY KEY, value TEXT);"
                        "INSERT INTO fixture (value) VALUES ('ready');",
                        NULL,
                        NULL,
                        &errmsg);
  if (errmsg != NULL) {
    sqlite3_free(errmsg);
  }
  sqlite3_close(db);
  return rc == SQLITE_OK;
}

int main(void) {
  @autoreleasepool {
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ejs-sqlite-test-%@", NSUUID.UUID.UUIDString]];
    NSString *mainDB = [base stringByAppendingPathComponent:@"main.sqlite"];
    NSString *readonlyDB = [base stringByAppendingPathComponent:@"readonly.sqlite"];
    if (!write_readonly_fixture(readonlyDB)) {
      fprintf(stderr, "failed to create readonly sqlite fixture\n");
      return EXIT_FAILURE;
    }

    NSError *error = nil;
    EJSRuntime *runtime = nil;
    EJSContext *context = make_context(@"app://tests/sqlite", sqlite_json(mainDB, readonlyDB, 8), &runtime, &error);
    if (context == nil) {
      fprintf(stderr, "failed to create sqlite context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error]) {
      fprintf(stderr, "failed to register report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (!EJSSQLiteInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install EJSSQLite: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *basic =
      @"(async function(){"
       " if (!globalThis.EJSSQLite) throw new Error('sqlite global missing');"
       " const db = await EJSSQLite.open('main');"
       " await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, qty REAL, active INTEGER, note TEXT)');"
       " await db.execute('INSERT INTO items (name, qty, active, note) VALUES (?, ?, ?, ?)', ['alpha', 2.5, true, null]);"
       " await db.execute('INSERT INTO items (name, qty, active, note) VALUES (?, ?, ?, ?)', ['beta', 7, false, 'ok']);"
       " const rows = await db.query('SELECT name, qty, active, note FROM items WHERE qty > ? ORDER BY id', [1]);"
       " if (rows.length !== 2 || rows[0].name !== 'alpha' || rows[0].qty !== 2.5 || rows[0].active !== 1 || rows[0].note !== null) throw new Error('query rows failed');"
       " const blobRows = await db.query(\"SELECT X'0102' AS data\");"
       " if (blobRows[0].data.type !== 'blob' || blobRows[0].data.base64 !== 'AQI=') throw new Error('blob row failed');"
       " await db.close();"
       " try { await db.query('SELECT 1'); throw new Error('closed query accepted'); } catch (e) { if (!String(e.message).includes('closed')) throw e; }"
       " await __ejs_native__.invoke('test','report','sqlite:basic');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context, reportProvider, basic, @"sqlite_basic.js", @"sqlite:basic", &error)) {
      return EXIT_FAILURE;
    }

    NSString *int64Precision =
      @"(async function(){"
       " const db = await EJSSQLite.open('main');"
       " await db.execute('CREATE TABLE bigints (value INTEGER)');"
       " await db.execute('INSERT INTO bigints (value) VALUES (9007199254740993)');"
       " const rows = await db.query('SELECT value FROM bigints');"
       " if (rows.length !== 1) throw new Error('int64 row missing');"
       " const value = rows[0].value;"
       " if (typeof BigInt === 'function') {"
       "   if (typeof value !== 'bigint' || value !== 9007199254740993n) throw new Error('int64 bigint decode failed');"
       " } else {"
       "   if (value !== '9007199254740993') throw new Error('int64 string decode failed');"
       " }"
       " await db.close();"
       " await __ejs_native__.invoke('test','report','sqlite:int64');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context, reportProvider, int64Precision, @"sqlite_int64.js", @"sqlite:int64", &error)) {
      return EXIT_FAILURE;
    }

    NSString *transactions =
      @"(async function(){"
       " const db = await EJSSQLite.open('main');"
       " await db.transaction(async tx => {"
       "   await tx.execute('INSERT INTO items (name, qty, active) VALUES (?, ?, ?)', ['commit', 1, true]);"
       "   let outsideRejected = false;"
       "   try { await db.query('SELECT name FROM items WHERE name = ?', ['commit']); }"
       "   catch (e) { outsideRejected = String(e.message).includes('transaction client'); }"
       "   if (!outsideRejected) throw new Error('outer db query joined transaction');"
       "   const txRows = await tx.query('SELECT name FROM items WHERE name = ?', ['commit']);"
       "   if (txRows.length !== 1 || txRows[0].name !== 'commit') throw new Error('transaction client query failed');"
       " });"
       " try { await db.transaction(async tx => { await tx.execute('INSERT INTO items (name, qty, active) VALUES (?, ?, ?)', ['rollback', 1, true]); throw new Error('force rollback'); }); } catch (e) { if (!String(e.message).includes('force rollback')) throw e; }"
       " const rows = await db.query(\"SELECT name FROM items WHERE name IN ('commit','rollback') ORDER BY name\");"
       " if (rows.length !== 1 || rows[0].name !== 'commit') throw new Error('transaction result failed');"
       " await db.close();"
       " await __ejs_native__.invoke('test','report','sqlite:transactions');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context, reportProvider, transactions, @"sqlite_transactions.js", @"sqlite:transactions", &error)) {
      return EXIT_FAILURE;
    }

    NSString *policy =
      @"(async function(){"
       " try { await EJSSQLite.open('missing'); throw new Error('missing db accepted'); } catch (e) { if (!String(e.message).includes('not allowed')) throw e; }"
       " const ro = await EJSSQLite.open('readonly');"
       " const rows = await ro.query('SELECT value FROM fixture');"
       " if (rows.length !== 1 || rows[0].value !== 'ready') throw new Error('readonly query failed');"
       " try { await ro.execute(\"INSERT INTO fixture (value) VALUES ('nope')\"); throw new Error('readonly write accepted'); } catch (e) { if (!String(e.message).includes('writes')) throw e; }"
       " await ro.close();"
       " await __ejs_native__.invoke('test','report','sqlite:policy');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context, reportProvider, policy, @"sqlite_policy.js", @"sqlite:policy", &error)) {
      return EXIT_FAILURE;
    }

    NSString *paramValidation =
      @"(async function(){"
       " const moduleID = 'ejs.sqlite';"
       " const connectionID = 'native-bind-validation';"
       " async function invoke(method, request) {"
       "   return __ejs_native__.invoke(moduleID, method, JSON.stringify(request), null);"
       " }"
	       " async function expectBindFailure(sql, params, expected) {"
	       "   try {"
	       "     await invoke('execute', { connection: connectionID, sql: sql, params: params });"
	       "     throw new Error('expected bind failure: ' + expected);"
	       "   } catch (error) {"
	       "     if (String(error.message).indexOf(expected) < 0) throw error;"
	       "   }"
	       " }"
	       " async function expectInvokeFailure(method, request, expected) {"
	       "   try {"
	       "     await invoke(method, request);"
	       "     throw new Error('expected invoke failure: ' + expected);"
	       "   } catch (error) {"
	       "     if (String(error.message).indexOf(expected) < 0) throw error;"
	       "   }"
	       " }"
	       " await invoke('open', { connection: connectionID, name: 'main' });"
	       " await invoke('execute', { connection: connectionID, sql: 'CREATE TABLE IF NOT EXISTS bind_check (id INTEGER PRIMARY KEY, b INTEGER, n REAL, s TEXT)' });"
       " await expectBindFailure('INSERT INTO bind_check (b) VALUES (?)', [{ type: 'boolean', value: 1 }], 'boolean');"
       " await expectBindFailure('INSERT INTO bind_check (b) VALUES (?)', [{ type: 'boolean', value: null }], 'boolean');"
       " await expectBindFailure('INSERT INTO bind_check (n) VALUES (?)', [{ type: 'number', value: '1' }], 'number');"
       " await expectBindFailure('INSERT INTO bind_check (n) VALUES (?)', [{ type: 'number', value: true }], 'number');"
       " await expectBindFailure('INSERT INTO bind_check (s) VALUES (?)', [{ type: 'string', value: 123 }], 'string');"
       " await expectBindFailure('INSERT INTO bind_check (s) VALUES (?)', [{ type: 'string', value: null }], 'string');"
       " await expectBindFailure('INSERT INTO bind_check (s) VALUES (?)', [{ type: 'object', value: 'bad' }], 'unsupported');"
	       " await invoke('execute', {"
	       "   connection: connectionID,"
	       "   sql: 'INSERT INTO bind_check (b, n, s) VALUES (?, ?, ?)',"
       "   params: ["
       "     { type: 'boolean', value: true },"
       "     { type: 'number', value: 2.5 },"
	       "     { type: 'string', value: 'ok' }"
	       "   ]"
	       " });"
	       " await invoke('begin', { connection: connectionID, transaction: 'tx-1' });"
	       " await expectInvokeFailure('execute', { connection: connectionID, sql: 'INSERT INTO bind_check (s) VALUES (?)', params: [{ type: 'string', value: 'missing-tx' }] }, 'transaction does not match');"
	       " await expectInvokeFailure('execute', { connection: connectionID, transaction: 'tx-wrong', sql: 'INSERT INTO bind_check (s) VALUES (?)', params: [{ type: 'string', value: 'wrong-tx' }] }, 'transaction does not match');"
	       " await invoke('execute', { connection: connectionID, transaction: 'tx-1', sql: 'INSERT INTO bind_check (s) VALUES (?)', params: [{ type: 'string', value: 'in-tx' }] });"
	       " await invoke('commit', { connection: connectionID, transaction: 'tx-1' });"
	       " await expectInvokeFailure('query', { connection: connectionID, sql: 'SELECT 1; SELECT 2' }, 'single statement');"
	       " await expectInvokeFailure('execute', { connection: connectionID, sql: \"INSERT INTO bind_check (s) VALUES ('one'); INSERT INTO bind_check (s) VALUES ('two')\" }, 'single statement');"
	       " await invoke('close', { connection: connectionID });"
	       " await __ejs_native__.invoke('test','report','sqlite:param-validation');"
	       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context, reportProvider, paramValidation, @"sqlite_param_validation.js", @"sqlite:param-validation", &error)) {
      return EXIT_FAILURE;
    }
    [runtime invalidate];

    EJSRuntime *runtime2 = nil;
    EJSContext *context2 = make_context(@"app://tests/sqlite-limits", sqlite_json([base stringByAppendingPathComponent:@"limit.sqlite"], readonlyDB, 1), &runtime2, &error);
    if (context2 == nil) {
      fprintf(stderr, "failed to create sqlite limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider2 = [[TestReportProvider alloc] init];
    if (![context2 registerProvider:reportProvider2 error:&error] ||
        !EJSSQLiteInstallIntoContext(context2, &error)) {
      fprintf(stderr, "failed to install limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *limits =
      @"(async function(){"
       " const db = await EJSSQLite.open('main');"
       " await db.execute('CREATE TABLE rows (id INTEGER PRIMARY KEY)');"
       " await db.execute('INSERT INTO rows DEFAULT VALUES');"
       " await db.execute('INSERT INTO rows DEFAULT VALUES');"
       " try { await db.query('SELECT id FROM rows ORDER BY id'); throw new Error('row limit accepted'); } catch (e) { if (!String(e.message).includes('maxRows')) throw e; }"
       " await db.close();"
       " await __ejs_native__.invoke('test','report','sqlite:limits');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context2, reportProvider2, limits, @"sqlite_limits.js", @"sqlite:limits", &error)) {
      return EXIT_FAILURE;
    }
    [runtime2 invalidate];

    EJSRuntime *runtime3 = nil;
    EJSContext *context3 = make_context(@"app://tests/sqlite-byte-limits",
                                        sqlite_json_with_limits([base stringByAppendingPathComponent:@"byte-limit.sqlite"],
                                                                readonlyDB,
                                                                8,
                                                                @32,
                                                                @48),
                                        &runtime3,
                                        &error);
    if (context3 == nil) {
      fprintf(stderr, "failed to create sqlite byte-limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *reportProvider3 = [[TestReportProvider alloc] init];
    if (![context3 registerProvider:reportProvider3 error:&error] ||
        !EJSSQLiteInstallIntoContext(context3, &error)) {
      fprintf(stderr, "failed to install sqlite byte-limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *byteLimits =
      @"(async function(){"
       " const db = await EJSSQLite.open('main');"
       " await db.execute('CREATE TABLE text_limits (v TEXT)');"
       " await db.execute('INSERT INTO text_limits (v) VALUES (?)', ['0123456789012345678901234567890123456789']);"
       " try { await db.query('SELECT v FROM text_limits'); throw new Error('maxTextBytes limit not enforced'); } catch (e) { if (!String(e.message).includes('maxTextBytes')) throw e; }"
       " await db.execute('DELETE FROM text_limits');"
       " await db.execute('INSERT INTO text_limits (v) VALUES (?)', ['12345678901234567890']);"
       " await db.execute('INSERT INTO text_limits (v) VALUES (?)', ['12345678901234567890']);"
       " await db.execute('INSERT INTO text_limits (v) VALUES (?)', ['12345678901234567890']);"
       " try { await db.query('SELECT v FROM text_limits ORDER BY rowid'); throw new Error('maxResponseBytes limit not enforced'); } catch (e) { if (!String(e.message).includes('maxResponseBytes')) throw e; }"
       " await db.close();"
       " await __ejs_native__.invoke('test','report','sqlite:byte-limits');"
       "})().catch(e => __ejs_native__.invoke('test','report','error:' + e.message));";
    if (!run_script(context3, reportProvider3, byteLimits, @"sqlite_byte_limits.js", @"sqlite:byte-limits", &error)) {
      return EXIT_FAILURE;
    }
    [runtime3 invalidate];

#ifdef EJS_TEST
    EJSRuntime *rollbackRuntime = nil;
    EJSContext *rollbackContext =
      make_context(@"app://tests/sqlite-install-rollback", sqlite_json([base stringByAppendingPathComponent:@"rollback.sqlite"], readonlyDB, 8),
                   &rollbackRuntime,
                   &error);
    if (rollbackContext == nil) {
      fprintf(stderr, "failed to create sqlite rollback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *rollbackReportProvider = [[TestReportProvider alloc] init];
    if (![rollbackContext registerProvider:rollbackReportProvider error:&error]) {
      fprintf(stderr, "failed to register sqlite rollback report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![rollbackContext evaluateScript:
          @"Object.defineProperty(globalThis, 'EJSSQLite', { value: { marker: 'pre-sqlite' }, configurable: true, writable: false, enumerable: false });"
                         filename:@"sqlite_rollback_setup.js"
                            error:&error]) {
      fprintf(stderr, "failed to setup sqlite rollback global: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSSQLiteAppleTestSetInstallFailScriptIndex(0);
    NSError *rollbackInstallError = nil;
    BOOL rollbackInstallResult = EJSSQLiteInstallIntoContext(rollbackContext, &rollbackInstallError);
    EJSSQLiteAppleTestSetInstallFailScriptIndex(-1);
    if (rollbackInstallResult || rollbackInstallError == nil ||
        [rollbackInstallError.localizedDescription containsString:@"sentinel"] == NO) {
      fprintf(stderr, "sqlite rollback install should fail with sentinel error\n");
      return EXIT_FAILURE;
    }

    if (!run_script(rollbackContext,
                    rollbackReportProvider,
                    @"(async function(){"
                     " const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'EJSSQLite');"
                     " if (!descriptor || descriptor.enumerable !== false || descriptor.writable !== false || !descriptor.value || descriptor.value.marker !== 'pre-sqlite') throw new Error('sqlite descriptor rollback mismatch');"
                     " let providerRolledBack = false;"
                     " try {"
                     "   await __ejs_native__.invoke('ejs.sqlite', 'open', JSON.stringify({ connection: 'probe', name: 'main' }), null);"
                     " } catch (error) {"
                     "   providerRolledBack = true;"
                     " }"
                     " if (!providerRolledBack) throw new Error('sqlite provider rollback missing');"
                     " await __ejs_native__.invoke('test', 'report', 'sqlite:install-rollback');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"sqlite_install_rollback.js",
                    @"sqlite:install-rollback",
                    &error)) {
      return EXIT_FAILURE;
    }
    [rollbackRuntime invalidate];
#endif

    [[NSFileManager defaultManager] removeItemAtPath:base error:nil];
    return EXIT_SUCCESS;
  }
}
