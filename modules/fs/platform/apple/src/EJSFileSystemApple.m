#import "EJSFileSystemApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_fs_js_bundle.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

NSString * const EJSFileSystemConfigurationKey = @"ejs.fs";

static const unsigned long long EJSFSDefaultLimitBytes = 8ull * 1024ull * 1024ull;

#ifdef EJS_TEST
static NSInteger g_ejs_fs_apple_test_fail_script_index = -1;

void EJSFileSystemAppleTestSetInstallFailScriptIndex(NSInteger index) {
    g_ejs_fs_apple_test_fail_script_index = index;
}
#endif

static NSError * EJSFSRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSFSProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"File-system provider failed");
}

static BOOL EJSFSStringIsNonEmpty(NSString *value) {
    return [value isKindOfClass:[NSString class]] && value.length > 0u;
}

static BOOL EJSFSPathIsInsideRoot(NSString *path, NSString *rootPath) {
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *standardRoot = [rootPath stringByStandardizingPath];

    if ([standardRoot isEqualToString:@"/"]) {
        return [standardPath hasPrefix:@"/"];
    }

    if ([standardPath isEqualToString:standardRoot]) {
        return YES;
    }

    NSString *rootPrefix = [standardRoot stringByAppendingString:@"/"];
    return [standardPath hasPrefix:rootPrefix];
}

static BOOL EJSFSPathHasParentTraversal(NSString *path) {
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@".."]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary * EJSFSJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"fs payload must be a JSON object");
        }
        return nil;
    }

    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"fs payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData * EJSFSJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSFSProviderError(EJSProviderErrorCodeInternal, @"Failed to encode fs JSON response");
    }
    return data;
}

static NSData * EJSFSOKData(void) {
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError * EJSFSProviderErrorForErrno(EJSProviderErrorCode code, NSString *operation, int errorNumber) {
    NSString *message = [NSString stringWithFormat:@"%@: %s", operation, strerror(errorNumber)];
    return EJSFSProviderError(code, message);
}

static EJSProviderErrorCode EJSFSProviderCodeForErrno(int errorNumber) {
    if (errorNumber == ENOENT ||
        errorNumber == ENOTDIR ||
        errorNumber == EEXIST ||
        errorNumber == ENOTEMPTY ||
        errorNumber == EISDIR ||
        errorNumber == EINVAL ||
        errorNumber == EBADF) {
        return EJSProviderErrorCodeInvalidArgument;
    }
    if (errorNumber == EACCES || errorNumber == EPERM || errorNumber == ELOOP) {
        return EJSProviderErrorCodeSecurity;
    }
    return EJSProviderErrorCodeInternal;
}

static NSDictionary * EJSFSStatDictionaryFromStruct(struct stat st) {
    NSString *type = @"other";
    if (S_ISREG(st.st_mode)) {
        type = @"file";
    } else if (S_ISDIR(st.st_mode)) {
        type = @"directory";
    } else if (S_ISLNK(st.st_mode)) {
        type = @"symbolicLink";
    }

    return @{
        @"type": type,
        @"dev": @(st.st_dev),
        @"ino": @(st.st_ino),
        @"mode": @(st.st_mode),
        @"nlink": @(st.st_nlink),
        @"uid": @(st.st_uid),
        @"gid": @(st.st_gid),
        @"rdev": @(st.st_rdev),
        @"size": @(st.st_size),
        @"blksize": @(st.st_blksize),
        @"blocks": @(st.st_blocks),
        @"atimeMs": @((double)st.st_atimespec.tv_sec * 1000.0 + (double)st.st_atimespec.tv_nsec / 1000000.0),
        @"mtimeMs": @((double)st.st_mtimespec.tv_sec * 1000.0 + (double)st.st_mtimespec.tv_nsec / 1000000.0),
        @"ctimeMs": @((double)st.st_ctimespec.tv_sec * 1000.0 + (double)st.st_ctimespec.tv_nsec / 1000000.0),
        @"birthtimeMs": @((double)st.st_birthtimespec.tv_sec * 1000.0 + (double)st.st_birthtimespec.tv_nsec / 1000000.0)
    };
}

static NSData * EJSFSStatJSONData(struct stat st, NSError **error) {
    return EJSFSJSONData(EJSFSStatDictionaryFromStruct(st), error);
}

static BOOL EJSFSNumberIsNonNegative(id value) {
    return [value isKindOfClass:[NSNumber class]] && [(NSNumber *)value longLongValue] >= 0;
}

static BOOL EJSFSWriteExclusiveData(NSData *data,
                                    NSString *path,
                                    NSString *alreadyExistsMessage,
                                    NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0666);
    if (fd < 0) {
        int openErrno = errno;
        if (openErrno == EEXIST || openErrno == ELOOP || openErrno == EISDIR) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, alreadyExistsMessage);
            }
        } else {
            if (error != NULL) {
                *error = EJSFSProviderErrorForErrno(EJSProviderErrorCodeInternal, @"Failed to create file", openErrno);
            }
        }
        return NO;
    }

    BOOL success = YES;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0u) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            success = NO;
            if (error != NULL) {
                *error = EJSFSProviderErrorForErrno(EJSProviderErrorCodeInternal, @"Failed to write file", errno);
            }
            break;
        }
        if (written == 0) {
            success = NO;
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInternal, @"Failed to write file: zero bytes written");
            }
            break;
        }
        bytes += (NSUInteger)written;
        remaining -= (NSUInteger)written;
    }

    if (close(fd) != 0 && success) {
        success = NO;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSProviderErrorCodeInternal, @"Failed to finalize file write", errno);
        }
    }

    if (!success) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return success;
}

static BOOL EJSFSValidateOptionalEncoding(NSDictionary *request, NSError **error) {
    id encoding = request[@"encoding"];
    if (encoding == nil || encoding == [NSNull null]) {
        return YES;
    }

    if (![encoding isKindOfClass:[NSString class]]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs encoding");
        }
        return NO;
    }

    NSString *normalized = [(NSString *)encoding lowercaseString];
    if (![normalized isEqualToString:@"utf8"] && ![normalized isEqualToString:@"utf-8"]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs encoding");
        }
        return NO;
    }

    return YES;
}

@interface EJSFileSystemRootPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, assign, readonly) BOOL canRead;
@property (nonatomic, assign, readonly) BOOL canWrite;
@property (nonatomic, assign, readonly) BOOL createIfMissing;
- (instancetype)initWithName:(NSString *)name
                        path:(NSString *)path
                     canRead:(BOOL)canRead
                    canWrite:(BOOL)canWrite
             createIfMissing:(BOOL)createIfMissing;
@end

@implementation EJSFileSystemRootPolicy

- (instancetype)initWithName:(NSString *)name
                        path:(NSString *)path
                     canRead:(BOOL)canRead
                    canWrite:(BOOL)canWrite
             createIfMissing:(BOOL)createIfMissing {
    self = [super init];

    if (self != nil) {
        _name = [name copy];
        _path = [[path stringByStandardizingPath] copy];
        _canRead = canRead;
        _canWrite = canWrite;
        _createIfMissing = createIfMissing;
    }

    return self;
}

@end

@interface EJSFileSystemPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *defaultRoot;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSFileSystemRootPolicy *> *roots;
@property (nonatomic, assign, readonly) unsigned long long maxReadBytes;
@property (nonatomic, assign, readonly) unsigned long long maxWriteBytes;
@property (nonatomic, assign, readonly) BOOL allowAbsolutePath;
@property (nonatomic, assign, readonly) BOOL allowParentTraversal;
@property (nonatomic, assign, readonly) BOOL allowSymlinkEscape;
- (instancetype)initWithDefaultRoot:(NSString *)defaultRoot
                              roots:(NSDictionary<NSString *, EJSFileSystemRootPolicy *> *)roots
                       maxReadBytes:(unsigned long long)maxReadBytes
                      maxWriteBytes:(unsigned long long)maxWriteBytes
                  allowAbsolutePath:(BOOL)allowAbsolutePath
               allowParentTraversal:(BOOL)allowParentTraversal
                 allowSymlinkEscape:(BOOL)allowSymlinkEscape;
@end

@implementation EJSFileSystemPolicy

- (instancetype)initWithDefaultRoot:(NSString *)defaultRoot
                              roots:(NSDictionary<NSString *, EJSFileSystemRootPolicy *> *)roots
                       maxReadBytes:(unsigned long long)maxReadBytes
                      maxWriteBytes:(unsigned long long)maxWriteBytes
                  allowAbsolutePath:(BOOL)allowAbsolutePath
               allowParentTraversal:(BOOL)allowParentTraversal
                 allowSymlinkEscape:(BOOL)allowSymlinkEscape {
    self = [super init];

    if (self != nil) {
        _defaultRoot = [defaultRoot copy];
        _roots = [roots copy];
        _maxReadBytes = maxReadBytes;
        _maxWriteBytes = maxWriteBytes;
        _allowAbsolutePath = allowAbsolutePath;
        _allowParentTraversal = allowParentTraversal;
        _allowSymlinkEscape = allowSymlinkEscape;
    }

    return self;
}

@end

@interface EJSFileSystemCancellation : NSObject
@property (atomic, assign, getter = isCancelled) BOOL cancelled;
@end

@implementation EJSFileSystemCancellation
@end

@interface EJSFileSystemOpenFile : NSObject
@property (nonatomic, assign, readonly) int fd;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, assign, readonly) BOOL readable;
@property (nonatomic, assign, readonly) BOOL writable;
- (instancetype)initWithFileDescriptor:(int)fd
                                  path:(NSString *)path
                              readable:(BOOL)readable
                              writable:(BOOL)writable;
- (BOOL)closeWithError:(NSError **)error;
@end

@implementation EJSFileSystemOpenFile {
    BOOL _closed;
}

- (instancetype)initWithFileDescriptor:(int)fd
                                  path:(NSString *)path
                              readable:(BOOL)readable
                              writable:(BOOL)writable {
    self = [super init];
    if (self != nil) {
        _fd = fd;
        _path = [path copy];
        _readable = readable;
        _writable = writable;
        _closed = NO;
    }
    return self;
}

- (void)dealloc {
    if (!_closed && _fd >= 0) {
        close(_fd);
    }
}

- (BOOL)closeWithError:(NSError **)error {
    if (_closed) {
        return YES;
    }
    _closed = YES;
    if (close(_fd) != 0) {
        int closeErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(closeErrno),
                                                @"Failed to close file handle",
                                                closeErrno);
        }
        return NO;
    }
    return YES;
}

@end

@interface EJSFileSystemProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSFileSystemPolicy *)policy;
- (NSData *)readFileWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)writeFileWithRequest:(NSDictionary *)request
                  transferBuffer:(NSData *)transferBuffer
                           error:(NSError **)error;
- (NSData *)openFileWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)readOpenFileWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)writeOpenFileWithRequest:(NSDictionary *)request
                       transferBuffer:(NSData *)transferBuffer
                                error:(NSError **)error;
- (NSData *)truncateOpenFileWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)syncOpenFileWithRequest:(NSDictionary *)request datasync:(BOOL)datasync error:(NSError **)error;
- (NSData *)closeOpenFileWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)statPathWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)lstatPathWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)existsPathWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)accessPathWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)readDirectoryWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)createDirectoryWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)copyFileWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)readLinkWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)linkWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)symlinkWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)statFSWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)makeTempPathWithRequest:(NSDictionary *)request directory:(BOOL)directory error:(NSError **)error;
- (NSData *)chmodWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)chownWithRequest:(NSDictionary *)request followSymlink:(BOOL)followSymlink error:(NSError **)error;
- (NSData *)utimeWithRequest:(NSDictionary *)request followSymlink:(BOOL)followSymlink error:(NSError **)error;
- (NSData *)renameWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)deletePathWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSString *)resolvedPathForRequest:(NSDictionary *)request
                              pathKey:(NSString *)pathKey
                              rootKey:(NSString *)rootKey
                                 read:(BOOL)read
                                error:(NSError **)error;
@end

static unsigned long long EJSFSUnsignedLimit(id value, unsigned long long defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }

    long long number = [value longLongValue];
    if (number < 0) {
        return defaultValue;
    }
    return (unsigned long long)number;
}

static BOOL EJSFSBoolValue(id value, BOOL defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    return [value boolValue];
}

static NSString * EJSFSAccessMode(NSDictionary *request, NSError **error) {
    id mode = request[@"mode"];
    if (mode == nil || mode == [NSNull null]) {
        return @"read";
    }
    if (![mode isKindOfClass:[NSString class]]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs access mode");
        }
        return nil;
    }

    NSString *normalized = [[(NSString *)mode lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if ([normalized isEqualToString:@"r"]) {
        return @"read";
    }
    if ([normalized isEqualToString:@"w"]) {
        return @"write";
    }
    if ([normalized isEqualToString:@"rw"]) {
        return @"readwrite";
    }
    if ([normalized isEqualToString:@"read"] ||
        [normalized isEqualToString:@"write"] ||
        [normalized isEqualToString:@"readwrite"]) {
        return normalized;
    }

    if (error != NULL) {
        *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs access mode");
    }
    return nil;
}

static int EJSFSOpenFlags(NSString *flag,
                          BOOL *readable,
                          BOOL *writable,
                          NSError **error) {
    if (![flag isKindOfClass:[NSString class]] || flag.length == 0u) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"fs open flag must be a non-empty string");
        }
        return -1;
    }

    if ([flag isEqualToString:@"r"]) {
        *readable = YES;
        *writable = NO;
        return O_RDONLY;
    }
    if ([flag isEqualToString:@"r+"]) {
        *readable = YES;
        *writable = YES;
        return O_RDWR;
    }
    if ([flag isEqualToString:@"w"] || [flag isEqualToString:@"wx"]) {
        *readable = NO;
        *writable = YES;
        return O_WRONLY | O_CREAT | O_TRUNC | ([flag isEqualToString:@"wx"] ? O_EXCL : 0);
    }
    if ([flag isEqualToString:@"w+"] || [flag isEqualToString:@"wx+"]) {
        *readable = YES;
        *writable = YES;
        return O_RDWR | O_CREAT | O_TRUNC | ([flag isEqualToString:@"wx+"] ? O_EXCL : 0);
    }
    if ([flag isEqualToString:@"a"] || [flag isEqualToString:@"ax"]) {
        *readable = NO;
        *writable = YES;
        return O_WRONLY | O_CREAT | O_APPEND | ([flag isEqualToString:@"ax"] ? O_EXCL : 0);
    }
    if ([flag isEqualToString:@"a+"] || [flag isEqualToString:@"ax+"]) {
        *readable = YES;
        *writable = YES;
        return O_RDWR | O_CREAT | O_APPEND | ([flag isEqualToString:@"ax+"] ? O_EXCL : 0);
    }

    if (error != NULL) {
        *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs open flag");
    }
    return -1;
}

static EJSFileSystemPolicy * EJSFileSystemPolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0) {
        if (error != NULL) {
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Missing ejs.fs configuration");
        }
        return nil;
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        if (error != NULL) {
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fs configuration must be valid UTF-8");
        }
        return nil;
    }

    NSError *jsonError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            NSString *message = jsonError.localizedDescription ?: @"ejs.fs configuration must be a JSON object";
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, message);
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    NSNumber *version = [object[@"version"] isKindOfClass:[NSNumber class]] ? object[@"version"] : nil;
    if (version == nil || version.integerValue != 1) {
        if (error != NULL) {
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Unsupported ejs.fs configuration version");
        }
        return nil;
    }

    NSString *defaultRoot = [object[@"defaultRoot"] isKindOfClass:[NSString class]] ? object[@"defaultRoot"] : nil;
    NSDictionary *rootsObject = [object[@"roots"] isKindOfClass:[NSDictionary class]] ? object[@"roots"] : nil;
    if (!EJSFSStringIsNonEmpty(defaultRoot) || rootsObject.count == 0u) {
        if (error != NULL) {
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fs requires defaultRoot and roots");
        }
        return nil;
    }

    NSMutableDictionary<NSString *, EJSFileSystemRootPolicy *> *roots = [[NSMutableDictionary alloc] init];
    for (NSString *rootName in rootsObject) {
        if (!EJSFSStringIsNonEmpty(rootName)) {
            if (error != NULL) {
                *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fs root names must be non-empty strings");
            }
            return nil;
        }

        NSDictionary *rootObject = [rootsObject[rootName] isKindOfClass:[NSDictionary class]] ? rootsObject[rootName] : nil;
        NSString *path = [rootObject[@"path"] isKindOfClass:[NSString class]] ? rootObject[@"path"] : nil;
        NSArray *permissions = [rootObject[@"permissions"] isKindOfClass:[NSArray class]] ? rootObject[@"permissions"] : nil;
        BOOL canRead = NO;
        BOOL canWrite = NO;

        for (id permission in permissions) {
            if ([permission isKindOfClass:[NSString class]]) {
                if ([permission isEqualToString:@"read"]) {
                    canRead = YES;
                } else if ([permission isEqualToString:@"write"]) {
                    canWrite = YES;
                }
            }
        }

        if (!EJSFSStringIsNonEmpty(path) || !path.isAbsolutePath || (!canRead && !canWrite)) {
            if (error != NULL) {
                *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fs roots require absolute paths and permissions");
            }
            return nil;
        }

        BOOL createIfMissing = EJSFSBoolValue(rootObject[@"createIfMissing"], NO);
        roots[rootName] = [[EJSFileSystemRootPolicy alloc] initWithName:rootName
                                                                   path:path
                                                                canRead:canRead
                                                               canWrite:canWrite
                                                        createIfMissing:createIfMissing];
    }

    if (roots[defaultRoot] == nil) {
        if (error != NULL) {
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fs defaultRoot must exist in roots");
        }
        return nil;
    }

    NSDictionary *limits = [object[@"limits"] isKindOfClass:[NSDictionary class]] ? object[@"limits"] : @{};
    NSDictionary *pathPolicy = [object[@"pathPolicy"] isKindOfClass:[NSDictionary class]] ? object[@"pathPolicy"] : @{};
    EJSFileSystemPolicy *policy =
        [[EJSFileSystemPolicy alloc] initWithDefaultRoot:defaultRoot
                                                   roots:roots
                                            maxReadBytes:EJSFSUnsignedLimit(limits[@"maxReadBytes"], EJSFSDefaultLimitBytes)
                                           maxWriteBytes:EJSFSUnsignedLimit(limits[@"maxWriteBytes"], EJSFSDefaultLimitBytes)
                                       allowAbsolutePath:EJSFSBoolValue(pathPolicy[@"allowAbsolutePath"], NO)
                                    allowParentTraversal:EJSFSBoolValue(pathPolicy[@"allowParentTraversal"], NO)
                                      allowSymlinkEscape:EJSFSBoolValue(pathPolicy[@"allowSymlinkEscape"], NO)];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (EJSFileSystemRootPolicy *root in policy.roots.allValues) {
        if (!root.createIfMissing) {
            continue;
        }

        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:root.path
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&createError]) {
            if (error != NULL) {
                NSString *message = [NSString stringWithFormat:@"Failed to create ejs.fs root '%@': %@",
                                                               root.name,
                                                               createError.localizedDescription ?: @"unknown error"];
                *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInternal, message);
            }
            return nil;
        }
    }

    return policy;
}

@implementation EJSFileSystemProvider {
    EJSFileSystemPolicy *_policy;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, EJSFileSystemOpenFile *> *_openFiles;
    unsigned long long _nextFileHandle;
}

- (instancetype)initWithPolicy:(EJSFileSystemPolicy *)policy {
    self = [super init];

    if (self != nil) {
        _moduleID = @"ejs.fs";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.fs.provider", DISPATCH_QUEUE_SERIAL);
        _openFiles = [[NSMutableDictionary alloc] init];
        _nextFileHandle = 1ull;
    }

    return self;
}

- (void)dealloc {
    for (EJSFileSystemOpenFile *file in _openFiles.allValues) {
        [file closeWithError:nil];
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;

    if (![methodID isEqualToString:@"readFile"] &&
        ![methodID isEqualToString:@"writeFile"] &&
        ![methodID isEqualToString:@"open"] &&
        ![methodID isEqualToString:@"fileHandleRead"] &&
        ![methodID isEqualToString:@"fileHandleWrite"] &&
        ![methodID isEqualToString:@"fileHandleTruncate"] &&
        ![methodID isEqualToString:@"fileHandleDatasync"] &&
        ![methodID isEqualToString:@"fileHandleSync"] &&
        ![methodID isEqualToString:@"fileHandleClose"] &&
        ![methodID isEqualToString:@"stat"] &&
        ![methodID isEqualToString:@"lstat"] &&
        ![methodID isEqualToString:@"exists"] &&
        ![methodID isEqualToString:@"access"] &&
        ![methodID isEqualToString:@"readdir"] &&
        ![methodID isEqualToString:@"list"] &&
        ![methodID isEqualToString:@"mkdir"] &&
        ![methodID isEqualToString:@"copyFile"] &&
        ![methodID isEqualToString:@"readLink"] &&
        ![methodID isEqualToString:@"link"] &&
        ![methodID isEqualToString:@"symlink"] &&
        ![methodID isEqualToString:@"statFs"] &&
        ![methodID isEqualToString:@"makeTempDir"] &&
        ![methodID isEqualToString:@"makeTempFile"] &&
        ![methodID isEqualToString:@"chmod"] &&
        ![methodID isEqualToString:@"chown"] &&
        ![methodID isEqualToString:@"lchown"] &&
        ![methodID isEqualToString:@"utime"] &&
        ![methodID isEqualToString:@"lutime"] &&
        ![methodID isEqualToString:@"rename"] &&
        ![methodID isEqualToString:@"delete"] &&
        ![methodID isEqualToString:@"remove"] &&
        ![methodID isEqualToString:@"rm"] &&
        ![methodID isEqualToString:@"unlink"]) {
        [responder finishWithData:nil error:EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.fs method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSFSJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *encodingError = nil;
    if (!EJSFSValidateOptionalEncoding(request, &encodingError)) {
        [responder finishWithData:nil error:encodingError];
        return [[EJSImmediateOperation alloc] init];
    }

    EJSFileSystemCancellation *cancellation = [[EJSFileSystemCancellation alloc] init];
    NSData *requestTransfer = [transferBuffer copy];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (cancellation.isCancelled) {
                return;
            }

            NSError *operationError = nil;
            NSData *result = nil;

            if ([methodID isEqualToString:@"readFile"]) {
                result = [self readFileWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"writeFile"]) {
                result = [self writeFileWithRequest:request transferBuffer:requestTransfer error:&operationError];
            } else if ([methodID isEqualToString:@"open"]) {
                result = [self openFileWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"fileHandleRead"]) {
                result = [self readOpenFileWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"fileHandleWrite"]) {
                result = [self writeOpenFileWithRequest:request transferBuffer:requestTransfer error:&operationError];
            } else if ([methodID isEqualToString:@"fileHandleTruncate"]) {
                result = [self truncateOpenFileWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"fileHandleDatasync"]) {
                result = [self syncOpenFileWithRequest:request datasync:YES error:&operationError];
            } else if ([methodID isEqualToString:@"fileHandleSync"]) {
                result = [self syncOpenFileWithRequest:request datasync:NO error:&operationError];
            } else if ([methodID isEqualToString:@"fileHandleClose"]) {
                result = [self closeOpenFileWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"stat"]) {
                result = [self statPathWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"lstat"]) {
                result = [self lstatPathWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"exists"]) {
                result = [self existsPathWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"access"]) {
                result = [self accessPathWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"readdir"] || [methodID isEqualToString:@"list"]) {
                result = [self readDirectoryWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"mkdir"]) {
                result = [self createDirectoryWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"copyFile"]) {
                result = [self copyFileWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"readLink"]) {
                result = [self readLinkWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"link"]) {
                result = [self linkWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"symlink"]) {
                result = [self symlinkWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"statFs"]) {
                result = [self statFSWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"makeTempDir"]) {
                result = [self makeTempPathWithRequest:request directory:YES error:&operationError];
            } else if ([methodID isEqualToString:@"makeTempFile"]) {
                result = [self makeTempPathWithRequest:request directory:NO error:&operationError];
            } else if ([methodID isEqualToString:@"chmod"]) {
                result = [self chmodWithRequest:request error:&operationError];
            } else if ([methodID isEqualToString:@"chown"]) {
                result = [self chownWithRequest:request followSymlink:YES error:&operationError];
            } else if ([methodID isEqualToString:@"lchown"]) {
                result = [self chownWithRequest:request followSymlink:NO error:&operationError];
            } else if ([methodID isEqualToString:@"utime"]) {
                result = [self utimeWithRequest:request followSymlink:YES error:&operationError];
            } else if ([methodID isEqualToString:@"lutime"]) {
                result = [self utimeWithRequest:request followSymlink:NO error:&operationError];
            } else if ([methodID isEqualToString:@"rename"]) {
                result = [self renameWithRequest:request error:&operationError];
            } else {
                result = [self deletePathWithRequest:request error:&operationError];
            }

            if (cancellation.isCancelled) {
                return;
            }

            [responder finishWithData:result error:operationError];
        }
    });

    return [[EJSBlockOperation alloc] initWithCancelBlock:^{
        cancellation.cancelled = YES;
    }];
}

- (NSString *)resolvedPathForRequest:(NSDictionary *)request
                                read:(BOOL)read
                               error:(NSError **)error {
    return [self resolvedPathForRequest:request pathKey:@"path" rootKey:@"root" read:read error:error];
}

- (NSString *)resolvedPathForRequest:(NSDictionary *)request
                              pathKey:(NSString *)pathKey
                              rootKey:(NSString *)rootKey
                                 read:(BOOL)read
                                error:(NSError **)error {
    NSString *requestPath = [request[pathKey] isKindOfClass:[NSString class]] ? request[pathKey] : nil;
    if (!EJSFSStringIsNonEmpty(requestPath)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"fs path is required");
        }
        return nil;
    }

    id rootValue = request[rootKey];
    NSString *rootName = rootValue == nil || rootValue == [NSNull null]
        ? _policy.defaultRoot
        : ([rootValue isKindOfClass:[NSString class]] ? rootValue : nil);
    if (!EJSFSStringIsNonEmpty(rootName)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"fs root must be a non-empty string");
        }
        return nil;
    }

    EJSFileSystemRootPolicy *root = _policy.roots[rootName];
    if (root == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"fs root is not allowed");
        }
        return nil;
    }

    if (read && !root.canRead) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"fs root does not allow reads");
        }
        return nil;
    }
    if (!read && !root.canWrite) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"fs root does not allow writes");
        }
        return nil;
    }

    if (requestPath.isAbsolutePath && !_policy.allowAbsolutePath) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Absolute fs paths are not allowed");
        }
        return nil;
    }

    if (!_policy.allowParentTraversal && EJSFSPathHasParentTraversal(requestPath)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Parent traversal is not allowed");
        }
        return nil;
    }

    NSString *targetPath = requestPath.isAbsolutePath
        ? requestPath
        : [root.path stringByAppendingPathComponent:requestPath];
    targetPath = [targetPath stringByStandardizingPath];

    NSString *rootCheckPath = _policy.allowSymlinkEscape
        ? [root.path stringByStandardizingPath]
        : [root.path stringByResolvingSymlinksInPath];
    NSString *targetCheckPath = nil;

    if (_policy.allowSymlinkEscape) {
        targetCheckPath = targetPath;
    } else {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL targetExists = [fileManager fileExistsAtPath:targetPath];
        BOOL targetIsSymlink = [fileManager destinationOfSymbolicLinkAtPath:targetPath error:nil] != nil;

        if (read || targetExists || targetIsSymlink) {
            targetCheckPath = [targetPath stringByResolvingSymlinksInPath];
        } else {
            NSString *parentPath = [targetPath stringByDeletingLastPathComponent];
            NSString *resolvedParent = [parentPath stringByResolvingSymlinksInPath];
            targetCheckPath = [resolvedParent stringByAppendingPathComponent:targetPath.lastPathComponent];
        }
    }

    if (!EJSFSPathIsInsideRoot(targetCheckPath, rootCheckPath)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Resolved fs path escapes its root");
        }
        return nil;
    }

    return targetPath;
}

- (NSData *)readFileWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *attributesError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:path error:&attributesError];
    NSNumber *fileSize = attributes[NSFileSize];
    if ([fileSize isKindOfClass:[NSNumber class]] && fileSize.unsignedLongLongValue > _policy.maxReadBytes) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Read exceeds fs maxReadBytes");
        }
        return nil;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (data == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                        readError.localizedDescription ?: attributesError.localizedDescription ?: @"Failed to read file");
        }
        return nil;
    }

    if (data.length > _policy.maxReadBytes) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Read exceeds fs maxReadBytes");
        }
        return nil;
    }

    return data;
}

- (NSData *)writeFileWithRequest:(NSDictionary *)request
                  transferBuffer:(NSData *)transferBuffer
                           error:(NSError **)error {
    if (transferBuffer == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"writeFile requires a transfer buffer");
        }
        return nil;
    }

    if (transferBuffer.length > _policy.maxWriteBytes) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Write exceeds fs maxWriteBytes");
        }
        return nil;
    }

    NSString *flag = [request[@"flag"] isKindOfClass:[NSString class]] ? request[@"flag"] : @"w";
    if (![flag isEqualToString:@"w"] && ![flag isEqualToString:@"wx"]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs write flag");
        }
        return nil;
    }

    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    if ([flag isEqualToString:@"wx"]) {
        if (!EJSFSWriteExclusiveData(transferBuffer, path, @"File already exists", error)) {
            return nil;
        }
    } else {
        NSError *writeError = nil;
        if (![transferBuffer writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                            writeError.localizedDescription ?: @"Failed to write file");
            }
            return nil;
        }
    }

    return EJSFSOKData();
}

- (EJSFileSystemOpenFile *)openFileForRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *handle = [request[@"handle"] isKindOfClass:[NSString class]] ? request[@"handle"] : nil;
    if (!EJSFSStringIsNonEmpty(handle)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file handle is required");
        }
        return nil;
    }

    EJSFileSystemOpenFile *file = _openFiles[handle];
    if (file == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file handle is closed or unknown");
        }
        return nil;
    }
    return file;
}

- (NSData *)openFileWithRequest:(NSDictionary *)request error:(NSError **)error {
    BOOL readable = NO;
    BOOL writable = NO;
    NSError *flagError = nil;
    NSString *flag = [request[@"flags"] isKindOfClass:[NSString class]] ? request[@"flags"] : @"r";
    int openFlags = EJSFSOpenFlags(flag, &readable, &writable, &flagError);
    if (openFlags < 0) {
        if (error != NULL) {
            *error = flagError;
        }
        return nil;
    }

    NSString *path = nil;
    if (readable) {
        NSError *readError = nil;
        path = [self resolvedPathForRequest:request read:YES error:&readError];
        if (path == nil) {
            if (error != NULL) {
                *error = readError;
            }
            return nil;
        }
    }
    if (writable) {
        NSError *writeError = nil;
        NSString *writePath = [self resolvedPathForRequest:request read:NO error:&writeError];
        if (writePath == nil) {
            if (error != NULL) {
                *error = writeError;
            }
            return nil;
        }
        path = writePath;
    }

    NSNumber *modeNumber = [request[@"mode"] isKindOfClass:[NSNumber class]] ? request[@"mode"] : @0666;
    mode_t mode = (mode_t)(modeNumber.unsignedIntValue & 07777u);
    const char *fsPath = path.fileSystemRepresentation;
    if (fsPath == NULL) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid fs open path");
        }
        return nil;
    }

    int fd = open(fsPath, openFlags, mode);
    if (fd < 0) {
        int openErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(openErrno), @"Failed to open file", openErrno);
        }
        return nil;
    }

    NSString *handle = [NSString stringWithFormat:@"%llu", _nextFileHandle++];
    _openFiles[handle] = [[EJSFileSystemOpenFile alloc] initWithFileDescriptor:fd
                                                                          path:path
                                                                      readable:readable
                                                                      writable:writable];
    return EJSFSJSONData(@{ @"handle": handle }, error);
}

- (NSData *)readOpenFileWithRequest:(NSDictionary *)request error:(NSError **)error {
    EJSFileSystemOpenFile *file = [self openFileForRequest:request error:error];
    if (file == nil) {
        return nil;
    }
    if (!file.readable) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file handle is not readable");
        }
        return nil;
    }

    if (!EJSFSNumberIsNonNegative(request[@"length"])) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file read length must be a non-negative number");
        }
        return nil;
    }

    unsigned long long requestedLength = [(NSNumber *)request[@"length"] unsignedLongLongValue];
    if (requestedLength > _policy.maxReadBytes || requestedLength > NSUIntegerMax) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Read exceeds fs maxReadBytes");
        }
        return nil;
    }
    if (requestedLength == 0u) {
        return [NSData data];
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)requestedLength];
    ssize_t bytesRead = 0;
    do {
        if (EJSFSNumberIsNonNegative(request[@"position"])) {
            bytesRead = pread(file.fd, data.mutableBytes, (size_t)requestedLength, (off_t)[(NSNumber *)request[@"position"] longLongValue]);
        } else {
            bytesRead = read(file.fd, data.mutableBytes, (size_t)requestedLength);
        }
    } while (bytesRead < 0 && errno == EINTR);

    if (bytesRead < 0) {
        int readErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(readErrno), @"Failed to read file handle", readErrno);
        }
        return nil;
    }

    data.length = (NSUInteger)bytesRead;
    return data;
}

- (NSData *)writeOpenFileWithRequest:(NSDictionary *)request
                       transferBuffer:(NSData *)transferBuffer
                                error:(NSError **)error {
    EJSFileSystemOpenFile *file = [self openFileForRequest:request error:error];
    if (file == nil) {
        return nil;
    }
    if (!file.writable) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file handle is not writable");
        }
        return nil;
    }
    if (transferBuffer == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file handle write requires a transfer buffer");
        }
        return nil;
    }
    if (transferBuffer.length > _policy.maxWriteBytes) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Write exceeds fs maxWriteBytes");
        }
        return nil;
    }

    const uint8_t *bytes = transferBuffer.bytes;
    NSUInteger remaining = transferBuffer.length;
    NSUInteger totalWritten = 0u;
    BOOL hasPosition = EJSFSNumberIsNonNegative(request[@"position"]);
    off_t position = hasPosition ? (off_t)[(NSNumber *)request[@"position"] longLongValue] : 0;
    while (remaining > 0u) {
        ssize_t written = hasPosition
            ? pwrite(file.fd, bytes + totalWritten, remaining, position + (off_t)totalWritten)
            : write(file.fd, bytes + totalWritten, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            int writeErrno = errno;
            if (error != NULL) {
                *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(writeErrno), @"Failed to write file handle", writeErrno);
            }
            return nil;
        }
        if (written == 0) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInternal, @"Failed to write file handle: zero bytes written");
            }
            return nil;
        }
        totalWritten += (NSUInteger)written;
        remaining -= (NSUInteger)written;
    }

    return EJSFSJSONData(@{ @"bytesWritten": @(totalWritten) }, error);
}

- (NSData *)truncateOpenFileWithRequest:(NSDictionary *)request error:(NSError **)error {
    EJSFileSystemOpenFile *file = [self openFileForRequest:request error:error];
    if (file == nil) {
        return nil;
    }
    if (!file.writable) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file handle is not writable");
        }
        return nil;
    }
    if (!EJSFSNumberIsNonNegative(request[@"length"])) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"file truncate length must be a non-negative number");
        }
        return nil;
    }
    unsigned long long length = [(NSNumber *)request[@"length"] unsignedLongLongValue];
    if (length > _policy.maxWriteBytes) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Truncate exceeds fs maxWriteBytes");
        }
        return nil;
    }
    if (ftruncate(file.fd, (off_t)length) != 0) {
        int truncateErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(truncateErrno), @"Failed to truncate file handle", truncateErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)syncOpenFileWithRequest:(NSDictionary *)request datasync:(BOOL)datasync error:(NSError **)error {
    (void)datasync;
    EJSFileSystemOpenFile *file = [self openFileForRequest:request error:error];
    if (file == nil) {
        return nil;
    }
    if (fsync(file.fd) != 0) {
        int syncErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(syncErrno), @"Failed to sync file handle", syncErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)closeOpenFileWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *handle = [request[@"handle"] isKindOfClass:[NSString class]] ? request[@"handle"] : nil;
    EJSFileSystemOpenFile *file = [self openFileForRequest:request error:error];
    if (file == nil) {
        return nil;
    }
    if (![file closeWithError:error]) {
        return nil;
    }
    [_openFiles removeObjectForKey:handle];
    return EJSFSOKData();
}

- (NSData *)statPathWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    const char *fsPath = path.fileSystemRepresentation;
    if (fsPath == NULL) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid fs stat path");
        }
        return nil;
    }

    struct stat st;
    if (stat(fsPath, &st) != 0) {
        int statErrno = errno;
        EJSProviderErrorCode code = EJSProviderErrorCodeInternal;
        if (statErrno == ENOENT || statErrno == ENOTDIR) {
            code = EJSProviderErrorCodeInvalidArgument;
        } else if (statErrno == EACCES) {
            code = EJSProviderErrorCodeSecurity;
        }
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(code, @"Failed to stat path", statErrno);
        }
        return nil;
    }

    return EJSFSStatJSONData(st, error);
}

- (NSData *)lstatPathWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    const char *fsPath = path.fileSystemRepresentation;
    if (fsPath == NULL) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid fs lstat path");
        }
        return nil;
    }

    struct stat st;
    if (lstat(fsPath, &st) != 0) {
        int statErrno = errno;
        EJSProviderErrorCode code = EJSProviderErrorCodeInternal;
        if (statErrno == ENOENT || statErrno == ENOTDIR) {
            code = EJSProviderErrorCodeInvalidArgument;
        } else if (statErrno == EACCES) {
            code = EJSProviderErrorCodeSecurity;
        }
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(code, @"Failed to lstat path", statErrno);
        }
        return nil;
    }

    return EJSFSStatJSONData(st, error);
}

- (NSData *)existsPathWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL exists = [fileManager fileExistsAtPath:path];
    NSError *jsonError = nil;
    NSData *data = EJSFSJSONData(@{ @"exists": @(exists) }, &jsonError);
    if (data == nil && error != NULL) {
        *error = jsonError;
    }
    return data;
}

- (NSData *)accessPathWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *modeError = nil;
    NSString *mode = EJSFSAccessMode(request, &modeError);
    if (mode == nil) {
        if (error != NULL) {
            *error = modeError;
        }
        return nil;
    }

    BOOL needsRead = [mode isEqualToString:@"read"] || [mode isEqualToString:@"readwrite"];
    BOOL needsWrite = [mode isEqualToString:@"write"] || [mode isEqualToString:@"readwrite"];
    NSString *path = nil;

    if (needsRead) {
        NSError *resolveError = nil;
        path = [self resolvedPathForRequest:request read:YES error:&resolveError];
        if (path == nil) {
            if (error != NULL) {
                *error = resolveError;
            }
            return nil;
        }
    }

    if (needsWrite) {
        NSError *resolveError = nil;
        path = [self resolvedPathForRequest:request read:NO error:&resolveError];
        if (path == nil) {
            if (error != NULL) {
                *error = resolveError;
            }
            return nil;
        }
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL exists = [fileManager fileExistsAtPath:path] ||
        [fileManager destinationOfSymbolicLinkAtPath:path error:nil] != nil;
    if (!exists) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Path does not exist");
        }
        return nil;
    }

    if (needsRead && ![fileManager isReadableFileAtPath:path]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Path is not readable");
        }
        return nil;
    }
    if (needsWrite && ![fileManager isWritableFileAtPath:path]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Path is not writable");
        }
        return nil;
    }

    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)readDirectoryWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    NSError *readError = nil;
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&readError];
    if (entries == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                        readError.localizedDescription ?: @"Failed to list directory");
        }
        return nil;
    }

    NSArray<NSString *> *sortedEntries = [entries sortedArrayUsingSelector:@selector(compare:)];
    NSError *jsonError = nil;
    NSData *data = EJSFSJSONData(@{ @"entries": sortedEntries }, &jsonError);
    if (data == nil && error != NULL) {
        *error = jsonError;
    }
    return data;
}

- (NSData *)createDirectoryWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    BOOL recursive = EJSFSBoolValue(request[@"recursive"], NO);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    BOOL exists = [fileManager fileExistsAtPath:path isDirectory:&isDirectory];
    BOOL isSymlink = [fileManager destinationOfSymbolicLinkAtPath:path error:nil] != nil;

    if (exists || isSymlink) {
        if (recursive && isDirectory && !isSymlink) {
            return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Directory path already exists");
        }
        return nil;
    }

    NSError *createError = nil;
    if (![fileManager createDirectoryAtPath:path
                withIntermediateDirectories:recursive
                                 attributes:nil
                                      error:&createError]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                        createError.localizedDescription ?: @"Failed to create directory");
        }
        return nil;
    }

    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)copyFileWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *sourceError = nil;
    NSString *sourcePath = [self resolvedPathForRequest:request read:YES error:&sourceError];
    if (sourcePath == nil) {
        if (error != NULL) {
            *error = sourceError;
        }
        return nil;
    }

    NSMutableDictionary *destinationRequest = [request mutableCopy];
    if (destinationRequest[@"newRoot"] == nil && destinationRequest[@"root"] != nil) {
        destinationRequest[@"newRoot"] = destinationRequest[@"root"];
    }

    NSError *destinationError = nil;
    NSString *destinationPath = [self resolvedPathForRequest:destinationRequest
                                                     pathKey:@"newPath"
                                                     rootKey:@"newRoot"
                                                        read:NO
                                                       error:&destinationError];
    if (destinationPath == nil) {
        if (error != NULL) {
            *error = destinationError;
        }
        return nil;
    }

    NSString *flag = [request[@"flag"] isKindOfClass:[NSString class]] ? request[@"flag"] : @"w";
    if (![flag isEqualToString:@"w"] && ![flag isEqualToString:@"wx"]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported fs copy flag");
        }
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *attributesError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [fileManager attributesOfItemAtPath:sourcePath error:&attributesError];
    if (attributes == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument,
                                        attributesError.localizedDescription ?: @"Source path does not exist");
        }
        return nil;
    }
    if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"copyFile source must be a file");
        }
        return nil;
    }

    NSNumber *fileSize = [attributes[NSFileSize] isKindOfClass:[NSNumber class]] ? attributes[NSFileSize] : nil;
    if ([fileSize isKindOfClass:[NSNumber class]] &&
        (fileSize.unsignedLongLongValue > _policy.maxReadBytes ||
         fileSize.unsignedLongLongValue > _policy.maxWriteBytes)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"copyFile exceeds fs size limits");
        }
        return nil;
    }

    if ([[sourcePath stringByStandardizingPath] isEqualToString:[destinationPath stringByStandardizingPath]]) {
        if ([flag isEqualToString:@"wx"]) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Destination already exists");
            }
            return nil;
        }
        return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    BOOL destinationIsDirectory = NO;
    BOOL destinationExists = [fileManager fileExistsAtPath:destinationPath isDirectory:&destinationIsDirectory];
    BOOL destinationIsSymlink = [fileManager destinationOfSymbolicLinkAtPath:destinationPath error:nil] != nil;

    if ([flag isEqualToString:@"wx"]) {
        if (destinationExists && destinationIsDirectory && !destinationIsSymlink) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Destination is a directory");
            }
            return nil;
        }
    } else if (destinationExists || destinationIsSymlink) {
        if (destinationIsDirectory && !destinationIsSymlink) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Destination is a directory");
            }
            return nil;
        }

        NSError *removeError = nil;
        if (![fileManager removeItemAtPath:destinationPath error:&removeError]) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                            removeError.localizedDescription ?: @"Failed to replace destination");
            }
            return nil;
        }
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:sourcePath options:0 error:&readError];
    if (data == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                        readError.localizedDescription ?: @"Failed to read source file");
        }
        return nil;
    }
    if (data.length > _policy.maxReadBytes || data.length > _policy.maxWriteBytes) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"copyFile exceeds fs size limits");
        }
        return nil;
    }

    if ([flag isEqualToString:@"wx"]) {
        if (!EJSFSWriteExclusiveData(data, destinationPath, @"Destination already exists", error)) {
            return nil;
        }
    } else {
        NSError *writeError = nil;
        if (![data writeToFile:destinationPath options:NSDataWritingAtomic error:&writeError]) {
            if (error != NULL) {
                *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                            writeError.localizedDescription ?: @"Failed to write destination file");
            }
            return nil;
        }
    }

    return EJSFSOKData();
}

- (NSData *)readLinkWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    NSError *readError = nil;
    NSString *target = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:path error:&readError];
    if (target == nil) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument,
                                        readError.localizedDescription ?: @"Path is not a symbolic link");
        }
        return nil;
    }
    return EJSFSJSONData(@{ @"target": target }, error);
}

- (NSData *)linkWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *sourceError = nil;
    NSString *sourcePath = [self resolvedPathForRequest:request read:YES error:&sourceError];
    if (sourcePath == nil) {
        if (error != NULL) {
            *error = sourceError;
        }
        return nil;
    }

    NSMutableDictionary *destinationRequest = [request mutableCopy];
    if (destinationRequest[@"newRoot"] == nil && destinationRequest[@"root"] != nil) {
        destinationRequest[@"newRoot"] = destinationRequest[@"root"];
    }
    NSError *destinationError = nil;
    NSString *destinationPath = [self resolvedPathForRequest:destinationRequest
                                                     pathKey:@"newPath"
                                                     rootKey:@"newRoot"
                                                        read:NO
                                                       error:&destinationError];
    if (destinationPath == nil) {
        if (error != NULL) {
            *error = destinationError;
        }
        return nil;
    }

    if (link(sourcePath.fileSystemRepresentation, destinationPath.fileSystemRepresentation) != 0) {
        int linkErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(linkErrno), @"Failed to create hard link", linkErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)symlinkWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *target = [request[@"target"] isKindOfClass:[NSString class]] ? request[@"target"] : nil;
    if (!EJSFSStringIsNonEmpty(target)) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"symlink target is required");
        }
        return nil;
    }
    if (!_policy.allowSymlinkEscape && (target.isAbsolutePath || EJSFSPathHasParentTraversal(target))) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeSecurity, @"Symlink target may not escape its root");
        }
        return nil;
    }

    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    if (symlink(target.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        int symlinkErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(symlinkErrno), @"Failed to create symbolic link", symlinkErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)statFSWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:YES error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    struct statfs fs;
    if (statfs(path.fileSystemRepresentation, &fs) != 0) {
        int statErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(statErrno), @"Failed to stat file system", statErrno);
        }
        return nil;
    }

    NSDictionary *response = @{
        @"type": @(fs.f_type),
        @"bsize": @(fs.f_bsize),
        @"blocks": @(fs.f_blocks),
        @"bfree": @(fs.f_bfree),
        @"bavail": @(fs.f_bavail),
        @"files": @(fs.f_files),
        @"ffree": @(fs.f_ffree)
    };
    return EJSFSJSONData(response, error);
}

- (NSData *)makeTempPathWithRequest:(NSDictionary *)request directory:(BOOL)directory error:(NSError **)error {
    NSString *prefix = [request[@"prefix"] isKindOfClass:[NSString class]] ? request[@"prefix"] : @"tmp-";
    if ([prefix rangeOfString:@"/"].location != NSNotFound || prefix.length == 0u) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"temp prefix must be non-empty and path-free");
        }
        return nil;
    }

    NSError *resolveError = nil;
    NSString *dirPath = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (dirPath == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    NSString *baseRequestPath = [request[@"path"] isKindOfClass:[NSString class]] ? request[@"path"] : @".";
    NSString *relativeDir = [baseRequestPath isEqualToString:@"."] ? @"" : baseRequestPath;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSUInteger attempt = 0u; attempt < 32u; ++attempt) {
        NSString *name = [prefix stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
        NSString *absolutePath = [dirPath stringByAppendingPathComponent:name];
        NSString *relativePath = relativeDir.length == 0u ? name : [relativeDir stringByAppendingPathComponent:name];
        if (directory) {
            NSError *createError = nil;
            if ([fileManager createDirectoryAtPath:absolutePath
                       withIntermediateDirectories:NO
                                        attributes:nil
                                             error:&createError]) {
                return EJSFSJSONData(@{ @"path": relativePath }, error);
            }
            if (![createError.domain isEqualToString:NSCocoaErrorDomain] || createError.code != NSFileWriteFileExistsError) {
                if (error != NULL) {
                    *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                                createError.localizedDescription ?: @"Failed to create temporary directory");
                }
                return nil;
            }
        } else {
            int fd = open(absolutePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (fd >= 0) {
                close(fd);
                return EJSFSJSONData(@{ @"path": relativePath }, error);
            }
            if (errno != EEXIST) {
                int createErrno = errno;
                if (error != NULL) {
                    *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(createErrno),
                                                        @"Failed to create temporary file",
                                                        createErrno);
                }
                return nil;
            }
        }
    }
    if (error != NULL) {
        *error = EJSFSProviderError(EJSProviderErrorCodeInternal, @"Failed to allocate unique temporary path");
    }
    return nil;
}

- (NSData *)chmodWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }
    if (![request[@"mode"] isKindOfClass:[NSNumber class]]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"chmod mode is required");
        }
        return nil;
    }
    if (chmod(path.fileSystemRepresentation, (mode_t)([(NSNumber *)request[@"mode"] unsignedIntValue] & 07777u)) != 0) {
        int chmodErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(chmodErrno), @"Failed to chmod path", chmodErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)chownWithRequest:(NSDictionary *)request followSymlink:(BOOL)followSymlink error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }
    if (!EJSFSNumberIsNonNegative(request[@"uid"]) || !EJSFSNumberIsNonNegative(request[@"gid"])) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"chown uid and gid are required");
        }
        return nil;
    }

    uid_t uid = (uid_t)[(NSNumber *)request[@"uid"] unsignedIntValue];
    gid_t gid = (gid_t)[(NSNumber *)request[@"gid"] unsignedIntValue];
    int result = followSymlink
        ? chown(path.fileSystemRepresentation, uid, gid)
        : lchown(path.fileSystemRepresentation, uid, gid);
    if (result != 0) {
        int chownErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(chownErrno), @"Failed to chown path", chownErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)utimeWithRequest:(NSDictionary *)request followSymlink:(BOOL)followSymlink error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }
    if (![request[@"atimeMs"] isKindOfClass:[NSNumber class]] ||
        ![request[@"mtimeMs"] isKindOfClass:[NSNumber class]]) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"utime atimeMs and mtimeMs are required");
        }
        return nil;
    }

    double atimeMs = [(NSNumber *)request[@"atimeMs"] doubleValue];
    double mtimeMs = [(NSNumber *)request[@"mtimeMs"] doubleValue];
    struct timeval times[2];
    times[0].tv_sec = (time_t)(atimeMs / 1000.0);
    times[0].tv_usec = (suseconds_t)((atimeMs - (double)times[0].tv_sec * 1000.0) * 1000.0);
    times[1].tv_sec = (time_t)(mtimeMs / 1000.0);
    times[1].tv_usec = (suseconds_t)((mtimeMs - (double)times[1].tv_sec * 1000.0) * 1000.0);

    int result = followSymlink
        ? utimes(path.fileSystemRepresentation, times)
        : lutimes(path.fileSystemRepresentation, times);
    if (result != 0) {
        int utimeErrno = errno;
        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(EJSFSProviderCodeForErrno(utimeErrno), @"Failed to update path times", utimeErrno);
        }
        return nil;
    }
    return EJSFSOKData();
}

- (NSData *)renameWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *sourceError = nil;
    NSString *sourcePath = [self resolvedPathForRequest:request read:NO error:&sourceError];
    if (sourcePath == nil) {
        if (error != NULL) {
            *error = sourceError;
        }
        return nil;
    }

    NSMutableDictionary *destinationRequest = [request mutableCopy];
    if (destinationRequest[@"newRoot"] == nil && destinationRequest[@"root"] != nil) {
        destinationRequest[@"newRoot"] = destinationRequest[@"root"];
    }

    NSError *destinationError = nil;
    NSString *destinationPath = [self resolvedPathForRequest:destinationRequest
                                                     pathKey:@"newPath"
                                                     rootKey:@"newRoot"
                                                        read:NO
                                                       error:&destinationError];
    if (destinationPath == nil) {
        if (error != NULL) {
            *error = destinationError;
        }
        return nil;
    }

    const char *sourceFSPath = sourcePath.fileSystemRepresentation;
    const char *destinationFSPath = destinationPath.fileSystemRepresentation;
    if (sourceFSPath == NULL || destinationFSPath == NULL) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Invalid fs rename path");
        }
        return nil;
    }

    if (rename(sourceFSPath, destinationFSPath) != 0) {
        int renameErrno = errno;
        EJSProviderErrorCode code = EJSProviderErrorCodeInternal;
        if (renameErrno == ENOENT ||
            renameErrno == EEXIST ||
            renameErrno == ENOTEMPTY ||
            renameErrno == EISDIR ||
            renameErrno == ENOTDIR) {
            code = EJSProviderErrorCodeInvalidArgument;
        } else if (renameErrno == EACCES || renameErrno == EPERM) {
            code = EJSProviderErrorCodeSecurity;
        }

        if (error != NULL) {
            *error = EJSFSProviderErrorForErrno(code, @"Failed to rename path", renameErrno);
        }
        return nil;
    }

    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)deletePathWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSError *resolveError = nil;
    NSString *path = [self resolvedPathForRequest:request read:NO error:&resolveError];
    if (path == nil) {
        if (error != NULL) {
            *error = resolveError;
        }
        return nil;
    }

    BOOL recursive = EJSFSBoolValue(request[@"recursive"], NO);
    BOOL force = EJSFSBoolValue(request[@"force"], NO);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    BOOL exists = [fileManager fileExistsAtPath:path isDirectory:&isDirectory];
    BOOL isSymlink = [fileManager destinationOfSymbolicLinkAtPath:path error:nil] != nil;

    if (!exists && !isSymlink) {
        if (force) {
            return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument, @"Path does not exist");
        }
        return nil;
    }

    if (isDirectory && !isSymlink && !recursive) {
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInvalidArgument,
                                        @"Directory delete requires recursive option");
        }
        return nil;
    }

    NSError *deleteError = nil;
    if (![fileManager removeItemAtPath:path error:&deleteError]) {
        if (force && [deleteError.domain isEqualToString:NSCocoaErrorDomain] &&
            deleteError.code == NSFileNoSuchFileError) {
            return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        }
        if (error != NULL) {
            *error = EJSFSProviderError(EJSProviderErrorCodeInternal,
                                        deleteError.localizedDescription ?: @"Failed to delete path");
        }
        return nil;
    }

    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

@end

BOOL EJSFileSystemInstallIntoContext(EJSContext *context, NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    NSString *json = [context configurationValueForKey:EJSFileSystemConfigurationKey];
    EJSFileSystemPolicy *policy = EJSFileSystemPolicyFromJSON(json, error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSFS" ], error)) {
        return NO;
    }

    EJSFileSystemProvider *provider = [[EJSFileSystemProvider alloc] initWithPolicy:policy];
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, provider, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < ejs_fs_scripts_count; ++i) {
#ifdef EJS_TEST
        if (g_ejs_fs_apple_test_fail_script_index >= 0 &&
            (size_t)g_ejs_fs_apple_test_fail_script_index == i) {
            if (error != NULL) {
                *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInternal, @"EJSFS test install sentinel");
            }
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
#endif

        const EJSFSBundledScript *script = &ejs_fs_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                           @"EJSFS bundled script must be valid UTF-8");
            }
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }

        if (![context evaluateScript:source filename:filename error:error]) {
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
    }

    if (!EJSAppleInstallTransactionCommit(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    return YES;
}

#ifdef EJS_TEST
static BOOL EJSFSTestFail(NSString *message, NSError **error) {
    if (error != NULL) {
        *error = EJSFSRuntimeError(EJSRuntimeErrorCodeInternal,
                                   message.length > 0u ? message : @"EJSFS internal coverage check failed");
    }
    return NO;
}

static BOOL EJSFSTestRequire(BOOL condition, NSString *message, NSError **error) {
    if (condition) {
        return YES;
    }
    return EJSFSTestFail(message, error);
}

static NSString * EJSFSTestJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#define EJSFS_TEST_REQUIRE(condition, message) \
    do { \
        if (!EJSFSTestRequire((condition), (message), error)) { \
            return NO; \
        } \
    } while (0)

BOOL EJSFileSystemAppleTestExerciseInternalCoverage(NSString *basePath, NSError **error) {
    NSError *expectedFailure = nil;
    (void)EJSFSTestRequire(NO, @"expected test failure path", &expectedFailure);
    EJSFS_TEST_REQUIRE(expectedFailure != nil, @"test require failure branch did not set an error");
    EJSContext *nilContext = nil;
    EJSFS_TEST_REQUIRE(EJSFileSystemInstallIntoContext(nilContext, &expectedFailure) == NO,
                       @"nil context install should fail");

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *rootPath = [basePath stringByAppendingPathComponent:@"internal-coverage"];
    NSString *documentsPath = [rootPath stringByAppendingPathComponent:@"documents"];
    NSString *readOnlyPath = [rootPath stringByAppendingPathComponent:@"read-only"];
    NSString *writeOnlyPath = [rootPath stringByAppendingPathComponent:@"write-only"];
    NSString *outsidePath = [rootPath stringByAppendingPathComponent:@"outside"];
    [fileManager removeItemAtPath:rootPath error:nil];
    EJSFS_TEST_REQUIRE([fileManager createDirectoryAtPath:documentsPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil],
                       @"failed to create documents coverage root");
    EJSFS_TEST_REQUIRE([fileManager createDirectoryAtPath:readOnlyPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil],
                       @"failed to create read-only coverage root");
    EJSFS_TEST_REQUIRE([fileManager createDirectoryAtPath:writeOnlyPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil],
                       @"failed to create write-only coverage root");
    EJSFS_TEST_REQUIRE([fileManager createDirectoryAtPath:outsidePath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil],
                       @"failed to create outside coverage root");

    NSString *filePath = [documentsPath stringByAppendingPathComponent:@"file.txt"];
    NSString *smallPath = [documentsPath stringByAppendingPathComponent:@"small.txt"];
    NSString *escapeLinkPath = [documentsPath stringByAppendingPathComponent:@"escape-link"];
    NSString *outsideFilePath = [outsidePath stringByAppendingPathComponent:@"outside.txt"];
    EJSFS_TEST_REQUIRE([@"hello" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil],
                       @"failed to seed file.txt");
    EJSFS_TEST_REQUIRE([@"abc" writeToFile:smallPath atomically:YES encoding:NSUTF8StringEncoding error:nil],
                       @"failed to seed small.txt");
    EJSFS_TEST_REQUIRE([@"outside" writeToFile:outsideFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil],
                       @"failed to seed outside file");
    EJSFS_TEST_REQUIRE([fileManager createSymbolicLinkAtPath:escapeLinkPath
                                         withDestinationPath:outsidePath
                                                       error:nil],
                       @"failed to seed escape symlink");

    NSError *operationError = nil;
    NSData *emptyData = [NSData data];
    NSData *arrayData = [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *objectData = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    EJSFS_TEST_REQUIRE(EJSFSPathIsInsideRoot(@"/tmp/ejs", @"/"), @"root slash containment failed");
    EJSFS_TEST_REQUIRE(EJSFSPathIsInsideRoot(filePath, documentsPath), @"exact/prefix containment failed");
    EJSFS_TEST_REQUIRE(!EJSFSPathIsInsideRoot(outsideFilePath, documentsPath), @"outside containment should fail");
    EJSFS_TEST_REQUIRE(EJSFSPathHasParentTraversal(@"a/../b"), @"parent traversal not detected");
    EJSFS_TEST_REQUIRE(!EJSFSPathHasParentTraversal(@"a/b"), @"false parent traversal positive");
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSJSONObjectFromData(emptyData, &operationError) == nil && operationError != nil,
                       @"empty payload should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSJSONObjectFromData(arrayData, &operationError) == nil && operationError != nil,
                       @"array payload should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSJSONObjectFromData(objectData, &operationError) != nil && operationError == nil,
                       @"object payload should parse");
    EJSFS_TEST_REQUIRE(EJSFSProviderCodeForErrno(ENOENT) == EJSProviderErrorCodeInvalidArgument,
                       @"ENOENT should map to invalid argument");
    EJSFS_TEST_REQUIRE(EJSFSProviderCodeForErrno(EACCES) == EJSProviderErrorCodeSecurity,
                       @"EACCES should map to security");
    EJSFS_TEST_REQUIRE(EJSFSProviderCodeForErrno(ENOSPC) == EJSProviderErrorCodeInternal,
                       @"ENOSPC should map to internal");

    struct stat fakeStat;
    memset(&fakeStat, 0, sizeof(fakeStat));
    fakeStat.st_mode = S_IFDIR;
    EJSFS_TEST_REQUIRE([EJSFSStatDictionaryFromStruct(fakeStat)[@"type"] isEqualToString:@"directory"],
                       @"directory stat type not covered");
    fakeStat.st_mode = S_IFIFO;
    EJSFS_TEST_REQUIRE([EJSFSStatDictionaryFromStruct(fakeStat)[@"type"] isEqualToString:@"other"],
                       @"other stat type not covered");

    EJSFS_TEST_REQUIRE(EJSFSValidateOptionalEncoding(@{}, &operationError), @"nil encoding should pass");
    EJSFS_TEST_REQUIRE(EJSFSValidateOptionalEncoding(@{ @"encoding": [NSNull null] }, &operationError),
                       @"null encoding should pass");
    operationError = nil;
    EJSFS_TEST_REQUIRE(!EJSFSValidateOptionalEncoding(@{ @"encoding": @1 }, &operationError) &&
                       operationError != nil,
                       @"numeric encoding should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(!EJSFSValidateOptionalEncoding(@{ @"encoding": @"latin1" }, &operationError) &&
                       operationError != nil,
                       @"latin1 encoding should reject");
    EJSFS_TEST_REQUIRE(EJSFSValidateOptionalEncoding(@{ @"encoding": @"UTF-8" }, &operationError),
                       @"utf-8 encoding should pass");

    EJSFS_TEST_REQUIRE(EJSFSUnsignedLimit(@"bad", 7) == 7, @"non-number limit should default");
    EJSFS_TEST_REQUIRE(EJSFSUnsignedLimit(@-1, 7) == 7, @"negative limit should default");
    EJSFS_TEST_REQUIRE(EJSFSUnsignedLimit(@9, 7) == 9, @"positive limit should survive");
    EJSFS_TEST_REQUIRE(EJSFSBoolValue(@"bad", YES), @"non-number bool should default");
    EJSFS_TEST_REQUIRE(!EJSFSBoolValue(@NO, YES), @"number bool should apply");

    operationError = nil;
    EJSFS_TEST_REQUIRE([EJSFSAccessMode(@{}, &operationError) isEqualToString:@"read"],
                       @"default access mode should be read");
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSAccessMode(@{ @"mode": @1 }, &operationError) == nil && operationError != nil,
                       @"numeric access mode should reject");
    EJSFS_TEST_REQUIRE([EJSFSAccessMode(@{ @"mode": @"r" }, &operationError) isEqualToString:@"read"],
                       @"r access mode should normalize");
    EJSFS_TEST_REQUIRE([EJSFSAccessMode(@{ @"mode": @"w" }, &operationError) isEqualToString:@"write"],
                       @"w access mode should normalize");
    EJSFS_TEST_REQUIRE([EJSFSAccessMode(@{ @"mode": @"rw" }, &operationError) isEqualToString:@"readwrite"],
                       @"rw access mode should normalize");
    EJSFS_TEST_REQUIRE([EJSFSAccessMode(@{ @"mode": @"readwrite" }, &operationError) isEqualToString:@"readwrite"],
                       @"readwrite access mode should pass through");
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSAccessMode(@{ @"mode": @"execute" }, &operationError) == nil && operationError != nil,
                       @"unsupported access mode should reject");

    BOOL readable = NO;
    BOOL writable = NO;
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSOpenFlags(@"r+", &readable, &writable, &operationError) >= 0 && readable && writable,
                       @"r+ flag should be read/write");
    EJSFS_TEST_REQUIRE(EJSFSOpenFlags(@"a", &readable, &writable, &operationError) >= 0 && !readable && writable,
                       @"a flag should be append/write");
    EJSFS_TEST_REQUIRE(EJSFSOpenFlags(@"ax", &readable, &writable, &operationError) >= 0 && !readable && writable,
                       @"ax flag should be append exclusive");
    EJSFS_TEST_REQUIRE(EJSFSOpenFlags(@"a+", &readable, &writable, &operationError) >= 0 && readable && writable,
                       @"a+ flag should be read/write append");
    EJSFS_TEST_REQUIRE(EJSFSOpenFlags(@"ax+", &readable, &writable, &operationError) >= 0 && readable && writable,
                       @"ax+ flag should be read/write exclusive append");
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFSOpenFlags(@"bad", &readable, &writable, &operationError) < 0 && operationError != nil,
                       @"bad open flag should reject");

    unichar loneSurrogate = 0xD800;
    NSString *badUTF8 = [NSString stringWithCharacters:&loneSurrogate length:1];
    NSArray<NSString *> *invalidConfigs = @[
        badUTF8,
        @"{",
        @"[]",
        @"{\"version\":2,\"defaultRoot\":\"documents\",\"roots\":{}}",
        @"{\"version\":1,\"defaultRoot\":\"\",\"roots\":{}}",
        @"{\"version\":1,\"defaultRoot\":\"documents\",\"roots\":{\"documents\":{\"path\":\"relative\",\"permissions\":[\"read\"]}}}",
        @"{\"version\":1,\"defaultRoot\":\"missing\",\"roots\":{\"documents\":{\"path\":\"/tmp\",\"permissions\":[\"read\"]}}}"
    ];
    for (NSString *invalidConfig in invalidConfigs) {
        operationError = nil;
        EJSFS_TEST_REQUIRE(EJSFileSystemPolicyFromJSON(invalidConfig, &operationError) == nil && operationError != nil,
                           @"invalid config should reject");
    }

    NSString *fileRootPath = [rootPath stringByAppendingPathComponent:@"root-file"];
    EJSFS_TEST_REQUIRE([@"root-file" writeToFile:fileRootPath atomically:YES encoding:NSUTF8StringEncoding error:nil],
                       @"failed to seed root-file");
    NSString *createFailConfig = EJSFSTestJSONString(@{
        @"version": @1,
        @"defaultRoot": @"documents",
        @"roots": @{
            @"documents": @{
                @"path": fileRootPath,
                @"permissions": @[ @"read" ],
                @"createIfMissing": @YES
            }
        }
    });
    operationError = nil;
    EJSFS_TEST_REQUIRE(EJSFileSystemPolicyFromJSON(createFailConfig, &operationError) == nil && operationError != nil,
                       @"root create failure should reject");

    NSString *skipCreatePath = [rootPath stringByAppendingPathComponent:@"skip-create"];
    NSString *validConfig = EJSFSTestJSONString(@{
        @"version": @1,
        @"defaultRoot": @"documents",
        @"roots": @{
            @"documents": @{
                @"path": skipCreatePath,
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @NO
            }
        },
        @"limits": @{
            @"maxReadBytes": @-1,
            @"maxWriteBytes": @"bad"
        },
        @"pathPolicy": @{
            @"allowAbsolutePath": @"bad"
        }
    });
    operationError = nil;
    EJSFileSystemPolicy *validParsedPolicy = EJSFileSystemPolicyFromJSON(validConfig, &operationError);
    EJSFS_TEST_REQUIRE(validParsedPolicy != nil &&
                       validParsedPolicy.maxReadBytes == EJSFSDefaultLimitBytes &&
                       validParsedPolicy.maxWriteBytes == EJSFSDefaultLimitBytes &&
                       ![fileManager fileExistsAtPath:skipCreatePath],
                       @"valid config defaults/skip-create failed");

    EJSFileSystemRootPolicy *documentsRoot =
        [[EJSFileSystemRootPolicy alloc] initWithName:@"documents"
                                                 path:documentsPath
                                              canRead:YES
                                             canWrite:YES
                                      createIfMissing:NO];
    EJSFileSystemRootPolicy *readOnlyRoot =
        [[EJSFileSystemRootPolicy alloc] initWithName:@"readOnly"
                                                 path:readOnlyPath
                                              canRead:YES
                                             canWrite:NO
                                      createIfMissing:NO];
    EJSFileSystemRootPolicy *writeOnlyRoot =
        [[EJSFileSystemRootPolicy alloc] initWithName:@"writeOnly"
                                                 path:writeOnlyPath
                                              canRead:NO
                                             canWrite:YES
                                      createIfMissing:NO];
    EJSFileSystemPolicy *policy =
        [[EJSFileSystemPolicy alloc] initWithDefaultRoot:@"documents"
                                                   roots:@{
                                                       @"documents": documentsRoot,
                                                       @"readOnly": readOnlyRoot,
                                                       @"writeOnly": writeOnlyRoot
                                                   }
                                            maxReadBytes:4
                                           maxWriteBytes:4
                                       allowAbsolutePath:NO
                                    allowParentTraversal:NO
                                      allowSymlinkEscape:NO];
    EJSFileSystemProvider *provider = [[EJSFileSystemProvider alloc] initWithPolicy:policy];

    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider resolvedPathForRequest:@{ @"path": @"file.txt", @"root": @"writeOnly" }
                                                   read:YES
                                                  error:&operationError] == nil &&
                       operationError != nil),
                       @"read-denied root should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider resolvedPathForRequest:@{ @"path": @"new.txt", @"root": @"readOnly" }
                                                   read:NO
                                                  error:&operationError] == nil &&
                       operationError != nil),
                       @"write-denied root should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE([provider resolvedPathForRequest:@{ @"path": filePath }
                                                   read:YES
                                                  error:&operationError] == nil &&
                       operationError != nil,
                       @"absolute path should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE([provider resolvedPathForRequest:@{ @"path": @"../outside.txt" }
                                                   read:YES
                                                  error:&operationError] == nil &&
                       operationError != nil,
                       @"parent traversal should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE([provider resolvedPathForRequest:@{ @"path": @"escape-link/outside.txt" }
                                                   read:YES
                                                  error:&operationError] == nil &&
                       operationError != nil,
                       @"symlink escape should reject");

    EJSFileSystemRootPolicy *slashRoot =
        [[EJSFileSystemRootPolicy alloc] initWithName:@"slash"
                                                 path:@"/"
                                              canRead:YES
                                             canWrite:NO
                                      createIfMissing:NO];
    EJSFileSystemPolicy *absolutePolicy =
        [[EJSFileSystemPolicy alloc] initWithDefaultRoot:@"slash"
                                                   roots:@{ @"slash": slashRoot }
                                            maxReadBytes:1024
                                           maxWriteBytes:1024
                                       allowAbsolutePath:YES
                                    allowParentTraversal:NO
                                      allowSymlinkEscape:YES];
    EJSFileSystemProvider *absoluteProvider = [[EJSFileSystemProvider alloc] initWithPolicy:absolutePolicy];
    operationError = nil;
    EJSFS_TEST_REQUIRE(([absoluteProvider readFileWithRequest:@{ @"path": filePath } error:&operationError] != nil &&
                        operationError == nil),
                       @"absolute read with slash root should succeed");

    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider readFileWithRequest:@{ @"path": @"file.txt" } error:&operationError] == nil &&
                        operationError != nil),
                       @"readFile should enforce maxReadBytes");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider writeFileWithRequest:@{ @"path": @"too-large.txt" }
                                        transferBuffer:[NSMutableData dataWithLength:8u]
                                                 error:&operationError] == nil &&
                        operationError != nil),
                       @"writeFile should enforce maxWriteBytes");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider writeFileWithRequest:@{ @"path": @"bad-flag.txt", @"flag": @"append" }
                                        transferBuffer:[@"x" dataUsingEncoding:NSUTF8StringEncoding]
                                                 error:&operationError] == nil &&
                        operationError != nil),
                       @"writeFile should reject unsupported flag");

    NSData *response = nil;
    operationError = nil;
    response = [provider openFileWithRequest:@{ @"path": @"file.txt", @"flags": @"r+" } error:&operationError];
    EJSFS_TEST_REQUIRE(response != nil && operationError == nil, @"r+ open should succeed");
    NSDictionary *handleResponse = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    NSString *handle = handleResponse[@"handle"];
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider readOpenFileWithRequest:@{ @"handle": handle, @"length": @8 } error:&operationError] == nil &&
                        operationError != nil),
                       @"read handle should enforce maxReadBytes");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider readOpenFileWithRequest:@{ @"handle": handle, @"length": @2, @"position": @0 } error:&operationError] != nil &&
                        operationError == nil),
                       @"positioned read should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider writeOpenFileWithRequest:@{ @"handle": handle }
                                            transferBuffer:[NSMutableData dataWithLength:8u]
                                                     error:&operationError] == nil &&
                        operationError != nil),
                       @"write handle should enforce maxWriteBytes");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider truncateOpenFileWithRequest:@{ @"handle": handle, @"length": @8 } error:&operationError] == nil &&
                        operationError != nil),
                       @"truncate handle should enforce maxWriteBytes");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider syncOpenFileWithRequest:@{ @"handle": handle } datasync:NO error:&operationError] != nil &&
                        operationError == nil),
                       @"sync handle should succeed");
    EJSFS_TEST_REQUIRE([provider closeOpenFileWithRequest:@{ @"handle": handle } error:&operationError] != nil,
                       @"r+ close should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider openFileForRequest:@{} error:&operationError] == nil &&
                        operationError != nil),
                       @"missing file handle should reject");

    for (NSString *flag in @[ @"a", @"ax", @"a+", @"ax+" ]) {
        operationError = nil;
        NSString *name = [NSString stringWithFormat:@"open-%@.txt", [flag stringByReplacingOccurrencesOfString:@"+" withString:@"p"]];
        response = [provider openFileWithRequest:@{ @"path": name, @"flags": flag } error:&operationError];
        EJSFS_TEST_REQUIRE(response != nil && operationError == nil, @"append open should succeed");
        handleResponse = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
        EJSFS_TEST_REQUIRE([provider closeOpenFileWithRequest:@{ @"handle": handleResponse[@"handle"] } error:&operationError] != nil,
                           @"append close should succeed");
    }
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider openFileWithRequest:@{ @"path": @"file.txt", @"flags": @"unsupported" } error:&operationError] == nil &&
                       operationError != nil),
                       @"unsupported open should fail");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider openFileWithRequest:@{ @"path": @"file.txt", @"root": @"writeOnly", @"flags": @"r" } error:&operationError] == nil &&
                       operationError != nil),
                       @"open read-denied root should fail");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider openFileWithRequest:@{ @"path": @"new.txt", @"root": @"readOnly", @"flags": @"w" } error:&operationError] == nil &&
                       operationError != nil),
                       @"open write-denied root should fail");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider statPathWithRequest:@{ @"path": @"../outside.txt" } error:&operationError] == nil &&
                        operationError != nil),
                       @"stat should propagate resolve failure");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider lstatPathWithRequest:@{ @"path": @"missing-lstat.txt" } error:&operationError] == nil &&
                        operationError != nil),
                       @"lstat missing path should fail");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider accessPathWithRequest:@{ @"path": @"file.txt", @"mode": @"read" } error:&operationError] != nil &&
                        operationError == nil),
                       @"access read should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider accessPathWithRequest:@{ @"path": @"file.txt", @"root": @"writeOnly", @"mode": @"read" } error:&operationError] == nil &&
                        operationError != nil),
                       @"access read-denied root should fail");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider copyFileWithRequest:@{ @"path": @"file.txt", @"newPath": @"copy-too-large.txt" } error:&operationError] == nil &&
                        operationError != nil),
                       @"copyFile should enforce size limits");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider linkWithRequest:@{ @"path": @"file.txt", @"newPath": @"hardlink.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"hard link should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider symlinkWithRequest:@{ @"path": @"symlink.txt", @"target": @"file.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"symlink should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider chmodWithRequest:@{ @"path": @"file.txt", @"mode": @0644 } error:&operationError] != nil &&
                        operationError == nil),
                       @"chmod should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider readFileWithRequest:@{ @"path": @"small.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"small readFile should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider writeFileWithRequest:@{ @"path": @"write-ok.txt" }
                                        transferBuffer:[@"data" dataUsingEncoding:NSUTF8StringEncoding]
                                                 error:&operationError] != nil &&
                        operationError == nil),
                       @"small writeFile should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider statPathWithRequest:@{ @"path": @"small.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"stat file should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider lstatPathWithRequest:@{ @"path": @"symlink.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"lstat symlink should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider existsPathWithRequest:@{ @"path": @"small.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"exists file should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider existsPathWithRequest:@{ @"path": @"missing-exists.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"exists missing path should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider readDirectoryWithRequest:@{ @"path": @"." } error:&operationError] != nil &&
                        operationError == nil),
                       @"readDirectory should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider createDirectoryWithRequest:@{ @"path": @"created-dir" } error:&operationError] != nil &&
                        operationError == nil),
                       @"createDirectory should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider createDirectoryWithRequest:@{ @"path": @"created-dir", @"recursive": @YES } error:&operationError] != nil &&
                        operationError == nil),
                       @"recursive existing directory should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider copyFileWithRequest:@{ @"path": @"small.txt", @"newPath": @"small-copy.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"copyFile should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider copyFileWithRequest:@{ @"path": @"small.txt", @"newPath": @"small-copy.txt", @"flag": @"wx" } error:&operationError] == nil &&
                        operationError != nil),
                       @"copyFile wx should reject existing destination");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider readLinkWithRequest:@{ @"path": @"symlink.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"readLink should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider symlinkWithRequest:@{ @"path": @"bad-symlink.txt", @"target": @"../outside.txt" } error:&operationError] == nil &&
                        operationError != nil),
                       @"symlink escape target should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider statFSWithRequest:@{ @"path": @"." } error:&operationError] != nil &&
                        operationError == nil),
                       @"statFS should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider makeTempPathWithRequest:@{ @"path": @".", @"prefix": @"tmpdir-" } directory:YES error:&operationError] != nil &&
                        operationError == nil),
                       @"make temp directory should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider makeTempPathWithRequest:@{ @"path": @".", @"prefix": @"tmpfile-" } directory:NO error:&operationError] != nil &&
                        operationError == nil),
                       @"make temp file should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider makeTempPathWithRequest:@{ @"path": @".", @"prefix": @"bad/name" } directory:NO error:&operationError] == nil &&
                        operationError != nil),
                       @"make temp should reject path prefix");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider chmodWithRequest:@{ @"path": @"small.txt" } error:&operationError] == nil &&
                        operationError != nil),
                       @"chmod missing mode should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider chownWithRequest:@{ @"path": @"small.txt" } followSymlink:YES error:&operationError] == nil &&
                        operationError != nil),
                       @"chown missing ids should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider utimeWithRequest:@{ @"path": @"small.txt" } followSymlink:YES error:&operationError] == nil &&
                        operationError != nil),
                       @"utime missing times should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider utimeWithRequest:@{ @"path": @"small.txt", @"atimeMs": @1000, @"mtimeMs": @2000 } followSymlink:YES error:&operationError] != nil &&
                        operationError == nil),
                       @"utime should succeed");
    EJSFS_TEST_REQUIRE([@"mv" writeToFile:[documentsPath stringByAppendingPathComponent:@"rename-source.txt"]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:nil],
                       @"failed to seed rename source");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider renameWithRequest:@{ @"path": @"rename-source.txt", @"newPath": @"rename-dest.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"rename should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider deletePathWithRequest:@{ @"path": @"created-dir" } error:&operationError] == nil &&
                        operationError != nil),
                       @"delete directory without recursive should reject");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider deletePathWithRequest:@{ @"path": @"created-dir", @"recursive": @YES } error:&operationError] != nil &&
                        operationError == nil),
                       @"delete directory recursive should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider deletePathWithRequest:@{ @"path": @"missing-delete.txt", @"force": @YES } error:&operationError] != nil &&
                        operationError == nil),
                       @"force delete missing path should succeed");
    operationError = nil;
    EJSFS_TEST_REQUIRE(([provider deletePathWithRequest:@{ @"path": @"rename-dest.txt" } error:&operationError] != nil &&
                        operationError == nil),
                       @"delete file should succeed");

    return YES;
}

#undef EJSFS_TEST_REQUIRE
#endif
