#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"
#import "EJSFileSystemApple.h"

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

static NSString * fs_json(NSString *documentsRoot,
                          NSString *cacheRoot,
                          NSString *readOnlyRoot,
                          unsigned long long maxReadBytes,
                          unsigned long long maxWriteBytes) {
  NSDictionary *config = @{
    @"version": @1,
    @"defaultRoot": @"documents",
    @"roots": @{
      @"documents": @{
        @"path": documentsRoot,
        @"permissions": @[ @"read", @"write" ],
        @"createIfMissing": @YES
      },
      @"cache": @{
        @"path": cacheRoot,
        @"permissions": @[ @"read", @"write" ],
        @"createIfMissing": @YES
      },
      @"readOnly": @{
        @"path": readOnlyRoot,
        @"permissions": @[ @"read" ],
        @"createIfMissing": @YES
      }
    },
    @"limits": @{
      @"maxReadBytes": @(maxReadBytes),
      @"maxWriteBytes": @(maxWriteBytes)
    },
    @"pathPolicy": @{
      @"allowAbsolutePath": @NO,
      @"allowParentTraversal": @NO,
      @"allowSymlinkEscape": @NO
    }
  };

  NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static EJSContext * make_context(NSString *contextID,
                                 NSString *fsConfig,
                                 EJSRuntime **runtimeOut,
                                 NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  configuration.runtimeName = @"ejs_fs_apple_test";
  configuration.contextDefaults = @{
    EJSFileSystemConfigurationKey: fsConfig
  };

  EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
  if (runtime == nil) {
    return nil;
  }

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
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ejs-fs-test-%@", NSUUID.UUID.UUIDString]];
    NSString *documentsRoot = [base stringByAppendingPathComponent:@"documents"];
    NSString *cacheRoot = [base stringByAppendingPathComponent:@"cache"];
    NSString *readOnlyRoot = [base stringByAppendingPathComponent:@"read-only"];
    NSString *outsideRoot = [base stringByAppendingPathComponent:@"outside"];

    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:outsideRoot
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error]) {
      fprintf(stderr, "failed to create outside root: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSString *config = fs_json(documentsRoot, cacheRoot, readOnlyRoot, 1024, 1024);
    EJSRuntime *runtime = nil;
    EJSContext *context = make_context(@"app://tests/fs-main", config, &runtime, &error);
    if (context == nil) {
      fprintf(stderr, "failed to create fs context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
    if (![context registerProvider:reportProvider error:&error]) {
      fprintf(stderr, "failed to register report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!EJSFileSystemInstallIntoContext(context, &error)) {
      fprintf(stderr, "failed to install EJSFS: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    NSData *profileBytes = [NSData dataWithBytes:(const uint8_t[]){ 1, 2, 3 } length:3];
    if (![profileBytes writeToFile:[documentsRoot stringByAppendingPathComponent:@"profile.bin"]
                           options:0
                             error:&error]) {
      fprintf(stderr, "failed to seed profile.bin: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *listDirectory = [documentsRoot stringByAppendingPathComponent:@"listdir"];
    if (![fileManager createDirectoryAtPath:listDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error] ||
        ![@"b" writeToFile:[listDirectory stringByAppendingPathComponent:@"b.txt"]
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:&error] ||
        ![@"a" writeToFile:[listDirectory stringByAppendingPathComponent:@"a.txt"]
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:&error]) {
      fprintf(stderr, "failed to seed listdir: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *brokenLink = [documentsRoot stringByAppendingPathComponent:@"broken-link"];
    if (![fileManager createSymbolicLinkAtPath:brokenLink
                           withDestinationPath:@"missing-target.txt"
                                         error:&error]) {
      fprintf(stderr, "failed to seed broken symlink: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " if (!globalThis.EJSFS ||"
                     "     typeof EJSFS.promises.access !== 'function' ||"
                     "     typeof EJSFS.promises.copyFile !== 'function' ||"
                     "     typeof EJSFS.promises.exists !== 'function' ||"
                     "     typeof EJSFS.promises.chmod !== 'function' ||"
                     "     typeof EJSFS.promises.chown !== 'function' ||"
                     "     typeof EJSFS.promises.readFile !== 'function' ||"
                     "     typeof EJSFS.promises.writeFile !== 'function' ||"
                     "     typeof EJSFS.promises.readdir !== 'function' ||"
                     "     typeof EJSFS.promises.readLink !== 'function' ||"
                     "     typeof EJSFS.promises.link !== 'function' ||"
                     "     typeof EJSFS.promises.symlink !== 'function' ||"
                     "     typeof EJSFS.promises.statFs !== 'function' ||"
                     "     typeof EJSFS.promises.makeTempDir !== 'function' ||"
                     "     typeof EJSFS.promises.makeTempFile !== 'function' ||"
                     "     typeof EJSFS.promises.mkdir !== 'function' ||"
                     "     typeof EJSFS.promises.createDirectory !== 'function' ||"
                     "     typeof EJSFS.promises.rename !== 'function' ||"
                     "     typeof EJSFS.promises.remove !== 'function' ||"
                     "     typeof EJSFS.promises.utime !== 'function' ||"
                     "     typeof EJSFS.promises.lutime !== 'function' ||"
                     "     typeof EJSFS.promises.unlink !== 'function' ||"
                     "     typeof EJSFS.promises.rm !== 'function' ||"
                     "     typeof EJSFS.promises.stat !== 'function' ||"
                     "     typeof EJSFS.promises.lstat !== 'function' ||"
                     "     typeof EJSFS.promises.open !== 'function' ||"
                     "     typeof EJSFS.promises.delete !== 'function') throw new Error('missing EJSFS');"
                     " await __ejs_native__.invoke('test', 'report', 'installed');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_install.js",
                    @"installed",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.mkdir('made/child', { recursive: true });"
                     " await EJSFS.promises.writeFile('made/child/file.txt', 'mkdir-ok', 'utf8');"
                     " const entries = await EJSFS.promises.readdir('made/child');"
                     " await EJSFS.promises.createDirectory('made/alias');"
                     " const parentEntries = await EJSFS.promises.readdir('made');"
                     " await __ejs_native__.invoke('test', 'report', 'mkdir:' + entries.join(',') + ':' + parentEntries.join(','));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_mkdir.js",
                    @"mkdir:file.txt:alias,child",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.mkdir('no-parent/child'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', 'mkdir-nonrecursive-error'); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'mkdir-nonrecursive-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_mkdir_nonrecursive.js",
                    @"mkdir-nonrecursive-error",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try {"
                     "   await EJSFS.promises.mkdir('bool-option-check/child', { recursive: 'false' });"
                     " } catch (e) {"
                     "   await __ejs_native__.invoke('test', 'report', e instanceof TypeError ? 'mkdir-bool-option-error' : 'mkdir-bool-option-bad:' + e.name);"
                     "   return;"
                     " }"
                     " await __ejs_native__.invoke('test', 'report', 'mkdir-bool-option-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_mkdir_bool_option.js",
                    @"mkdir-bool-option-error",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const info = await EJSFS.promises.stat('profile.bin');"
                     " const existsProfile = await EJSFS.promises.exists('profile.bin');"
                     " const existsMissing = await EJSFS.promises.exists('missing-profile.bin');"
                     " const existsBrokenLink = await EJSFS.promises.exists('broken-link');"
                     " await EJSFS.promises.access('profile.bin');"
                     " const ok = info.isFile() && !info.isDirectory() && !info.isSymbolicLink() && info.size === 3 && existsProfile && !existsMissing && !existsBrokenLink"
                     "   && typeof info.dev === 'number' && typeof info.ino === 'number' && typeof info.mode === 'number'"
                     "   && typeof info.uid === 'number' && typeof info.gid === 'number'"
                     "   && typeof info.atimeMs === 'number' && typeof info.ctimeMs === 'number' && typeof info.mtimeMs === 'number';"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'stat-access-ok' : 'stat-access-bad:' + JSON.stringify({ type: info.type, size: info.size, dev: info.dev, mode: info.mode, uid: info.uid }));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_stat_exists_access.js",
                    @"stat-access-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const lstatInfo = await EJSFS.promises.lstat('broken-link');"
                     " let statRejected = false;"
                     " try { await EJSFS.promises.stat('broken-link'); }"
                     " catch (e) { statRejected = true; }"
                     " const ok = statRejected && lstatInfo.isSymbolicLink() && !lstatInfo.isFile() && !lstatInfo.isDirectory();"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'lstat-ok' : 'lstat-bad');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_lstat_broken_link.js",
                    @"lstat-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const handle = await EJSFS.promises.open('handle.txt', 'w+');"
                     " const written = await handle.write('abcdef', 'utf8');"
                     " await handle.truncate(4);"
                     " await handle.datasync();"
                     " await handle.sync();"
                     " await handle.close();"
                     " const reader = await EJSFS.promises.open('handle.txt', 'r');"
                     " const text = await reader.read({ length: 16, encoding: 'utf8' });"
                     " await reader.close();"
                     " await __ejs_native__.invoke('test', 'report', written === 6 && text === 'abcd' ? 'filehandle-ok' : 'filehandle-bad:' + written + ':' + text);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_filehandle.js",
                    @"filehandle-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.writeFile('link-source.txt', 'link-ok', 'utf8');"
                     " await EJSFS.promises.symlink('link-source.txt', 'link-symbolic');"
                     " const linkTarget = await EJSFS.promises.readLink('link-symbolic');"
                     " const linkInfo = await EJSFS.promises.lstat('link-symbolic');"
                     " const linkText = await EJSFS.promises.readFile('link-symbolic', 'utf8');"
                     " await EJSFS.promises.link('link-source.txt', 'link-hard');"
                     " const hardText = await EJSFS.promises.readFile('link-hard', 'utf8');"
                     " const fsInfo = await EJSFS.promises.statFs('.');"
                     " const ok = linkTarget === 'link-source.txt' && linkInfo.isSymbolicLink() && linkText === 'link-ok' && hardText === 'link-ok' && typeof fsInfo.bsize === 'number' && fsInfo.bsize > 0;"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'link-statfs-ok' : 'link-statfs-bad:' + JSON.stringify({ linkTarget, linkText, hardText, fsInfo }));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_link_statfs.js",
                    @"link-statfs-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const dir = await EJSFS.promises.makeTempDir('phase-');"
                     " const file = await EJSFS.promises.makeTempFile('phase-', { dir });"
                     " await EJSFS.promises.writeFile(file, 'temp-ok', 'utf8');"
                     " const text = await EJSFS.promises.readFile(file, 'utf8');"
                     " await EJSFS.promises.remove(dir, { recursive: true });"
                     " const gone = !(await EJSFS.promises.exists(dir));"
                     " await __ejs_native__.invoke('test', 'report', text === 'temp-ok' && gone ? 'temp-remove-ok' : 'temp-remove-bad:' + dir + ':' + file + ':' + text + ':' + gone);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_temp_remove.js",
                    @"temp-remove-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.writeFile('metadata.txt', 'metadata', 'utf8');"
                     " await EJSFS.promises.chmod('metadata.txt', 0o600);"
                     " await EJSFS.promises.utime('metadata.txt', 1000, 2000);"
                     " const info = await EJSFS.promises.stat('metadata.txt');"
                     " let chownOutcome = 'ok';"
                     " try { await EJSFS.promises.chown('metadata.txt', 0, 0); }"
                     " catch (e) { chownOutcome = e.code === 7 ? 'restricted' : 'bad:' + e.code; }"
                     " const ok = (info.mode & 0o777) === 0o600 && Math.abs(info.mtimeMs - 2000) < 1000 && chownOutcome !== 'bad:undefined' && chownOutcome.indexOf('bad:') !== 0;"
                     " await __ejs_native__.invoke('test', 'report', ok ? 'metadata-ok' : 'metadata-bad:' + JSON.stringify({ mode: info.mode, mtimeMs: info.mtimeMs, chownOutcome }));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_metadata.js",
                    @"metadata-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.access('missing-profile.bin'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', 'access-missing-ok'); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'access-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_access_missing.js",
                    @"access-missing-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const value = await EJSFS.promises.readFile('profile.bin');"
                     " const bytes = Array.prototype.join.call(new Uint8Array(value), ',');"
                     " await __ejs_native__.invoke('test', 'report', 'bytes:' + bytes);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_read_bytes.js",
                    @"bytes:1,2,3",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.copyFile('profile.bin', 'profile-copy.bin');"
                     " const bytes = new Uint8Array(await EJSFS.promises.readFile('profile-copy.bin'));"
                     " await EJSFS.promises.copyFile('profile.bin', 'profile-cache-copy.bin', { newRoot: 'cache', flag: 'wx' });"
                     " const cacheBytes = new Uint8Array(await EJSFS.promises.readFile('profile-cache-copy.bin', { root: 'cache' }));"
                     " try { await EJSFS.promises.copyFile('profile.bin', 'profile-cache-copy.bin', { newRoot: 'cache', flag: 'wx' }); }"
                     " catch (e) {"
                     "   const copied = Array.prototype.join.call(bytes, ',') + ':' + Array.prototype.join.call(cacheBytes, ',');"
                     "   await __ejs_native__.invoke('test', 'report', e.code === 1 ? 'copy:' + copied : 'copy-error:' + e.code);"
                     "   return;"
                     " }"
                     " await __ejs_native__.invoke('test', 'report', 'copy-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_copy_file.js",
                    @"copy:1,2,3:1,2,3",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const entries = await EJSFS.promises.readdir('listdir');"
                     " const aliasEntries = await EJSFS.promises.list('listdir');"
                     " await __ejs_native__.invoke('test', 'report', 'list:' + entries.join(',') + ':' + aliasEntries.join(','));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_readdir.js",
                    @"list:a.txt,b.txt:a.txt,b.txt",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const result = await EJSFS.promises.writeFile('profile.json', '{\"ok\":true}', 'utf8');"
                     " const text = await EJSFS.promises.readFile('profile.json', { encoding: 'utf-8' });"
                     " await __ejs_native__.invoke('test', 'report', result === undefined && text === '{\"ok\":true}' ? 'text-ok' : 'text-bad:' + text);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_write_read_text.js",
                    @"text-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.writeFile('exclusive.txt', 'first', 'utf8');"
                     " await EJSFS.promises.writeFile('exclusive-new.txt', 'seed', { flag: 'wx' });"
                     " try { await EJSFS.promises.writeFile('exclusive.txt', 'second', { flag: 'wx' }); }"
                     " catch (e) {"
                     "   if (e.code !== 1) { await __ejs_native__.invoke('test', 'report', 'write-wx-error:' + e.code); return; }"
                     "   const text = await EJSFS.promises.readFile('exclusive.txt', 'utf8');"
                     "   await __ejs_native__.invoke('test', 'report', text === 'first' ? 'write-wx-protected' : 'write-wx-overwrote');"
                     "   return;"
                     " }"
                     " await __ejs_native__.invoke('test', 'report', 'write-wx-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_write_exclusive.js",
                    @"write-wx-protected",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const source = new Uint8Array([9, 65, 66, 67, 8]);"
                     " await EJSFS.promises.writeFile('slice.bin', source.subarray(1, 4));"
                     " const bytes = new Uint8Array(await EJSFS.promises.readFile('slice.bin'));"
                     " await __ejs_native__.invoke('test', 'report', 'slice:' + Array.prototype.join.call(bytes, ','));"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_write_typed_array_slice.js",
                    @"slice:65,66,67",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.writeFile('cache.txt', 'cache-ok', { root: 'cache', flag: 'w' });"
                     " const text = await EJSFS.promises.readFile('cache.txt', { root: 'cache', encoding: 'utf8' });"
                     " await __ejs_native__.invoke('test', 'report', 'cache:' + text);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_cache_root.js",
                    @"cache:cache-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.writeFile('rename-source.txt', 'rename-ok', 'utf8');"
                     " await EJSFS.promises.writeFile('rename-dest.txt', 'stale', 'utf8');"
                     " await EJSFS.promises.rename('rename-source.txt', 'rename-dest.txt');"
                     " const text = await EJSFS.promises.readFile('rename-dest.txt', 'utf8');"
                     " const sourceExists = await EJSFS.promises.exists('rename-source.txt');"
                     " await __ejs_native__.invoke('test', 'report', text === 'rename-ok' && sourceExists === false ? 'rename:rename-ok' : 'rename-bad:' + text + ':' + sourceExists);"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_rename.js",
                    @"rename:rename-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.writeFile('delete-file.txt', 'delete-ok', 'utf8');"
                     " await EJSFS.promises.unlink('delete-file.txt');"
                     " try { await EJSFS.promises.readFile('delete-file.txt', 'utf8'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', 'unlink-ok'); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'unlink-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_unlink.js",
                    @"unlink-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " await EJSFS.promises.rm('missing-file.txt', { force: true });"
                     " await __ejs_native__.invoke('test', 'report', 'rm-force-ok');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_rm_force.js",
                    @"rm-force-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " let recursiveRejected = false;"
                     " let forceRejected = false;"
                     " try { await EJSFS.promises.rm('missing-recursive.txt', { recursive: 'false' }); }"
                     " catch (e) { recursiveRejected = e instanceof TypeError; }"
                     " try { await EJSFS.promises.rm('missing-force.txt', { force: 'false' }); }"
                     " catch (e) { forceRejected = e instanceof TypeError; }"
                     " await __ejs_native__.invoke('test', 'report', recursiveRejected && forceRejected ? 'rm-bool-option-error' : 'rm-bool-option-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_rm_bool_option.js",
                    @"rm-bool-option-error",
                    &error)) {
      return EXIT_FAILURE;
    }

    NSString *deleteDirectory = [documentsRoot stringByAppendingPathComponent:@"delete-dir"];
    if (![fileManager createDirectoryAtPath:deleteDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error] ||
        ![@"nested" writeToFile:[deleteDirectory stringByAppendingPathComponent:@"nested.txt"]
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:&error]) {
      fprintf(stderr, "failed to seed delete-dir: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.rm('delete-dir'); }"
                     " catch (e) {"
                     "   if (e.code !== 1) { await __ejs_native__.invoke('test', 'report', 'rm-dir-error:' + e.code); return; }"
                     "   await EJSFS.promises.delete('delete-dir', { recursive: true });"
                     "   try { await EJSFS.promises.readdir('delete-dir'); }"
                     "   catch (_) { await __ejs_native__.invoke('test', 'report', 'rm-dir-ok'); return; }"
                     " }"
                     " await __ejs_native__.invoke('test', 'report', 'rm-dir-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_rm_directory.js",
                    @"rm-dir-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.writeFile('bad.txt', 'x', { flag: 'a' }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 6 ? 'flag-unsupported' : 'flag-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'flag-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_unsupported_flag.js",
                    @"flag-unsupported",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await __ejs_native__.invoke('ejs.fs', 'readFile', JSON.stringify({ path: 'profile.bin', encoding: 'latin1' }), null); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 6 ? 'encoding-unsupported' : 'encoding-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'encoding-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_unsupported_encoding.js",
                    @"encoding-unsupported",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const invoke = (method, request, transfer) => __ejs_native__.invoke('ejs.fs', method, JSON.stringify(request), transfer === undefined ? null : transfer);"
                     " const expectReject = async (promise, needle) => {"
                     "   let rejected = false;"
                     "   try { await promise; } catch (e) {"
                     "     rejected = true;"
                     "     if (String(e && (e.message || e)).indexOf(needle) === -1) throw e;"
                     "   }"
                     "   if (!rejected) throw new Error('missing rejection: ' + needle);"
                     " };"
                     " await expectReject(__ejs_native__.invoke('ejs.fs', 'unsupportedMethod', '{}', null), 'Unsupported ejs.fs method');"
                     " await expectReject(__ejs_native__.invoke('ejs.fs', 'readFile', '[]', null), 'JSON object');"
                     " await expectReject(invoke('readFile', { path: '' }), 'fs path is required');"
                     " await expectReject(invoke('readFile', { path: 'profile.bin', root: '' }), 'fs root');"
                     " await expectReject(invoke('readFile', { path: 'profile.bin', root: 'missing' }), 'root is not allowed');"
                     " await expectReject(invoke('writeFile', { path: 'native-missing-transfer.txt' }), 'transfer buffer');"
                     " await expectReject(invoke('access', { path: 'profile.bin', mode: 5 }), 'Unsupported fs access mode');"
                     " await expectReject(invoke('access', { path: 'profile.bin', mode: 'execute' }), 'Unsupported fs access mode');"
                     " await invoke('access', { path: 'profile.bin', mode: 'r-w' });"
                     " await __ejs_native__.invoke('test', 'report', 'native-errors-ok');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_native_errors.js",
                    @"native-errors-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const text = (value) => typeof value === 'string' ? value : String.fromCharCode.apply(null, new Uint8Array(value));"
                     " const parse = async (promise) => JSON.parse(text(await promise));"
                     " const invoke = (method, request, transfer) => __ejs_native__.invoke('ejs.fs', method, JSON.stringify(request), transfer === undefined ? null : transfer);"
                     " const expectReject = async (promise, needle) => {"
                     "   let rejected = false;"
                     "   try { await promise; } catch (e) {"
                     "     rejected = true;"
                     "     if (String(e && (e.message || e)).indexOf(needle) === -1) throw e;"
                     "   }"
                     "   if (!rejected) throw new Error('missing rejection: ' + needle);"
                     " };"
                     " const reader = (await parse(invoke('open', { path: 'profile.bin', flags: 'r' }))).handle;"
                     " await expectReject(invoke('fileHandleWrite', { handle: reader }, new Uint8Array([1]).buffer), 'not writable');"
                     " await expectReject(invoke('fileHandleRead', { handle: reader, length: -1 }), 'non-negative');"
                     " const empty = await invoke('fileHandleRead', { handle: reader, length: 0 });"
                     " if (new Uint8Array(empty).length !== 0) throw new Error('zero-length read returned data');"
                     " await expectReject(invoke('fileHandleTruncate', { handle: reader, length: 1 }), 'not writable');"
                     " await invoke('fileHandleClose', { handle: reader });"
                     " await expectReject(invoke('fileHandleClose', { handle: reader }), 'closed or unknown');"
                     " const writer = (await parse(invoke('open', { path: 'native-open.txt', flags: 'w' }))).handle;"
                     " await expectReject(invoke('fileHandleRead', { handle: writer, length: 1 }), 'not readable');"
                     " await expectReject(invoke('fileHandleWrite', { handle: writer }), 'transfer buffer');"
                     " await expectReject(invoke('fileHandleTruncate', { handle: writer, length: -1 }), 'non-negative');"
                     " await expectReject(invoke('fileHandleTruncate', { handle: writer, length: 2048 }), 'maxWriteBytes');"
                     " await invoke('fileHandleWrite', { handle: writer, position: 0 }, new Uint8Array([65,66]).buffer);"
                     " await invoke('fileHandleClose', { handle: writer });"
                     " await expectReject(invoke('open', { path: 'missing-open.txt', flags: 'r' }), 'Failed to open file');"
                     " await expectReject(invoke('open', { path: 'bad-open.txt', flags: '' }), 'non-empty string');"
                     " await __ejs_native__.invoke('test', 'report', 'filehandle-errors-ok');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_filehandle_errors.js",
                    @"filehandle-errors-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " const invoke = (method, request, transfer) => __ejs_native__.invoke('ejs.fs', method, JSON.stringify(request), transfer === undefined ? null : transfer);"
                     " const expectReject = async (promise, needle) => {"
                     "   let rejected = false;"
                     "   try { await promise; } catch (e) {"
                     "     rejected = true;"
                     "     if (String(e && (e.message || e)).indexOf(needle) === -1) throw e;"
                     "   }"
                     "   if (!rejected) throw new Error('missing rejection: ' + needle);"
                     " };"
                     " await invoke('mkdir', { path: 'made/child', recursive: true });"
                     " await expectReject(invoke('mkdir', { path: 'made/child' }), 'already exists');"
                     " await EJSFS.promises.writeFile('copy-source.txt', 'copy-source', 'utf8');"
                     " await EJSFS.promises.writeFile('copy-existing.txt', 'existing', 'utf8');"
                     " await expectReject(invoke('copyFile', { path: 'copy-source.txt', newPath: 'copy-existing.txt', flag: 'wx' }), 'Destination already exists');"
                     " await expectReject(invoke('copyFile', { path: 'copy-source.txt', newPath: 'copy-target.txt', flag: 'ax' }), 'Unsupported fs copy flag');"
                     " await expectReject(invoke('copyFile', { path: 'missing-copy.txt', newPath: 'copy-target.txt' }), 'missing-copy.txt');"
                     " await expectReject(invoke('copyFile', { path: 'made', newPath: 'copy-dir-source.txt' }), 'source must be a file');"
                     " await EJSFS.promises.mkdir('copy-dir-dest');"
                     " await expectReject(invoke('copyFile', { path: 'copy-source.txt', newPath: 'copy-dir-dest' }), 'Destination is a directory');"
                     " await expectReject(invoke('readLink', { path: 'profile.bin' }), 'profile.bin');"
                     " await expectReject(invoke('symlink', { path: 'bad-symlink' }), 'target is required');"
                     " await expectReject(invoke('symlink', { path: 'escape-symlink', target: '../outside.txt' }), 'may not escape');"
                     " await expectReject(invoke('makeTempFile', { prefix: '' }), 'temp prefix');"
                     " await expectReject(invoke('makeTempDir', { prefix: 'bad/name' }), 'temp prefix');"
                     " await expectReject(invoke('chmod', { path: 'metadata.txt' }), 'mode is required');"
                     " await expectReject(invoke('lchown', { path: 'link-symbolic' }), 'uid and gid');"
                     " await invoke('lutime', { path: 'link-symbolic', atimeMs: 3000, mtimeMs: 4000 });"
                     " await expectReject(invoke('utime', { path: 'metadata.txt' }), 'atimeMs and mtimeMs');"
                     " await expectReject(invoke('rename', { path: 'missing-rename.txt', newPath: 'missing-rename-out.txt' }), 'Failed to rename path');"
                     " await expectReject(invoke('delete', { path: 'missing-delete.txt' }), 'Path does not exist');"
                     " await expectReject(invoke('statFs', { path: 'missing-statfs.txt' }), 'Failed to stat file system');"
                     " await __ejs_native__.invoke('test', 'report', 'metadata-errors-ok');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_metadata_errors.js",
                    @"metadata-errors-ok",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (![@"readonly" writeToFile:[readOnlyRoot stringByAppendingPathComponent:@"locked.txt"]
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&error]) {
      fprintf(stderr, "failed to seed read-only locked file: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.writeFile('nope.txt', 'x', { root: 'readOnly' }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'readonly-security' : 'readonly-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'readonly-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_readonly_write.js",
                    @"readonly-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.access('locked.txt', { root: 'readOnly', mode: 'write' }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'readonly-access-security' : 'readonly-access-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'readonly-access-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_readonly_access.js",
                    @"readonly-access-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.copyFile('profile.bin', 'copy-denied.bin', { newRoot: 'readOnly' }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'readonly-copy-security' : 'readonly-copy-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'readonly-copy-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_readonly_copy.js",
                    @"readonly-copy-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.unlink('locked.txt', { root: 'readOnly' }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'readonly-delete-security' : 'readonly-delete-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'readonly-delete-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_readonly_delete.js",
                    @"readonly-delete-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.mkdir('new-dir', { root: 'readOnly' }); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'readonly-mkdir-security' : 'readonly-mkdir-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'readonly-mkdir-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_readonly_mkdir.js",
                    @"readonly-mkdir-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.readFile('../escape.txt'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'parent-security' : 'parent-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'parent-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_parent_escape.js",
                    @"parent-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    NSString *secretPath = [outsideRoot stringByAppendingPathComponent:@"secret.txt"];
    if (![@"secret" writeToFile:secretPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
      fprintf(stderr, "failed to write symlink target: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    NSString *symlinkPath = [documentsRoot stringByAppendingPathComponent:@"link"];
    if (![fileManager createSymbolicLinkAtPath:symlinkPath withDestinationPath:outsideRoot error:&error]) {
      fprintf(stderr, "failed to create symlink: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(context,
                    reportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.readFile('link/secret.txt', 'utf8'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'symlink-security' : 'symlink-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'symlink-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_symlink_escape.js",
                    @"symlink-security",
                    &error)) {
      return EXIT_FAILURE;
    }

    NSString *smallConfig = fs_json(documentsRoot, cacheRoot, readOnlyRoot, 4, 4);
    EJSContextConfiguration *smallContextConfig = [[EJSContextConfiguration alloc] init];
    smallContextConfig.values = @{
      EJSFileSystemConfigurationKey: smallConfig
    };
    EJSContext *smallContext = [runtime createContextWithID:@"app://tests/fs-small"
                                              configuration:smallContextConfig
                                                      error:&error];
    if (smallContext == nil) {
      fprintf(stderr, "failed to create small-limit context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    TestReportProvider *smallReportProvider = [[TestReportProvider alloc] init];
    if (![smallContext registerProvider:smallReportProvider error:&error] ||
        !EJSFileSystemInstallIntoContext(smallContext, &error)) {
      fprintf(stderr, "failed to install small-limit EJSFS: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(smallContext,
                    smallReportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.writeFile('too-large.txt', '12345'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'write-limit' : 'write-limit-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'write-limit-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_write_limit.js",
                    @"write-limit",
                    &error)) {
      return EXIT_FAILURE;
    }

    NSData *largeData = [NSData dataWithBytes:(const uint8_t[]){ 1, 2, 3, 4, 5 } length:5];
    if (![largeData writeToFile:[documentsRoot stringByAppendingPathComponent:@"too-large-read.bin"]
                        options:0
                          error:&error]) {
      fprintf(stderr, "failed to seed too-large-read.bin: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    if (!run_script(smallContext,
                    smallReportProvider,
                    @"(async function(){"
                     " try { await EJSFS.promises.readFile('too-large-read.bin'); }"
                     " catch (e) { await __ejs_native__.invoke('test', 'report', e.code === 7 ? 'read-limit' : 'read-limit-error:' + e.code); return; }"
                     " await __ejs_native__.invoke('test', 'report', 'read-limit-missing-error');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_read_limit.js",
                    @"read-limit",
                    &error)) {
      return EXIT_FAILURE;
    }

    EJSRuntime *missingConfigRuntime = [[EJSRuntime alloc] init];
    EJSContext *missingConfigContext = [missingConfigRuntime createContextWithID:@"app://tests/fs-missing-config"
                                                                          error:&error];
    NSError *missingConfigError = nil;
    if (EJSFileSystemInstallIntoContext(missingConfigContext, &missingConfigError) ||
        missingConfigError.code != EJSRuntimeErrorCodeInvalidArgument) {
      fprintf(stderr, "missing fs config should fail install with invalid argument\n");
      return EXIT_FAILURE;
    }
    [missingConfigRuntime invalidate];

#ifdef EJS_TEST
    EJSRuntime *rollbackRuntime = nil;
    EJSContext *rollbackContext = make_context(@"app://tests/fs-install-rollback", config, &rollbackRuntime, &error);
    if (rollbackContext == nil) {
      fprintf(stderr, "failed to create fs rollback context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    TestReportProvider *rollbackReportProvider = [[TestReportProvider alloc] init];
    if (![rollbackContext registerProvider:rollbackReportProvider error:&error]) {
      fprintf(stderr, "failed to register fs rollback report provider: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    if (![rollbackContext evaluateScript:
          @"Object.defineProperty(globalThis, 'EJSFS', { value: { marker: 'pre-fs' }, configurable: true, writable: false, enumerable: false });"
                         filename:@"fs_rollback_setup.js"
                            error:&error]) {
      fprintf(stderr, "failed to setup fs rollback global: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }

    EJSFileSystemAppleTestSetInstallFailScriptIndex(0);
    NSError *rollbackInstallError = nil;
    BOOL rollbackInstallResult = EJSFileSystemInstallIntoContext(rollbackContext, &rollbackInstallError);
    EJSFileSystemAppleTestSetInstallFailScriptIndex(-1);
    if (rollbackInstallResult || rollbackInstallError == nil ||
        [rollbackInstallError.localizedDescription containsString:@"sentinel"] == NO) {
      fprintf(stderr, "fs rollback install should fail with sentinel error\n");
      return EXIT_FAILURE;
    }

    if (!run_script(rollbackContext,
                    rollbackReportProvider,
                    @"(async function(){"
                     " const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'EJSFS');"
                     " if (!descriptor || descriptor.enumerable !== false || descriptor.writable !== false || !descriptor.value || descriptor.value.marker !== 'pre-fs') throw new Error('fs descriptor rollback mismatch');"
                     " let providerRolledBack = false;"
                     " try {"
                     "   await __ejs_native__.invoke('ejs.fs', 'exists', JSON.stringify({ path: 'profile.bin' }), null);"
                     " } catch (error) {"
                     "   providerRolledBack = true;"
                     " }"
                     " if (!providerRolledBack) throw new Error('fs provider rollback missing');"
                     " await __ejs_native__.invoke('test', 'report', 'fs:install-rollback');"
                     "})().catch(e => __ejs_native__.invoke('test', 'report', 'error:' + e.message));",
                    @"fs_install_rollback.js",
                    @"fs:install-rollback",
                    &error)) {
      return EXIT_FAILURE;
    }
    [rollbackRuntime invalidate];
#endif

#ifdef EJS_TEST
    NSError *internalCoverageError = nil;
    if (!EJSFileSystemAppleTestExerciseInternalCoverage(base, &internalCoverageError)) {
      fprintf(stderr, "fs internal coverage helper failed: %s\n", internalCoverageError.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
#endif

    EJSContext *invalidatedContext = [runtime createContextWithID:@"app://tests/fs-invalidated" error:&error];
    if (invalidatedContext == nil) {
      fprintf(stderr, "failed to create invalidated fs context: %s\n", error.localizedDescription.UTF8String);
      return EXIT_FAILURE;
    }
    [invalidatedContext invalidate];
    NSError *invalidatedError = nil;
    if (EJSFileSystemInstallIntoContext(invalidatedContext, &invalidatedError) ||
        invalidatedError.code != EJSRuntimeErrorCodeInvalidated) {
      fprintf(stderr, "invalidated fs context should reject install with invalidated error\n");
      return EXIT_FAILURE;
    }

    [runtime invalidate];
    [fileManager removeItemAtPath:base error:nil];
  }

  printf("ejs_fs_apple_test PASS\n");
  return EXIT_SUCCESS;
}
