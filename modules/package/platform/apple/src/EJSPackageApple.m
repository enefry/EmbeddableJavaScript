#import "EJSPackageApple.h"

#import <CommonCrypto/CommonDigest.h>

NSErrorDomain const EJSPackageErrorDomain = @"EJSPackageErrorDomain";

static NSString * const EJSPackageManifestFileName = @"ejs-package.json";

static NSError * EJSPackageMakeError(EJSPackageErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};

    return [NSError errorWithDomain:EJSPackageErrorDomain code:code userInfo:userInfo];
}

static BOOL EJSPackageFail(NSError **error, EJSPackageErrorCode code, NSString *message) {
    if (error != NULL) {
        *error = EJSPackageMakeError(code, message);
    }

    return NO;
}

static NSString * EJSPackageSHA256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [[NSMutableString alloc] initWithCapacity:CC_SHA256_DIGEST_LENGTH * 2u];
    for (NSUInteger index = 0u; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        [hex appendFormat:@"%02x", digest[index]];
    }

    return [hex copy];
}

static NSString * EJSPackageNormalizedHash(NSString *hash) {
    if (![hash isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *trimmed = [[hash stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    if (trimmed.length == 0) {
        return nil;
    }

    if ([trimmed hasPrefix:@"sha256-"]) {
        return trimmed;
    }

    if (trimmed.length == 64u) {
        NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if ([[trimmed stringByTrimmingCharactersInSet:hexSet] length] == 0u) {
            return [@"sha256-" stringByAppendingString:trimmed];
        }
    }

    return trimmed;
}

static NSString * EJSPackageRawSHA256(NSString *hash) {
    NSString *normalized = EJSPackageNormalizedHash(hash);
    if ([normalized hasPrefix:@"sha256-"] && normalized.length > 7u) {
        return [normalized substringFromIndex:7u];
    }

    return normalized;
}

static NSString * EJSPackageString(NSDictionary<NSString *, id> *dictionary, NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSDictionary<NSString *, id> * EJSPackageDictionary(NSDictionary<NSString *, id> *dictionary, NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static BOOL EJSPackageBoolean(NSDictionary<NSString *, id> *dictionary, NSString *key, BOOL defaultValue) {
    id value = dictionary[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : defaultValue;
}

static BOOL EJSPackagePathContainsNUL(NSString *path) {
    return [path rangeOfString:[NSString stringWithFormat:@"%C", 0]].location != NSNotFound;
}

static NSURL * EJSPackageResolveModuleURL(NSURL *packageURL, NSString *modulePath, NSString *packageRootPath, NSError **error) {
    if (modulePath.length == 0 ||
        [modulePath isAbsolutePath] ||
        EJSPackagePathContainsNUL(modulePath)) {
        EJSPackageFail(error, EJSPackageErrorCodeSecurity, @"Package module path is not relative");
        return nil;
    }

    for (NSString *component in [modulePath pathComponents]) {
        if ([component isEqualToString:@".."]) {
            EJSPackageFail(error, EJSPackageErrorCodeSecurity, @"Package module path escapes package root");
            return nil;
        }
    }

    NSURL *candidateURL = [packageURL URLByAppendingPathComponent:modulePath isDirectory:NO];
    NSString *resolvedPath = candidateURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *rootPrefix = [packageRootPath stringByAppendingString:@"/"];

    if (resolvedPath.length == 0 ||
        [resolvedPath isEqualToString:packageRootPath] ||
        ![resolvedPath hasPrefix:rootPrefix]) {
        EJSPackageFail(error, EJSPackageErrorCodeSecurity, @"Package module path escapes package root");
        return nil;
    }

    return [NSURL fileURLWithPath:resolvedPath isDirectory:NO];
}

static BOOL EJSPackageVerifyCapabilities(NSDictionary<NSString *, id> *manifest,
                                         EJSPackageInstallOptions *options,
                                         NSError **error) {
    NSDictionary<NSString *, id> *capabilities = EJSPackageDictionary(manifest, @"capabilities");
    if (capabilities == nil) {
        return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package manifest is missing capabilities");
    }

    for (NSString *capability in capabilities) {
        id value = capabilities[capability];
        if (![value isKindOfClass:[NSString class]]) {
            return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package capability values must be strings");
        }

        if (![value isEqualToString:@"none"] &&
            ![options.allowedCapabilities containsObject:capability]) {
            return EJSPackageFail(error,
                                  EJSPackageErrorCodeSecurity,
                                  [NSString stringWithFormat:@"Unsupported package capability: %@", capability]);
        }
    }

    NSDictionary<NSString *, id> *policy = EJSPackageDictionary(manifest, @"policy");
    if (policy == nil) {
        return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package manifest is missing policy");
    }

    if (EJSPackageBoolean(policy, @"allowDynamicImport", NO) && !options.allowDynamicImport) {
        return EJSPackageFail(error, EJSPackageErrorCodeSecurity, @"Package dynamic import is not allowed");
    }

    if (EJSPackageBoolean(policy, @"allowEval", NO) &&
        ![options.allowedCapabilities containsObject:@"dynamicCode"]) {
        return EJSPackageFail(error, EJSPackageErrorCodeSecurity, @"Package eval is not allowed");
    }

    return YES;
}

static BOOL EJSPackageApprovalEntryMatches(NSDictionary<NSString *, id> *entry,
                                           NSString *packageID,
                                           NSString *manifestSHA256,
                                           NSString *packageSHA256) {
    NSString *entryPackageID = EJSPackageString(entry, @"packageId");
    if (entryPackageID.length > 0 && ![entryPackageID isEqualToString:packageID]) {
        return NO;
    }

    NSString *entryManifestSHA256 = EJSPackageNormalizedHash(EJSPackageString(entry, @"manifestSha256"));
    NSString *entryPackageSHA256 = EJSPackageNormalizedHash(EJSPackageString(entry, @"packageSha256"));
    return (entryManifestSHA256.length > 0 && [entryManifestSHA256 isEqualToString:manifestSHA256]) ||
        (entryPackageSHA256.length > 0 && [entryPackageSHA256 isEqualToString:packageSHA256]);
}

static BOOL EJSPackageApprovalManifestMatches(NSURL *approvalURL,
                                              NSString *packageID,
                                              NSString *manifestSHA256,
                                              NSString *packageSHA256,
                                              NSError **error) {
    if (approvalURL == nil) {
        return NO;
    }

    NSData *approvalData = [NSData dataWithContentsOfURL:approvalURL options:0 error:error];
    if (approvalData == nil) {
        return NO;
    }

    id root = [NSJSONSerialization JSONObjectWithData:approvalData options:0 error:error];
    if (![root isKindOfClass:[NSDictionary class]]) {
        EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Approval manifest must be a JSON object");
        return NO;
    }

    id approvedPackages = root[@"approvedPackages"];
    if (![approvedPackages isKindOfClass:[NSArray class]]) {
        EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Approval manifest is missing approvedPackages");
        return NO;
    }

    for (id entry in approvedPackages) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        if (EJSPackageApprovalEntryMatches(entry, packageID, manifestSHA256, packageSHA256)) {
            return YES;
        }
    }

    return NO;
}

static BOOL EJSPackageVerifyApproval(EJSPackageInstallOptions *options,
                                     NSString *packageID,
                                     NSString *manifestSHA256,
                                     NSString *packageSHA256,
                                     NSError **error) {
    if (packageSHA256.length == 0) {
        return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package manifest is missing packageSha256");
    }

    NSString *expectedPackageSHA256 = EJSPackageNormalizedHash(options.expectedPackageSHA256);
    if (expectedPackageSHA256.length > 0 && ![expectedPackageSHA256 isEqualToString:packageSHA256]) {
        return EJSPackageFail(error, EJSPackageErrorCodeHashMismatch, @"Package hash does not match expected hash");
    }

    if ([options.approvedPackageSHA256Values containsObject:packageSHA256] ||
        [options.approvedManifestSHA256Values containsObject:manifestSHA256]) {
        return YES;
    }

    NSError *approvalError = nil;
    if (EJSPackageApprovalManifestMatches(options.approvalManifestURL,
                                          packageID,
                                          manifestSHA256,
                                          packageSHA256,
                                          &approvalError)) {
        return YES;
    }

    if (approvalError != nil) {
        if (error != NULL) {
            *error = approvalError;
        }
        return NO;
    }

    return EJSPackageFail(error,
                          EJSPackageErrorCodeApprovalMissing,
                          [NSString stringWithFormat:@"Package approval missing for %@", packageID]);
}

@implementation EJSPackageInstallOptions

- (instancetype)init {
    self = [super init];

    if (self == nil) {
        return nil;
    }

    _approvedManifestSHA256Values = [NSSet set];
    _approvedPackageSHA256Values = [NSSet set];
    _allowedCapabilities = [NSSet set];
    _allowDynamicImport = NO;
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    EJSPackageInstallOptions *copy = [[[self class] allocWithZone:zone] init];
    copy.approvalManifestURL = self.approvalManifestURL;
    copy.expectedPackageSHA256 = self.expectedPackageSHA256;
    copy.approvedManifestSHA256Values = self.approvedManifestSHA256Values;
    copy.approvedPackageSHA256Values = self.approvedPackageSHA256Values;
    copy.allowedCapabilities = self.allowedCapabilities;
    copy.allowDynamicImport = self.allowDynamicImport;
    return copy;
}

- (void)setApprovedManifestSHA256Values:(NSSet<NSString *> *)approvedManifestSHA256Values {
    NSMutableSet<NSString *> *normalized = [[NSMutableSet alloc] init];
    for (NSString *hash in approvedManifestSHA256Values) {
        NSString *value = EJSPackageNormalizedHash(hash);
        if (value.length > 0) {
            [normalized addObject:value];
        }
    }
    _approvedManifestSHA256Values = [normalized copy];
}

- (void)setApprovedPackageSHA256Values:(NSSet<NSString *> *)approvedPackageSHA256Values {
    NSMutableSet<NSString *> *normalized = [[NSMutableSet alloc] init];
    for (NSString *hash in approvedPackageSHA256Values) {
        NSString *value = EJSPackageNormalizedHash(hash);
        if (value.length > 0) {
            [normalized addObject:value];
        }
    }
    _approvedPackageSHA256Values = [normalized copy];
}

- (void)setAllowedCapabilities:(NSSet<NSString *> *)allowedCapabilities {
    _allowedCapabilities = [allowedCapabilities copy] ?: [NSSet set];
}

@end

BOOL EJSPackageInstallIntoContext(EJSContext *context,
                                  NSURL *packageURL,
                                  EJSPackageInstallOptions *options,
                                  NSError **error) {
    if (context == nil || packageURL == nil) {
        return EJSPackageFail(error, EJSPackageErrorCodeInvalidArgument, @"Context and packageURL are required");
    }

    if (!packageURL.isFileURL) {
        return EJSPackageFail(error, EJSPackageErrorCodeUnsupported, @"Only file URL packages are supported");
    }

    if (options == nil) {
        options = [[EJSPackageInstallOptions alloc] init];
    } else {
        options = [options copy];
    }

    NSNumber *isDirectory = nil;
    NSError *resourceError = nil;
    if (![packageURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&resourceError] ||
        !isDirectory.boolValue) {
        if (resourceError != nil && error != NULL) {
            *error = resourceError;
            return NO;
        }
        return EJSPackageFail(error, EJSPackageErrorCodeUnsupported, @"Only unpacked .ejspkg directories are supported");
    }

    NSURL *canonicalPackageURL = packageURL.URLByResolvingSymlinksInPath;
    NSString *packageRootPath = canonicalPackageURL.path.stringByStandardizingPath;
    if (packageRootPath.length == 0) {
        return EJSPackageFail(error, EJSPackageErrorCodeInvalidArgument, @"Invalid package path");
    }

    NSURL *manifestURL = [canonicalPackageURL URLByAppendingPathComponent:EJSPackageManifestFileName isDirectory:NO];
    NSData *manifestData = [NSData dataWithContentsOfURL:manifestURL options:0 error:error];
    if (manifestData == nil) {
        return NO;
    }

    NSString *manifestSHA256 = [@"sha256-" stringByAppendingString:EJSPackageSHA256Hex(manifestData)];
    id root = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
    if (![root isKindOfClass:[NSDictionary class]]) {
        return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package manifest must be a JSON object");
    }

    NSDictionary<NSString *, id> *manifest = root;
    NSNumber *format = manifest[@"format"];
    NSString *packageID = EJSPackageString(manifest, @"packageId");
    NSString *entry = EJSPackageString(manifest, @"entry");
    NSDictionary<NSString *, id> *modules = EJSPackageDictionary(manifest, @"modules");
    NSString *packageSHA256 = EJSPackageNormalizedHash(EJSPackageString(manifest, @"packageSha256"));

    if (![format respondsToSelector:@selector(integerValue)] ||
        format.integerValue != 1 ||
        packageID.length == 0 ||
        entry.length == 0 ||
        modules.count == 0u) {
        return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package manifest is missing required fields");
    }

    if (!EJSPackageVerifyCapabilities(manifest, options, error) ||
        !EJSPackageVerifyApproval(options, packageID, manifestSHA256, packageSHA256, error)) {
        return NO;
    }

    NSMutableArray<EJSModuleSource *> *sourceTable = [[NSMutableArray alloc] initWithCapacity:modules.count];
    for (NSString *specifier in modules) {
        id moduleRecord = modules[specifier];
        if (![specifier isKindOfClass:[NSString class]] ||
            specifier.length == 0 ||
            ![moduleRecord isKindOfClass:[NSDictionary class]]) {
            return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package module entries must be objects");
        }

        NSString *modulePath = EJSPackageString(moduleRecord, @"path");
        NSString *moduleSHA256 = EJSPackageRawSHA256(EJSPackageString(moduleRecord, @"sha256"));
        NSString *moduleFormat = EJSPackageString(moduleRecord, @"format");
        if (modulePath.length == 0 || moduleSHA256.length == 0 || ![moduleFormat isEqualToString:@"esm"]) {
            return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package module entry is missing required fields");
        }

        NSURL *moduleURL = EJSPackageResolveModuleURL(canonicalPackageURL, modulePath, packageRootPath, error);
        if (moduleURL == nil) {
            return NO;
        }

        NSData *sourceData = [NSData dataWithContentsOfURL:moduleURL options:0 error:error];
        if (sourceData == nil) {
            return NO;
        }

        NSString *actualModuleSHA256 = EJSPackageSHA256Hex(sourceData);
        if (![actualModuleSHA256 isEqualToString:moduleSHA256]) {
            return EJSPackageFail(error,
                                  EJSPackageErrorCodeHashMismatch,
                                  [NSString stringWithFormat:@"Module hash mismatch for %@", specifier]);
        }

        NSString *source = [[NSString alloc] initWithData:sourceData encoding:NSUTF8StringEncoding];
        if (source == nil) {
            return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package module source is not UTF-8");
        }

        EJSModuleSource *moduleSource = [[EJSModuleSource alloc] initWithSpecifier:specifier
                                                                         sourceURL:specifier
                                                                            source:source];
        if (moduleSource == nil) {
            return EJSPackageFail(error, EJSPackageErrorCodeMalformed, @"Package module source is invalid");
        }
        [sourceTable addObject:moduleSource];
    }

    return [context registerModuleSources:sourceTable error:error];
}
