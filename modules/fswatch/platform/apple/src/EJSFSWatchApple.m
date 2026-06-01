#import "EJSFSWatchApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_fswatch_js_bundle.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const EJSFSWatchConfigurationKey = @"ejs.fswatch";

static NSError * EJSFSWatchRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSFSWatchProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"FSWatch provider failed");
}

static NSError * EJSFSWatchErrnoError(EJSProviderErrorCode code, NSString *operation, int errorNumber) {
    return EJSFSWatchProviderError(code, [NSString stringWithFormat:@"%@: %s", operation, strerror(errorNumber)]);
}

static BOOL EJSFSWatchStringIsNonEmpty(NSString *value) {
    return [value isKindOfClass:[NSString class]] && value.length > 0u;
}

static BOOL EJSFSWatchPathIsInsideRoot(NSString *path, NSString *rootPath) {
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *standardRoot = [rootPath stringByStandardizingPath];
    if ([standardRoot isEqualToString:@"/"]) return [standardPath hasPrefix:@"/"];
    return [standardPath isEqualToString:standardRoot] ||
        [standardPath hasPrefix:[standardRoot stringByAppendingString:@"/"]];
}

static BOOL EJSFSWatchPathHasParentTraversal(NSString *path) {
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@".."]) return YES;
    }
    return NO;
}

static NSDictionary * EJSFSWatchJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeInvalidArgument, @"fswatch payload is required");
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) *error = EJSFSWatchProviderError(EJSProviderErrorCodeInvalidArgument, @"fswatch payload must be a JSON object");
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData * EJSFSWatchJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSFSWatchProviderError(EJSProviderErrorCodeInternal, @"Failed to encode fswatch JSON response");
    }
    return data;
}

@interface EJSFSWatchRootPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *path;
- (instancetype)initWithName:(NSString *)name path:(NSString *)path;
@end

@implementation EJSFSWatchRootPolicy
- (instancetype)initWithName:(NSString *)name path:(NSString *)path {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _path = [[path stringByStandardizingPath] copy];
    }
    return self;
}
@end

@interface EJSFSWatchPolicy : NSObject
@property (nonatomic, copy, readonly) NSString *defaultRoot;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSFSWatchRootPolicy *> *roots;
@property (nonatomic, assign, readonly) BOOL allowAbsolutePath;
@property (nonatomic, assign, readonly) BOOL allowParentTraversal;
@property (nonatomic, assign, readonly) BOOL allowSymlinkEscape;
- (instancetype)initWithDefaultRoot:(NSString *)defaultRoot
                              roots:(NSDictionary<NSString *, EJSFSWatchRootPolicy *> *)roots
                  allowAbsolutePath:(BOOL)allowAbsolutePath
               allowParentTraversal:(BOOL)allowParentTraversal
                 allowSymlinkEscape:(BOOL)allowSymlinkEscape;
@end

@implementation EJSFSWatchPolicy
- (instancetype)initWithDefaultRoot:(NSString *)defaultRoot
                              roots:(NSDictionary<NSString *,EJSFSWatchRootPolicy *> *)roots
                  allowAbsolutePath:(BOOL)allowAbsolutePath
               allowParentTraversal:(BOOL)allowParentTraversal
                 allowSymlinkEscape:(BOOL)allowSymlinkEscape {
    self = [super init];
    if (self != nil) {
        _defaultRoot = [defaultRoot copy];
        _roots = [roots copy];
        _allowAbsolutePath = allowAbsolutePath;
        _allowParentTraversal = allowParentTraversal;
        _allowSymlinkEscape = allowSymlinkEscape;
    }
    return self;
}
@end

@interface EJSFSWatchHandle : NSObject
@property (nonatomic, copy, readonly) NSString *watcherID;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, copy, readonly) NSArray *sources;
- (instancetype)initWithWatcherID:(NSString *)watcherID path:(NSString *)path sources:(NSArray *)sources;
@end

@implementation EJSFSWatchHandle
- (instancetype)initWithWatcherID:(NSString *)watcherID path:(NSString *)path sources:(NSArray *)sources {
    self = [super init];
    if (self != nil) {
        _watcherID = [watcherID copy];
        _path = [path copy];
        _sources = [sources copy];
    }
    return self;
}
@end

@interface EJSFSWatchProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSFSWatchPolicy *)policy;
@end

static EJSFSWatchPolicy * EJSFSWatchPolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0u) {
        if (error != NULL) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Missing ejs.fswatch configuration");
        return nil;
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id value = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fswatch configuration must be a JSON object");
        return nil;
    }
    NSDictionary *object = (NSDictionary *)value;
    NSNumber *version = [object[@"version"] isKindOfClass:[NSNumber class]] ? object[@"version"] : nil;
    NSString *defaultRoot = [object[@"defaultRoot"] isKindOfClass:[NSString class]] ? object[@"defaultRoot"] : nil;
    NSDictionary *rootsObject = [object[@"roots"] isKindOfClass:[NSDictionary class]] ? object[@"roots"] : nil;
    if (version.integerValue != 1 || !EJSFSWatchStringIsNonEmpty(defaultRoot) || rootsObject.count == 0u) {
        if (error != NULL) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fswatch requires version, defaultRoot, and roots");
        return nil;
    }
    NSMutableDictionary *roots = [[NSMutableDictionary alloc] init];
    for (NSString *name in rootsObject) {
        NSDictionary *root = [rootsObject[name] isKindOfClass:[NSDictionary class]] ? rootsObject[name] : nil;
        NSString *path = [root[@"path"] isKindOfClass:[NSString class]] ? root[@"path"] : nil;
        if (!EJSFSWatchStringIsNonEmpty(name) || !EJSFSWatchStringIsNonEmpty(path) || !path.isAbsolutePath) {
            if (error != NULL) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fswatch roots require absolute paths");
            return nil;
        }
        roots[name] = [[EJSFSWatchRootPolicy alloc] initWithName:name path:path];
    }
    if (roots[defaultRoot] == nil) {
        if (error != NULL) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.fswatch defaultRoot must exist in roots");
        return nil;
    }
    NSDictionary *pathPolicy = [object[@"pathPolicy"] isKindOfClass:[NSDictionary class]] ? object[@"pathPolicy"] : @{};
    return [[EJSFSWatchPolicy alloc] initWithDefaultRoot:defaultRoot
                                                   roots:roots
                                       allowAbsolutePath:[pathPolicy[@"allowAbsolutePath"] boolValue]
                                    allowParentTraversal:[pathPolicy[@"allowParentTraversal"] boolValue]
                                      allowSymlinkEscape:[pathPolicy[@"allowSymlinkEscape"] boolValue]];
}

@implementation EJSFSWatchProvider {
    EJSFSWatchPolicy *_policy;
    dispatch_queue_t _queue;
    dispatch_queue_t _eventQueue;
    NSMutableDictionary<NSString *, EJSFSWatchHandle *> *_watchers;
    unsigned long long _nextWatcherID;
}

- (instancetype)initWithPolicy:(EJSFSWatchPolicy *)policy {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.fswatch";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.fswatch.provider", DISPATCH_QUEUE_SERIAL);
        _eventQueue = dispatch_queue_create("dev.ejs.fswatch.events", DISPATCH_QUEUE_SERIAL);
        _watchers = [[NSMutableDictionary alloc] init];
        _nextWatcherID = 1ull;
    }
    return self;
}

- (void)dealloc {
    @synchronized(_watchers) {
        for (EJSFSWatchHandle *watcher in _watchers.allValues) {
            for (id source in watcher.sources) {
                dispatch_source_cancel((dispatch_source_t)source);
            }
        }
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)transferBuffer;

    if (![methodID isEqualToString:@"watch"] && ![methodID isEqualToString:@"close"]) {
        [responder finishWithData:nil error:EJSFSWatchProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.fswatch method")];
        return [[EJSImmediateOperation alloc] init];
    }
    NSError *parseError = nil;
    NSDictionary *request = EJSFSWatchJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"watch"]) {
        NSError *error = nil;
        NSData *data = [self watchWithRequest:request context:context error:&error];
        [responder finishWithData:data error:error];
    } else {
        NSError *error = nil;
        NSData *data = [self closeWithRequest:request error:&error];
        [responder finishWithData:data error:error];
    }
    return [[EJSImmediateOperation alloc] init];
}

- (NSString *)resolvedPathForRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *requestPath = [request[@"path"] isKindOfClass:[NSString class]] ? request[@"path"] : nil;
    if (!EJSFSWatchStringIsNonEmpty(requestPath)) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeInvalidArgument, @"watch path is required");
        return nil;
    }
    NSString *rootName = [request[@"root"] isKindOfClass:[NSString class]] ? request[@"root"] : _policy.defaultRoot;
    EJSFSWatchRootPolicy *root = _policy.roots[rootName];
    if (root == nil) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeSecurity, @"fswatch root is not allowed");
        return nil;
    }
    if (requestPath.isAbsolutePath && !_policy.allowAbsolutePath) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeSecurity, @"Absolute fswatch paths are not allowed");
        return nil;
    }
    if (!_policy.allowParentTraversal && EJSFSWatchPathHasParentTraversal(requestPath)) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeSecurity, @"Parent traversal is not allowed");
        return nil;
    }
    NSString *targetPath = requestPath.isAbsolutePath ? requestPath : [root.path stringByAppendingPathComponent:requestPath];
    targetPath = [targetPath stringByStandardizingPath];
    NSString *rootCheckPath = _policy.allowSymlinkEscape ? root.path.stringByStandardizingPath : root.path.stringByResolvingSymlinksInPath;
    NSString *targetCheckPath = _policy.allowSymlinkEscape ? targetPath : targetPath.stringByResolvingSymlinksInPath;
    if (!EJSFSWatchPathIsInsideRoot(targetCheckPath, rootCheckPath)) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeSecurity, @"Resolved fswatch path escapes its root");
        return nil;
    }
    return targetPath;
}

- (NSData *)watchWithRequest:(NSDictionary *)request context:(EJSContext *)context error:(NSError **)error {
    if ([request[@"recursive"] boolValue]) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeUnsupported, @"Recursive fswatch is not supported by the Apple dispatch-source provider");
        return nil;
    }
    NSString *path = [self resolvedPathForRequest:request error:error];
    if (path == nil) return nil;

    struct stat pathStat;
    if (stat(path.fileSystemRepresentation, &pathStat) != 0) {
        if (error != NULL) *error = EJSFSWatchErrnoError(EJSProviderErrorCodeInvalidArgument, @"Failed to open watch path", errno);
        return nil;
    }

    NSString *watcherID = [NSString stringWithFormat:@"%llu", _nextWatcherID++];
    __weak EJSContext *weakContext = context;
    __weak EJSFSWatchProvider *weakSelf = self;
    NSString *eventPath = [request[@"path"] isKindOfClass:[NSString class]] ? request[@"path"] : path.lastPathComponent;
    dispatch_queue_t eventQueue = _eventQueue;
    NSMutableArray *sources = [[NSMutableArray alloc] init];
    dispatch_source_t (^makeSource)(NSString *, BOOL, NSError **) = ^dispatch_source_t(NSString *watchPath, BOOL directoryEntrySource, NSError **sourceError) {
        int fd = open(watchPath.fileSystemRepresentation, O_EVTONLY);
        if (fd < 0) {
            int openErrno = errno;
            if (sourceError != NULL) *sourceError = EJSFSWatchErrnoError(EJSProviderErrorCodeInvalidArgument, @"Failed to open watch path", openErrno);
            return nil;
        }
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                          (uintptr_t)fd,
                                                          DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_LINK | DISPATCH_VNODE_REVOKE,
                                                          _queue);
        if (source == nil) {
            close(fd);
            if (sourceError != NULL) *sourceError = EJSFSWatchProviderError(EJSProviderErrorCodeInternal, @"Failed to create dispatch source");
            return nil;
        }
        dispatch_source_set_event_handler(source, ^{
            unsigned long flags = dispatch_source_get_data(source);
            NSString *eventType = (directoryEntrySource || (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE))) ? @"rename" : @"change";
            dispatch_async(eventQueue, ^{
                EJSContext *strongContext = weakContext;
                if (strongContext == nil) return;
                EJSFSWatchProvider *strongSelf = weakSelf;
                if (strongSelf == nil) return;
                @synchronized(strongSelf->_watchers) {
                    if (strongSelf->_watchers[watcherID] == nil) return;
                }
                NSArray *args = @[ watcherID, eventType, eventPath ?: watchPath ];
                NSData *json = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
                NSString *jsonArgs = json != nil ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
                if (jsonArgs.length == 0u) return;
                NSString *script = [NSString stringWithFormat:@"globalThis.__EJSFSWatchDispatch && globalThis.__EJSFSWatchDispatch.apply(null, %@);", jsonArgs];
                [strongContext evaluateScript:script filename:@"ejs_fswatch_event.js" error:nil];
            });
        });
        dispatch_source_set_cancel_handler(source, ^{
            close(fd);
        });
        return source;
    };

    NSError *sourceError = nil;
    dispatch_source_t directSource = makeSource(path, NO, &sourceError);
    if (directSource == nil) {
        if (error != NULL) *error = sourceError;
        return nil;
    }
    [sources addObject:(id)directSource];

    if (!S_ISDIR(pathStat.st_mode)) {
        dispatch_source_t parentSource = makeSource(path.stringByDeletingLastPathComponent, YES, &sourceError);
        if (parentSource == nil) {
            dispatch_source_cancel(directSource);
            if (error != NULL) *error = sourceError;
            return nil;
        }
        [sources addObject:(id)parentSource];
    }

    @synchronized(_watchers) {
        _watchers[watcherID] = [[EJSFSWatchHandle alloc] initWithWatcherID:watcherID path:path sources:sources];
    }
    for (id source in sources) {
        dispatch_resume((dispatch_source_t)source);
    }
    return EJSFSWatchJSONData(@{ @"watcherID": watcherID, @"recursive": @NO }, error);
}

- (NSData *)closeWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *watcherID = [request[@"watcherID"] isKindOfClass:[NSString class]] ? request[@"watcherID"] : nil;
    __block EJSFSWatchHandle *watcher = nil;
    @synchronized(_watchers) {
        watcher = watcherID.length > 0u ? _watchers[watcherID] : nil;
        if (watcher != nil) {
            [_watchers removeObjectForKey:watcherID];
        }
    }
    if (watcher == nil) {
        if (error != NULL) *error = EJSFSWatchProviderError(EJSProviderErrorCodeInvalidArgument, @"watcher is closed or unknown");
        return nil;
    }
    for (id source in watcher.sources) {
        dispatch_source_cancel((dispatch_source_t)source);
    }
    return EJSFSWatchJSONData(@{ @"ok": @YES }, error);
}

@end

BOOL EJSFSWatchInstallIntoContext(EJSContext *context, NSError **error) {
    if (context == nil) {
        if (error != NULL) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        return NO;
    }
    EJSFSWatchPolicy *policy = EJSFSWatchPolicyFromJSON([context configurationValueForKey:EJSFSWatchConfigurationKey], error);
    if (policy == nil) {
        return NO;
    }
    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSFSWatch", @"__EJSFSWatchDispatch", @"__EJSFSWatchLastError" ], error)) {
        return NO;
    }
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, [[EJSFSWatchProvider alloc] initWithPolicy:policy], error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
    for (size_t i = 0u; i < ejs_fswatch_scripts_count; ++i) {
        const EJSFSWatchBundledScript *script = &ejs_fswatch_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) *error = EJSFSWatchRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"EJSFSWatch bundled script must be valid UTF-8");
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
