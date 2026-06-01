#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>

#import "EJSApplePlatform.h"
#import "EJSPackageApple.h"

static NSString * const TestPackageID = @"npm:ejs-package-test@1.0.0";
static NSString * const TestIndexSpecifier = @"ejs-pkg://npm/ejs-package-test@1.0.0/modules/index.js";
static NSString * const TestDepSpecifier = @"ejs-pkg://npm/ejs-package-test@1.0.0/modules/dep.js";

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

static NSString * sha256_hex_for_data(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

  NSMutableString *hex = [[NSMutableString alloc] initWithCapacity:CC_SHA256_DIGEST_LENGTH * 2u];
  for (NSUInteger index = 0u; index < CC_SHA256_DIGEST_LENGTH; ++index) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return [hex copy];
}

static NSString * sha256_hex_for_string(NSString *value) {
  return sha256_hex_for_data([value dataUsingEncoding:NSUTF8StringEncoding]);
}

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

static NSURL * make_temp_dir(NSString *name, NSError **error) {
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"ejs-package-test-%@-%@", name, [NSUUID UUID].UUIDString]];
  NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
  if (![[NSFileManager defaultManager] createDirectoryAtURL:url
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
    return nil;
  }
  return url;
}

static BOOL write_string(NSURL *url, NSString *value, NSError **error) {
  NSURL *directoryURL = [url URLByDeletingLastPathComponent];
  if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
    return NO;
  }
  return [value writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static BOOL write_json(NSURL *url, id object, NSError **error) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:error];
  if (data == nil) {
    return NO;
  }
  NSURL *directoryURL = [url URLByDeletingLastPathComponent];
  if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
    return NO;
  }
  return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

static NSDictionary * default_capabilities(void) {
  return @{
    @"filesystem": @"none",
    @"network": @"none",
    @"process": @"none",
    @"native": @"none",
    @"dynamicCode": @"none"
  };
}

static NSDictionary * default_policy(void) {
  return @{
    @"requiresApproval": @YES,
    @"allowDynamicImport": @NO,
    @"allowEval": @NO
  };
}

static NSDictionary * manifest_with_modules(NSDictionary *modules,
                                            NSDictionary *capabilities,
                                            NSDictionary *policy,
                                            NSString *packageSHA256) {
  return @{
    @"format": @1,
    @"packageId": TestPackageID,
    @"entry": TestIndexSpecifier,
    @"modules": modules,
    @"capabilities": capabilities,
    @"policy": policy,
    @"packageSha256": packageSHA256,
    @"signature": [NSNull null]
  };
}

static BOOL create_valid_package(NSString *name,
                                 NSURL **packageURLOut,
                                 NSURL **approvalURLOut,
                                 NSString **packageSHA256Out,
                                 NSError **error) {
  NSURL *rootURL = make_temp_dir(name, error);
  if (rootURL == nil) {
    return NO;
  }

  NSString *indexSource = @"import { suffix } from './dep.js'; export const message = 'package:' + suffix;";
  NSString *depSource = @"export const suffix = 'ok';";
  if (!write_string([rootURL URLByAppendingPathComponent:@"modules/index.js"], indexSource, error) ||
      !write_string([rootURL URLByAppendingPathComponent:@"modules/dep.js"], depSource, error)) {
    return NO;
  }

  NSString *packageSHA256 = [@"sha256-" stringByAppendingString:sha256_hex_for_string([indexSource stringByAppendingString:depSource])];
  NSDictionary *manifest = manifest_with_modules(@{
    TestIndexSpecifier: @{
      @"path": @"modules/index.js",
      @"sha256": sha256_hex_for_string(indexSource),
      @"format": @"esm"
    },
    TestDepSpecifier: @{
      @"path": @"modules/dep.js",
      @"sha256": sha256_hex_for_string(depSource),
      @"format": @"esm"
    }
  }, default_capabilities(), default_policy(), packageSHA256);
  if (!write_json([rootURL URLByAppendingPathComponent:@"ejs-package.json"], manifest, error)) {
    return NO;
  }

  NSURL *approvalURL = [rootURL URLByAppendingPathComponent:@"approval.json"];
  NSDictionary *approvalManifest = @{
    @"format": @1,
    @"approvedPackages": @[
      @{
        @"packageId": TestPackageID,
        @"manifestSha256": @"",
        @"packageSha256": packageSHA256
      }
    ]
  };
  if (!write_json(approvalURL, approvalManifest, error)) {
    return NO;
  }

  if (packageURLOut != NULL) {
    *packageURLOut = rootURL;
  }
  if (approvalURLOut != NULL) {
    *approvalURLOut = approvalURL;
  }
  if (packageSHA256Out != NULL) {
    *packageSHA256Out = packageSHA256;
  }
  return YES;
}

static EJSContext * make_context(NSString *contextID, NSError **error) {
  EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
  configuration.runtimeName = @"ejs_package_apple_test";
  EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
  return [runtime createContextWithID:contextID error:error];
}

static BOOL expect_valid_package_installs_and_imports(void) {
  NSError *error = nil;
  NSURL *packageURL = nil;
  NSURL *approvalURL = nil;
  if (!create_valid_package(@"valid", &packageURL, &approvalURL, NULL, &error)) {
    fprintf(stderr, "failed to create valid package fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/valid", &error);
  if (context == nil) {
    fprintf(stderr, "failed to create package context: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
  if (![context registerProvider:reportProvider error:&error]) {
    fprintf(stderr, "failed to register package test provider: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
  options.approvalManifestURL = approvalURL;
  if (!EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
    fprintf(stderr, "failed to install valid package: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  NSString *script = [NSString stringWithFormat:
      @"import { message } from '%@';"
       "__ejs_native__.invoke('test', 'report', message);",
      TestIndexSpecifier];
  if (![context evaluateModule:script
                     specifier:@"package_valid_test"
                     sourceURL:@"app://tests/package/valid.mjs"
                         error:&error] ||
      !wait_for_report(reportProvider, @"package:ok")) {
    fprintf(stderr, "valid package import failed: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  return YES;
}

static BOOL expect_missing_approval_rejected(void) {
  NSError *error = nil;
  NSURL *packageURL = nil;
  if (!create_valid_package(@"missing-approval", &packageURL, NULL, NULL, &error)) {
    fprintf(stderr, "failed to create missing-approval package fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/missing-approval", &error);
  EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
  error = nil;
  if (EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
    fprintf(stderr, "package installer unexpectedly accepted missing approval\n");
    return NO;
  }
  if (![error.domain isEqualToString:EJSPackageErrorDomain] ||
      error.code != EJSPackageErrorCodeApprovalMissing) {
    fprintf(stderr, "unexpected missing approval error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_hash_mismatch_rejected(void) {
  NSError *error = nil;
  NSURL *packageURL = nil;
  NSURL *approvalURL = nil;
  if (!create_valid_package(@"hash-mismatch", &packageURL, &approvalURL, NULL, &error)) {
    fprintf(stderr, "failed to create hash-mismatch package fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  if (!write_string([packageURL URLByAppendingPathComponent:@"modules/dep.js"], @"export const suffix = 'tampered';", &error)) {
    fprintf(stderr, "failed to tamper package fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/hash-mismatch", &error);
  EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
  options.approvalManifestURL = approvalURL;
  error = nil;
  if (EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
    fprintf(stderr, "package installer unexpectedly accepted a tampered module\n");
    return NO;
  }
  if (![error.domain isEqualToString:EJSPackageErrorDomain] ||
      error.code != EJSPackageErrorCodeHashMismatch) {
    fprintf(stderr, "unexpected hash mismatch error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_expected_package_hash_mismatch_rejected(void) {
  NSError *error = nil;
  NSURL *packageURL = nil;
  NSURL *approvalURL = nil;
  if (!create_valid_package(@"package-hash-mismatch", &packageURL, &approvalURL, NULL, &error)) {
    fprintf(stderr, "failed to create package-hash-mismatch fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/package-hash-mismatch", &error);
  EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
  options.approvalManifestURL = approvalURL;
  options.expectedPackageSHA256 = @"sha256-0000000000000000000000000000000000000000000000000000000000000000";
  error = nil;
  if (EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
    fprintf(stderr, "package installer unexpectedly accepted the wrong expected package hash\n");
    return NO;
  }
  if (![error.domain isEqualToString:EJSPackageErrorDomain] ||
      error.code != EJSPackageErrorCodeHashMismatch) {
    fprintf(stderr, "unexpected package hash mismatch error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_unsupported_capability_rejected(void) {
  NSError *error = nil;
  NSURL *packageURL = nil;
  NSURL *approvalURL = nil;
  NSString *packageSHA256 = nil;
  if (!create_valid_package(@"unsupported-capability", &packageURL, &approvalURL, &packageSHA256, &error)) {
    fprintf(stderr, "failed to create unsupported-capability fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  NSString *indexSource = @"export const message = 'capability';";
  NSDictionary *manifest = manifest_with_modules(@{
    TestIndexSpecifier: @{
      @"path": @"modules/index.js",
      @"sha256": sha256_hex_for_string(indexSource),
      @"format": @"esm"
    }
  }, @{
    @"filesystem": @"none",
    @"network": @"required",
    @"process": @"none",
    @"native": @"none",
    @"dynamicCode": @"none"
  }, default_policy(), packageSHA256);
  if (!write_string([packageURL URLByAppendingPathComponent:@"modules/index.js"], indexSource, &error) ||
      !write_json([packageURL URLByAppendingPathComponent:@"ejs-package.json"], manifest, &error)) {
    fprintf(stderr, "failed to rewrite unsupported-capability fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/unsupported-capability", &error);
  EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
  options.approvalManifestURL = approvalURL;
  error = nil;
  if (EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
    fprintf(stderr, "package installer unexpectedly accepted unsupported capability\n");
    return NO;
  }
  if (![error.domain isEqualToString:EJSPackageErrorDomain] ||
      error.code != EJSPackageErrorCodeSecurity) {
    fprintf(stderr, "unexpected unsupported capability error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_malformed_manifest_rejected(void) {
  NSError *error = nil;
  NSURL *packageURL = make_temp_dir(@"malformed", &error);
  if (packageURL == nil ||
      !write_json([packageURL URLByAppendingPathComponent:@"ejs-package.json"], @{ @"format": @1 }, &error)) {
    fprintf(stderr, "failed to create malformed fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/malformed", &error);
  error = nil;
  if (EJSPackageInstallIntoContext(context, packageURL, [[EJSPackageInstallOptions alloc] init], &error)) {
    fprintf(stderr, "package installer unexpectedly accepted malformed manifest\n");
    return NO;
  }
  if (![error.domain isEqualToString:EJSPackageErrorDomain] ||
      error.code != EJSPackageErrorCodeMalformed) {
    fprintf(stderr, "unexpected malformed manifest error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

static BOOL expect_path_traversal_rejected(void) {
  NSError *error = nil;
  NSURL *packageURL = nil;
  NSURL *approvalURL = nil;
  NSString *packageSHA256 = nil;
  if (!create_valid_package(@"path-traversal", &packageURL, &approvalURL, &packageSHA256, &error)) {
    fprintf(stderr, "failed to create path-traversal fixture: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  NSString *indexSource = @"export const message = 'escape';";
  NSDictionary *manifest = manifest_with_modules(@{
    TestIndexSpecifier: @{
      @"path": @"../escape.js",
      @"sha256": sha256_hex_for_string(indexSource),
      @"format": @"esm"
    }
  }, default_capabilities(), default_policy(), packageSHA256);
  if (!write_json([packageURL URLByAppendingPathComponent:@"ejs-package.json"], manifest, &error)) {
    fprintf(stderr, "failed to rewrite path-traversal manifest: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }

  EJSContext *context = make_context(@"app://tests/package/path-traversal", &error);
  EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
  options.approvalManifestURL = approvalURL;
  error = nil;
  if (EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
    fprintf(stderr, "package installer unexpectedly accepted path traversal\n");
    return NO;
  }
  if (![error.domain isEqualToString:EJSPackageErrorDomain] ||
      error.code != EJSPackageErrorCodeSecurity) {
    fprintf(stderr, "unexpected path traversal error: %s\n", error.localizedDescription.UTF8String);
    return NO;
  }
  return YES;
}

int main(void) {
  @autoreleasepool {
    if (!expect_valid_package_installs_and_imports() ||
        !expect_missing_approval_rejected() ||
        !expect_hash_mismatch_rejected() ||
        !expect_expected_package_hash_mismatch_rejected() ||
        !expect_unsupported_capability_rejected() ||
        !expect_malformed_manifest_rejected() ||
        !expect_path_traversal_rejected()) {
      return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
  }
}
