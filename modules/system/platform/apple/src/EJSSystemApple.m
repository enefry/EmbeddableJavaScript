#import "EJSSystemApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_system_js_bundle.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>

static NSError * EJSSystemRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSSystemProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"System provider failed");
}

static NSError * EJSSystemErrnoError(EJSProviderErrorCode code, NSString *operation, int errorNumber) {
    return EJSSystemProviderError(code, [NSString stringWithFormat:@"%@: %s", operation, strerror(errorNumber)]);
}

static NSDictionary * EJSSystemJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        return @{};
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSSystemProviderError(EJSProviderErrorCodeInvalidArgument, @"system payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData * EJSSystemJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSSystemProviderError(EJSProviderErrorCodeInternal, @"Failed to encode system JSON response");
    }
    return data;
}

static NSRecursiveLock * EJSSystemProcessStateLock(void) {
    static NSRecursiveLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSRecursiveLock alloc] init];
    });
    return lock;
}

static NSString * EJSSystemSafeUTF8String(const char *value) {
    if (value == NULL) {
        return @"";
    }
    NSString *string = [NSString stringWithUTF8String:value];
    if (string != nil) {
        return string;
    }
    size_t length = strlen(value);
    string = [[NSString alloc] initWithBytes:value length:length encoding:NSISOLatin1StringEncoding];
    return string ?: @"";
}

static NSString * EJSSystemSysctlString(const char *name) {
    size_t size = 0u;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0u) {
        return @"";
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (sysctlbyname(name, data.mutableBytes, &size, NULL, 0) != 0) {
        return @"";
    }
    NSString *value = [[NSString alloc] initWithBytes:data.bytes length:size encoding:NSUTF8StringEncoding];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]] ?: @"";
}

@interface EJSSystemProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@implementation EJSSystemProvider

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.system";
    }
    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)transferBuffer;
    (void)context;

    NSError *parseError = nil;
    NSDictionary *request = EJSSystemJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *operationError = nil;
    NSData *result = [self resultForMethod:methodID request:request error:&operationError];
    [responder finishWithData:result error:operationError];
    return [[EJSImmediateOperation alloc] init];
}

- (NSData *)resultForMethod:(NSString *)methodID request:(NSDictionary *)request error:(NSError **)error {
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];

    if ([methodID isEqualToString:@"cwd"]) {
        [EJSSystemProcessStateLock() lock];
        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath] ?: @"";
        [EJSSystemProcessStateLock() unlock];
        return EJSSystemJSONData(@{ @"cwd": cwd }, error);
    }
    if ([methodID isEqualToString:@"chdir"]) {
        NSString *path = [request[@"path"] isKindOfClass:[NSString class]] ? request[@"path"] : nil;
        if (path.length == 0u) {
            if (error != NULL) *error = EJSSystemProviderError(EJSProviderErrorCodeInvalidArgument, @"chdir path is required");
            return nil;
        }
        [EJSSystemProcessStateLock() lock];
        if (chdir(path.fileSystemRepresentation) != 0) {
            int chdirErrno = errno;
            [EJSSystemProcessStateLock() unlock];
            if (error != NULL) *error = EJSSystemErrnoError(EJSProviderErrorCodeInvalidArgument, @"Failed to change directory", chdirErrno);
            return nil;
        }
        [EJSSystemProcessStateLock() unlock];
        return EJSSystemJSONData(@{ @"ok": @YES }, error);
    }
    if ([methodID isEqualToString:@"env"]) {
        [EJSSystemProcessStateLock() lock];
        NSDictionary *environment = [processInfo.environment copy] ?: @{};
        [EJSSystemProcessStateLock() unlock];
        return EJSSystemJSONData(@{ @"env": environment }, error);
    }
    if ([methodID isEqualToString:@"getenv"]) {
        NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : nil;
        if (name.length == 0u) {
            if (error != NULL) *error = EJSSystemProviderError(EJSProviderErrorCodeInvalidArgument, @"environment variable name is required");
            return nil;
        }
        [EJSSystemProcessStateLock() lock];
        const char *value = getenv(name.UTF8String);
        id jsonValue = value != NULL ? EJSSystemSafeUTF8String(value) : [NSNull null];
        [EJSSystemProcessStateLock() unlock];
        return EJSSystemJSONData(@{ @"value": jsonValue }, error);
    }
    if ([methodID isEqualToString:@"setenv"]) {
        NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : nil;
        NSString *value = [request[@"value"] isKindOfClass:[NSString class]] ? request[@"value"] : nil;
        if (name.length == 0u || value == nil) {
            if (error != NULL) *error = EJSSystemProviderError(EJSProviderErrorCodeInvalidArgument, @"setenv name and value are required");
            return nil;
        }
        [EJSSystemProcessStateLock() lock];
        if (setenv(name.UTF8String, value.UTF8String, 1) != 0) {
            int setErrno = errno;
            [EJSSystemProcessStateLock() unlock];
            if (error != NULL) *error = EJSSystemErrnoError(EJSProviderErrorCodeInternal, @"Failed to set environment variable", setErrno);
            return nil;
        }
        [EJSSystemProcessStateLock() unlock];
        return EJSSystemJSONData(@{ @"ok": @YES }, error);
    }
    if ([methodID isEqualToString:@"unsetenv"]) {
        NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : nil;
        if (name.length == 0u) {
            if (error != NULL) *error = EJSSystemProviderError(EJSProviderErrorCodeInvalidArgument, @"unsetenv name is required");
            return nil;
        }
        [EJSSystemProcessStateLock() lock];
        if (unsetenv(name.UTF8String) != 0) {
            int unsetErrno = errno;
            [EJSSystemProcessStateLock() unlock];
            if (error != NULL) *error = EJSSystemErrnoError(EJSProviderErrorCodeInternal, @"Failed to unset environment variable", unsetErrno);
            return nil;
        }
        [EJSSystemProcessStateLock() unlock];
        return EJSSystemJSONData(@{ @"ok": @YES }, error);
    }
    if ([methodID isEqualToString:@"pid"]) return EJSSystemJSONData(@{ @"pid": @(getpid()) }, error);
    if ([methodID isEqualToString:@"ppid"]) return EJSSystemJSONData(@{ @"ppid": @(getppid()) }, error);
    if ([methodID isEqualToString:@"homeDir"]) return EJSSystemJSONData(@{ @"homeDir": NSHomeDirectory() ?: @"" }, error);
    if ([methodID isEqualToString:@"tmpDir"]) return EJSSystemJSONData(@{ @"tmpDir": NSTemporaryDirectory() ?: @"" }, error);
    if ([methodID isEqualToString:@"exePath"]) {
        NSString *exe = NSBundle.mainBundle.executablePath ?: processInfo.arguments.firstObject ?: @"";
        return EJSSystemJSONData(@{ @"exePath": exe }, error);
    }
    if ([methodID isEqualToString:@"hostName"]) return EJSSystemJSONData(@{ @"hostName": processInfo.hostName ?: @"" }, error);
    if ([methodID isEqualToString:@"platform"]) return EJSSystemJSONData(@{ @"platform": @"darwin" }, error);
    if ([methodID isEqualToString:@"arch"]) {
        struct utsname uts;
        uname(&uts);
        return EJSSystemJSONData(@{ @"arch": [NSString stringWithUTF8String:uts.machine] ?: @"" }, error);
    }
    if ([methodID isEqualToString:@"uname"]) {
        struct utsname uts;
        uname(&uts);
        NSDictionary *value = @{
            @"sysname": [NSString stringWithUTF8String:uts.sysname] ?: @"",
            @"nodename": [NSString stringWithUTF8String:uts.nodename] ?: @"",
            @"release": [NSString stringWithUTF8String:uts.release] ?: @"",
            @"version": [NSString stringWithUTF8String:uts.version] ?: @"",
            @"machine": [NSString stringWithUTF8String:uts.machine] ?: @""
        };
        return EJSSystemJSONData(@{ @"uname": value }, error);
    }
    if ([methodID isEqualToString:@"uptime"]) return EJSSystemJSONData(@{ @"uptime": @(processInfo.systemUptime) }, error);
    if ([methodID isEqualToString:@"loadAvg"]) {
        double values[3] = { 0.0, 0.0, 0.0 };
        int count = getloadavg(values, 3);
        NSArray *load = count > 0 ? @[ @(values[0]), @(values[1]), @(values[2]) ] : @[ @0, @0, @0 ];
        return EJSSystemJSONData(@{ @"loadAvg": load }, error);
    }
    if ([methodID isEqualToString:@"availableParallelism"]) {
        NSUInteger count = processInfo.activeProcessorCount > 0u ? processInfo.activeProcessorCount : processInfo.processorCount;
        return EJSSystemJSONData(@{ @"availableParallelism": @(MAX((NSUInteger)1u, count)) }, error);
    }
    if ([methodID isEqualToString:@"cpuInfo"]) {
        NSUInteger count = MAX((NSUInteger)1u, processInfo.processorCount);
        NSString *model = EJSSystemSysctlString("machdep.cpu.brand_string");
        NSMutableArray *cpus = [[NSMutableArray alloc] initWithCapacity:count];
        for (NSUInteger i = 0u; i < count; ++i) {
            [cpus addObject:@{ @"model": model ?: @"", @"speed": @0 }];
        }
        return EJSSystemJSONData(@{ @"cpuInfo": cpus }, error);
    }
    if ([methodID isEqualToString:@"networkInterfaces"]) {
        return EJSSystemJSONData(@{ @"networkInterfaces": [self networkInterfaces] }, error);
    }
    if ([methodID isEqualToString:@"userInfo"]) {
        struct passwd *pw = getpwuid(getuid());
        NSDictionary *value = @{
            @"uid": @(getuid()),
            @"gid": @(getgid()),
            @"username": NSUserName() ?: (pw != NULL ? EJSSystemSafeUTF8String(pw->pw_name) : @""),
            @"homedir": NSHomeDirectory() ?: (pw != NULL ? EJSSystemSafeUTF8String(pw->pw_dir) : @""),
            @"shell": pw != NULL ? EJSSystemSafeUTF8String(pw->pw_shell) : @""
        };
        return EJSSystemJSONData(@{ @"userInfo": value }, error);
    }

    if (error != NULL) {
        *error = EJSSystemProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.system method");
    }
    return nil;
}

- (NSDictionary *)networkInterfaces {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return @{};
    }

    NSMutableDictionary<NSString *, NSMutableArray *> *result = [[NSMutableDictionary alloc] init];
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_name == NULL) {
            continue;
        }
        int family = cursor->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) {
            continue;
        }

        char address[INET6_ADDRSTRLEN] = { 0 };
        void *src = NULL;
        NSString *familyName = @"";
        if (family == AF_INET) {
            src = &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr;
            familyName = @"IPv4";
        } else {
            src = &((struct sockaddr_in6 *)cursor->ifa_addr)->sin6_addr;
            familyName = @"IPv6";
        }
        if (inet_ntop(family, src, address, sizeof(address)) == NULL) {
            continue;
        }

        NSString *name = EJSSystemSafeUTF8String(cursor->ifa_name);
        NSMutableArray *entries = result[name];
        if (entries == nil) {
            entries = [[NSMutableArray alloc] init];
            result[name] = entries;
        }
        [entries addObject:@{
            @"address": EJSSystemSafeUTF8String(address),
            @"family": familyName,
            @"internal": @((cursor->ifa_flags & IFF_LOOPBACK) != 0)
        }];
    }
    freeifaddrs(interfaces);
    return result;
}

@end

BOOL EJSSystemInstallIntoContext(EJSContext *context, NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSSystemRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSSystem" ], error)) {
        return NO;
    }

    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, [[EJSSystemProvider alloc] init], error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < ejs_system_scripts_count; ++i) {
        const EJSSystemBundledScript *script = &ejs_system_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSSystemRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                               @"EJSSystem bundled script must be valid UTF-8");
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
