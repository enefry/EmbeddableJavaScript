#import "EJSKeyValueStoreApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include <limits.h>
#include <sqlite3.h>
#include <time.h>

#include "ejs_kv_js_bundle.h"

NSString * const EJSKeyValueStoreConfigurationKey = @"ejs.kv";

static const unsigned long long EJSKVDefaultMaxKeyBytes = 512ull;
static const unsigned long long EJSKVDefaultMaxValueBytes = 1024ull * 1024ull;
static const unsigned long long EJSKVDefaultMaxKeysPerList = 1000ull;

#ifdef EJS_TEST
static NSInteger g_ejs_kv_apple_test_fail_script_index = -1;
static BOOL g_ejs_kv_apple_test_force_config_utf8_failure = NO;
static BOOL g_ejs_kv_apple_test_force_json_encode_failure = NO;
static BOOL g_ejs_kv_apple_test_force_bind_key_invalid = NO;
static BOOL g_ejs_kv_apple_test_force_bind_value_too_large = NO;
static BOOL g_ejs_kv_apple_test_force_key_exists_step_failure = NO;
static BOOL g_ejs_kv_apple_test_force_count_keys_step_failure = NO;
static BOOL g_ejs_kv_apple_test_force_get_step_failure = NO;
static BOOL g_ejs_kv_apple_test_force_set_timestamp_bind_failure = NO;
static BOOL g_ejs_kv_apple_test_force_keys_step_failure = NO;

void EJSKeyValueStoreAppleTestSetInstallFailScriptIndex(NSInteger index) {
    g_ejs_kv_apple_test_fail_script_index = index;
}
#endif

static NSError * EJSKVRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSKVProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"Key-value provider failed");
}

static NSError * EJSKVSQLiteProviderError(sqlite3 *db, NSString *message) {
    const char *sqliteMessage = db != NULL ? sqlite3_errmsg(db) : NULL;
    NSString *detail = sqliteMessage != NULL ? [NSString stringWithUTF8String:sqliteMessage] : nil;
    if (detail.length == 0u) {
        detail = @"SQLite operation failed";
    }
    NSString *combined = message.length > 0u ? [NSString stringWithFormat:@"%@: %@", message, detail] : detail;
    return EJSKVProviderError(EJSProviderErrorCodeInternal, combined);
}

static BOOL EJSKVStringIsNonEmpty(NSString *value) {
    return [value isKindOfClass:[NSString class]] && value.length > 0u;
}

static BOOL EJSKVBoolValue(id value, BOOL defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    return [value boolValue];
}

static unsigned long long EJSKVUnsignedLimit(id value, unsigned long long defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    long long number = [value longLongValue];
    if (number < 0) {
        return defaultValue;
    }
    return (unsigned long long)number;
}

static NSDictionary * EJSKVJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInvalidArgument, @"kv payload must be a JSON object");
        }
        return nil;
    }

    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInvalidArgument, @"kv payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData * EJSKVJSONData(NSDictionary *object, NSError **error) {
    NSData *data = nil;
#ifdef EJS_TEST
    if (!g_ejs_kv_apple_test_force_json_encode_failure) {
#endif
        data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
#ifdef EJS_TEST
    }
#endif
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSKVProviderError(EJSProviderErrorCodeInternal, @"Failed to encode kv JSON response");
    }
    return data;
}

static dispatch_queue_t g_ejs_kv_store_lock_map_queue;
static NSMutableDictionary<NSString *, NSLock *> *g_ejs_kv_store_locks;

static NSLock * EJSKVLockForStorePath(NSString *storePath) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_ejs_kv_store_lock_map_queue = dispatch_queue_create("dev.ejs.kv.store-lock-map", DISPATCH_QUEUE_SERIAL);
        g_ejs_kv_store_locks = [[NSMutableDictionary alloc] init];
    });

    __block NSLock *storeLock = nil;
    dispatch_sync(g_ejs_kv_store_lock_map_queue, ^{
        storeLock = g_ejs_kv_store_locks[storePath];
        if (storeLock == nil) {
            storeLock = [[NSLock alloc] init];
            g_ejs_kv_store_locks[storePath] = storeLock;
        }
    });

    return storeLock;
}

@interface EJSKeyValueStorePolicy : NSObject
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

@implementation EJSKeyValueStorePolicy

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

@interface EJSKeyValuePolicy : NSObject
@property (nonatomic, copy, readonly) NSString *defaultStore;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSKeyValueStorePolicy *> *stores;
@property (nonatomic, assign, readonly) unsigned long long maxKeyBytes;
@property (nonatomic, assign, readonly) unsigned long long maxValueBytes;
@property (nonatomic, assign, readonly) unsigned long long maxKeysPerList;
- (instancetype)initWithDefaultStore:(NSString *)defaultStore
                               stores:(NSDictionary<NSString *, EJSKeyValueStorePolicy *> *)stores
                          maxKeyBytes:(unsigned long long)maxKeyBytes
                        maxValueBytes:(unsigned long long)maxValueBytes
                       maxKeysPerList:(unsigned long long)maxKeysPerList;
@end

@implementation EJSKeyValuePolicy

- (instancetype)initWithDefaultStore:(NSString *)defaultStore
                               stores:(NSDictionary<NSString *, EJSKeyValueStorePolicy *> *)stores
                          maxKeyBytes:(unsigned long long)maxKeyBytes
                        maxValueBytes:(unsigned long long)maxValueBytes
                       maxKeysPerList:(unsigned long long)maxKeysPerList {
    self = [super init];
    if (self != nil) {
        _defaultStore = [defaultStore copy];
        _stores = [stores copy];
        _maxKeyBytes = maxKeyBytes;
        _maxValueBytes = maxValueBytes;
        _maxKeysPerList = maxKeysPerList;
    }
    return self;
}

@end

@interface EJSKeyValueCancellation : NSObject
@property (atomic, assign, getter = isCancelled) BOOL cancelled;
@end

@implementation EJSKeyValueCancellation
@end

@interface EJSKeyValueProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSKeyValuePolicy *)policy;
#ifdef EJS_TEST
- (NSData *)resultForMethod:(NSString *)methodID
                    request:(NSDictionary *)request
             transferBuffer:(NSData *)transferBuffer
                      error:(NSError **)error;
- (BOOL)runSQL:(const char *)sql database:(sqlite3 *)db error:(NSError **)error;
- (sqlite3_stmt *)prepareSQL:(const char *)sql database:(sqlite3 *)db error:(NSError **)error;
- (BOOL)bindKey:(NSString *)key statement:(sqlite3_stmt *)statement index:(int)index database:(sqlite3 *)db error:(NSError **)error;
- (BOOL)bindValue:(NSData *)data statement:(sqlite3_stmt *)statement index:(int)index database:(sqlite3 *)db error:(NSError **)error;
#endif
@end

static EJSKeyValuePolicy * EJSKeyValuePolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0) {
        if (error != NULL) {
            *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Missing ejs.kv configuration");
        }
        return nil;
    }

    NSData *data = nil;
#ifdef EJS_TEST
    if (!g_ejs_kv_apple_test_force_config_utf8_failure) {
#endif
        data = [json dataUsingEncoding:NSUTF8StringEncoding];
#ifdef EJS_TEST
    }
#endif
    if (data == nil) {
        if (error != NULL) {
            *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.kv configuration must be valid UTF-8");
        }
        return nil;
    }

    NSError *jsonError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                       jsonError.localizedDescription ?: @"ejs.kv configuration must be a JSON object");
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    NSNumber *version = [object[@"version"] isKindOfClass:[NSNumber class]] ? object[@"version"] : nil;
    NSDictionary *storesObject = [object[@"stores"] isKindOfClass:[NSDictionary class]] ? object[@"stores"] : nil;
    NSString *defaultStore = [object[@"defaultStore"] isKindOfClass:[NSString class]] ? object[@"defaultStore"] : nil;
    if (version == nil || version.integerValue != 1 || !EJSKVStringIsNonEmpty(defaultStore) || storesObject.count == 0u) {
        if (error != NULL) {
            *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.kv requires version, defaultStore, and stores");
        }
        return nil;
    }

    NSMutableDictionary<NSString *, EJSKeyValueStorePolicy *> *stores = [[NSMutableDictionary alloc] init];
    for (NSString *storeName in storesObject) {
        if (!EJSKVStringIsNonEmpty(storeName)) {
            if (error != NULL) {
                *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.kv store names must be non-empty strings");
            }
            return nil;
        }

        NSDictionary *storeObject = [storesObject[storeName] isKindOfClass:[NSDictionary class]] ? storesObject[storeName] : nil;
        NSString *path = [storeObject[@"path"] isKindOfClass:[NSString class]] ? storeObject[@"path"] : nil;
        NSArray *permissions = [storeObject[@"permissions"] isKindOfClass:[NSArray class]] ? storeObject[@"permissions"] : nil;
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

        if (!EJSKVStringIsNonEmpty(path) || !path.isAbsolutePath || (!canRead && !canWrite)) {
            if (error != NULL) {
                *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.kv stores require absolute paths and permissions");
            }
            return nil;
        }

        stores[storeName] = [[EJSKeyValueStorePolicy alloc] initWithName:storeName
                                                                    path:path
                                                                 canRead:canRead
                                                                canWrite:canWrite
                                                         createIfMissing:EJSKVBoolValue(storeObject[@"createIfMissing"], NO)];
    }

    if (stores[defaultStore] == nil) {
        if (error != NULL) {
            *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.kv defaultStore must exist in stores");
        }
        return nil;
    }

    NSDictionary *limits = [object[@"limits"] isKindOfClass:[NSDictionary class]] ? object[@"limits"] : @{};
    EJSKeyValuePolicy *policy =
        [[EJSKeyValuePolicy alloc] initWithDefaultStore:defaultStore
                                                 stores:stores
                                            maxKeyBytes:EJSKVUnsignedLimit(limits[@"maxKeyBytes"], EJSKVDefaultMaxKeyBytes)
                                          maxValueBytes:EJSKVUnsignedLimit(limits[@"maxValueBytes"], EJSKVDefaultMaxValueBytes)
                                         maxKeysPerList:EJSKVUnsignedLimit(limits[@"maxKeysPerList"], EJSKVDefaultMaxKeysPerList)];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (EJSKeyValueStorePolicy *store in policy.stores.allValues) {
        if (!store.createIfMissing) {
            continue;
        }
        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:store.path withIntermediateDirectories:YES attributes:nil error:&createError]) {
            if (error != NULL) {
                *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInternal,
                                           createError.localizedDescription ?: @"Failed to create ejs.kv store");
            }
            return nil;
        }
    }

    return policy;
}

@implementation EJSKeyValueProvider {
    EJSKeyValuePolicy *_policy;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, NSValue *> *_dbConnections;
}

- (instancetype)initWithPolicy:(EJSKeyValuePolicy *)policy {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.kv";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.kv.provider", DISPATCH_QUEUE_SERIAL);
        _dbConnections = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    @synchronized(_dbConnections) {
        for (NSValue *val in _dbConnections.allValues) {
            sqlite3 *db = val.pointerValue;
            if (db != NULL) {
                sqlite3_close_v2(db);
            }
        }
        [_dbConnections removeAllObjects];
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;

    if (![methodID isEqualToString:@"get"] &&
        ![methodID isEqualToString:@"set"] &&
        ![methodID isEqualToString:@"delete"] &&
        ![methodID isEqualToString:@"has"] &&
        ![methodID isEqualToString:@"keys"] &&
        ![methodID isEqualToString:@"clear"]) {
        [responder finishWithData:nil error:EJSKVProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.kv method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSKVJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    EJSKeyValueCancellation *cancellation = [[EJSKeyValueCancellation alloc] init];
    NSData *requestTransfer = [transferBuffer copy];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (cancellation.isCancelled) {
                return;
            }

            NSError *operationError = nil;
            NSData *result = [self resultForMethod:methodID request:request transferBuffer:requestTransfer error:&operationError];
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

- (NSData *)resultForMethod:(NSString *)methodID
                    request:(NSDictionary *)request
             transferBuffer:(NSData *)transferBuffer
                      error:(NSError **)error {
    EJSKeyValueStorePolicy *store = [self storeForRequest:request write:[methodID isEqualToString:@"set"] || [methodID isEqualToString:@"delete"] || [methodID isEqualToString:@"clear"] error:error];
    if (store == nil) {
        return nil;
    }

    NSLock *storeLock = EJSKVLockForStorePath(store.path);
    [storeLock lock];
    @try {
        if ([methodID isEqualToString:@"keys"]) {
            return [self keysForStore:store error:error];
        }
        if ([methodID isEqualToString:@"clear"]) {
            return [self clearStore:store error:error];
        }

        NSString *key = [self keyForRequest:request error:error];
        if (key == nil) {
            return nil;
        }
        if ([methodID isEqualToString:@"get"]) {
            return [self getKey:key store:store error:error];
        }
        if ([methodID isEqualToString:@"set"]) {
            return [self setKey:key data:transferBuffer store:store error:error];
        }
        if ([methodID isEqualToString:@"delete"]) {
            return [self deleteKey:key store:store error:error];
        }
        return [self hasKey:key store:store error:error];
    } @finally {
        [storeLock unlock];
    }
}

- (EJSKeyValueStorePolicy *)storeForRequest:(NSDictionary *)request write:(BOOL)write error:(NSError **)error {
    id storeValue = request[@"store"];
    NSString *storeName = storeValue == nil || storeValue == [NSNull null]
        ? _policy.defaultStore
        : ([storeValue isKindOfClass:[NSString class]] ? storeValue : nil);
    if (!EJSKVStringIsNonEmpty(storeName)) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInvalidArgument, @"kv store must be a non-empty string");
        }
        return nil;
    }

    EJSKeyValueStorePolicy *store = _policy.stores[storeName];
    if (store == nil) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv store is not allowed");
        }
        return nil;
    }
    if (write && !store.canWrite) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv store does not allow writes");
        }
        return nil;
    }
    if (!write && !store.canRead) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv store does not allow reads");
        }
        return nil;
    }
    return store;
}

- (NSString *)keyForRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *key = [request[@"key"] isKindOfClass:[NSString class]] ? request[@"key"] : nil;
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (!EJSKVStringIsNonEmpty(key) || keyData == nil) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInvalidArgument, @"kv key must be a non-empty string");
        }
        return nil;
    }
    if (keyData.length > _policy.maxKeyBytes) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv key exceeds maxKeyBytes");
        }
        return nil;
    }
    return key;
}

- (NSString *)databasePathForStore:(EJSKeyValueStorePolicy *)store {
    return [store.path stringByAppendingPathComponent:@"kv.sqlite3"];
}

- (BOOL)ensureStoreDirectoryForStore:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([fileManager fileExistsAtPath:store.path isDirectory:&isDirectory]) {
        if (!isDirectory) {
            if (error != NULL) {
                *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv store path is not a directory");
            }
            return NO;
        }
        return YES;
    }

    if (!store.createIfMissing) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv store is missing and createIfMissing is false");
        }
        return NO;
    }

    NSError *createError = nil;
    if (![fileManager createDirectoryAtPath:store.path withIntermediateDirectories:YES attributes:nil error:&createError]) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInternal,
                                        createError.localizedDescription ?: @"Failed to create kv store");
        }
        return NO;
    }
    return YES;
}

- (BOOL)runSQL:(const char *)sql database:(sqlite3 *)db error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (rc != SQLITE_OK) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to prepare kv sqlite statement");
        }
        return NO;
    }

    while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
    }
    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to execute kv sqlite statement");
        }
        sqlite3_finalize(statement);
        return NO;
    }

    sqlite3_finalize(statement);
    return YES;
}

- (sqlite3_stmt *)prepareSQL:(const char *)sql database:(sqlite3 *)db error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    int rc = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (rc != SQLITE_OK) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to prepare kv sqlite statement");
        }
        return NULL;
    }
    return statement;
}

- (BOOL)bindKey:(NSString *)key statement:(sqlite3_stmt *)statement index:(int)index database:(sqlite3 *)db error:(NSError **)error {
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (
#ifdef EJS_TEST
        g_ejs_kv_apple_test_force_bind_key_invalid ||
#endif
        keyData == nil || keyData.length > INT_MAX) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInvalidArgument, @"kv key must be valid UTF-8");
        }
        return NO;
    }

    int rc = sqlite3_bind_text(statement, index, (const char *)keyData.bytes, (int)keyData.length, SQLITE_TRANSIENT);
    if (rc != SQLITE_OK) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to bind kv key");
        }
        return NO;
    }
    return YES;
}

- (BOOL)bindValue:(NSData *)data statement:(sqlite3_stmt *)statement index:(int)index database:(sqlite3 *)db error:(NSError **)error {
    if (
#ifdef EJS_TEST
        g_ejs_kv_apple_test_force_bind_value_too_large ||
#endif
        data.length > INT_MAX) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv value exceeds sqlite bind limit");
        }
        return NO;
    }

    int rc = data.length == 0u
        ? sqlite3_bind_zeroblob(statement, index, 0)
        : sqlite3_bind_blob(statement, index, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    if (rc != SQLITE_OK) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to bind kv value");
        }
        return NO;
    }
    return YES;
}

- (sqlite3 *)openDatabaseForStore:(EJSKeyValueStorePolicy *)store
                   createIfNeeded:(BOOL)createIfNeeded
                             error:(NSError **)error {
    NSString *databasePath = [self databasePathForStore:store];
    @synchronized(_dbConnections) {
        NSValue *cachedDbVal = _dbConnections[databasePath];
        if (cachedDbVal != nil) {
            sqlite3 *db = cachedDbVal.pointerValue;
            if (db != NULL) {
                return db;
            }
        }
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL databaseExists = [fileManager fileExistsAtPath:databasePath];

    if (!databaseExists && !createIfNeeded) {
        return NULL;
    }

    BOOL writable = createIfNeeded || store.canWrite;
    BOOL allowCreate = writable && (createIfNeeded || !databaseExists);
    if (allowCreate && ![self ensureStoreDirectoryForStore:store error:error]) {
        return NULL;
    }

    int flags = writable
        ? (SQLITE_OPEN_READWRITE | (allowCreate ? SQLITE_OPEN_CREATE : 0))
        : SQLITE_OPEN_READONLY;
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(databasePath.fileSystemRepresentation, &db, flags, NULL);
    if (rc != SQLITE_OK) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to open kv sqlite database");
        }
        if (db != NULL) {
            sqlite3_close(db);
        }
        return NULL;
    }

    sqlite3_busy_timeout(db, 5000);

    if (writable) {
        if (![self runSQL:"PRAGMA journal_mode=WAL" database:db error:error] ||
            ![self runSQL:"CREATE TABLE IF NOT EXISTS kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL)" database:db error:error]) {
            sqlite3_close(db);
            return NULL;
        }
    }

    @synchronized(_dbConnections) {
        NSValue *cachedDbVal = _dbConnections[databasePath];
        if (cachedDbVal != nil) {
            sqlite3 *cachedDb = cachedDbVal.pointerValue;
            if (cachedDb != NULL) {
                sqlite3_close_v2(db);
                return cachedDb;
            }
        }
        _dbConnections[databasePath] = [NSValue valueWithPointer:db];
        return db;
    }
}

- (BOOL)keyExists:(NSString *)key database:(sqlite3 *)db exists:(BOOL *)exists error:(NSError **)error {
    *exists = NO;
    sqlite3_stmt *statement = [self prepareSQL:"SELECT 1 FROM kv_entries WHERE key = ? LIMIT 1"
                                      database:db
                                         error:error];
    if (statement == NULL) {
        return NO;
    }

    if (![self bindKey:key statement:statement index:1 database:db error:error]) {
        sqlite3_finalize(statement);
        return NO;
    }

    int rc = sqlite3_step(statement);
#ifdef EJS_TEST
    if (g_ejs_kv_apple_test_force_key_exists_step_failure) {
        rc = SQLITE_ERROR;
    }
#endif
    if (rc == SQLITE_ROW) {
        *exists = YES;
        sqlite3_finalize(statement);
        return YES;
    }
    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to query kv key existence");
        }
        sqlite3_finalize(statement);
        return NO;
    }

    sqlite3_finalize(statement);
    return YES;
}

- (BOOL)countKeysInDatabase:(sqlite3 *)db count:(unsigned long long *)count error:(NSError **)error {
    *count = 0ull;
    sqlite3_stmt *statement = [self prepareSQL:"SELECT COUNT(*) FROM kv_entries"
                                      database:db
                                         error:error];
    if (statement == NULL) {
        return NO;
    }

    int rc = sqlite3_step(statement);
#ifdef EJS_TEST
    if (g_ejs_kv_apple_test_force_count_keys_step_failure) {
        rc = SQLITE_ERROR;
    }
#endif
    if (rc != SQLITE_ROW) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to count kv keys");
        }
        sqlite3_finalize(statement);
        return NO;
    }

    sqlite3_int64 rawCount = sqlite3_column_int64(statement, 0);
    *count = rawCount < 0 ? 0ull : (unsigned long long)rawCount;
    sqlite3_finalize(statement);
    return YES;
}

- (NSData *)getKey:(NSString *)key store:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    sqlite3 *db = [self openDatabaseForStore:store createIfNeeded:NO error:error];
    if (db == NULL) {
        return nil;
    }

    sqlite3_stmt *statement = [self prepareSQL:"SELECT value FROM kv_entries WHERE key = ?"
                                      database:db
                                         error:error];
    if (statement == NULL) {
        return nil;
    }

    if (![self bindKey:key statement:statement index:1 database:db error:error]) {
        sqlite3_finalize(statement);
        return nil;
    }

    NSData *result = nil;
    int rc = sqlite3_step(statement);
#ifdef EJS_TEST
    if (g_ejs_kv_apple_test_force_get_step_failure) {
        rc = SQLITE_ERROR;
    }
#endif
    if (rc == SQLITE_ROW) {
        int length = sqlite3_column_bytes(statement, 0);
        const void *bytes = sqlite3_column_blob(statement, 0);
        if ((unsigned long long)length > _policy.maxValueBytes) {
            if (error != NULL) {
                *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv value exceeds maxValueBytes");
            }
            sqlite3_finalize(statement);
            return nil;
        }
        result = length == 0 ? [NSData data] : [NSData dataWithBytes:bytes length:(NSUInteger)length];
    } else if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to read kv value");
        }
        sqlite3_finalize(statement);
        return nil;
    }

    sqlite3_finalize(statement);
    return result;
}

- (NSData *)setKey:(NSString *)key data:(NSData *)data store:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    if (data == nil) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeInvalidArgument, @"kv set requires a transfer buffer");
        }
        return nil;
    }
    if (data.length > _policy.maxValueBytes) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv value exceeds maxValueBytes");
        }
        return nil;
    }

    sqlite3 *db = [self openDatabaseForStore:store createIfNeeded:YES error:error];
    if (db == NULL) {
        return nil;
    }

    sqlite3_stmt *statement = [self prepareSQL:"INSERT OR REPLACE INTO kv_entries(key, value, updated_at) VALUES(?, ?, ?)"
                                      database:db
                                         error:error];
    if (statement == NULL) {
        return nil;
    }

    BOOL timestampBound = sqlite3_bind_int64(statement, 3, (sqlite3_int64)time(NULL)) == SQLITE_OK;
#ifdef EJS_TEST
    if (g_ejs_kv_apple_test_force_set_timestamp_bind_failure) {
        timestampBound = NO;
    }
#endif
    BOOL ok = [self bindKey:key statement:statement index:1 database:db error:error] &&
              [self bindValue:data statement:statement index:2 database:db error:error] &&
              timestampBound;
    if (!ok) {
        if (error != NULL && *error == nil) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to bind kv row");
        }
        sqlite3_finalize(statement);
        return nil;
    }

    int rc = sqlite3_step(statement);
    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to write kv value");
        }
        sqlite3_finalize(statement);
        return nil;
    }

    sqlite3_finalize(statement);
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)deleteKey:(NSString *)key store:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    sqlite3 *db = [self openDatabaseForStore:store createIfNeeded:NO error:error];
    if (db == NULL) {
        if (error != NULL && *error != nil) {
            return nil;
        }
        return EJSKVJSONData(@{ @"deleted": @NO }, error);
    }

    sqlite3_stmt *statement = [self prepareSQL:"DELETE FROM kv_entries WHERE key = ?"
                                      database:db
                                         error:error];
    if (statement == NULL) {
        return nil;
    }

    if (![self bindKey:key statement:statement index:1 database:db error:error]) {
        sqlite3_finalize(statement);
        return nil;
    }

    int rc = sqlite3_step(statement);
    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to delete kv value");
        }
        sqlite3_finalize(statement);
        return nil;
    }

    BOOL deleted = sqlite3_changes(db) > 0;
    sqlite3_finalize(statement);
    return EJSKVJSONData(@{ @"deleted": @(deleted) }, error);
}

- (NSData *)hasKey:(NSString *)key store:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    sqlite3 *db = [self openDatabaseForStore:store createIfNeeded:NO error:error];
    if (db == NULL) {
        if (error != NULL && *error != nil) {
            return nil;
        }
        return EJSKVJSONData(@{ @"exists": @NO }, error);
    }

    BOOL exists = NO;
    if (![self keyExists:key database:db exists:&exists error:error]) {
        return nil;
    }
    return EJSKVJSONData(@{ @"exists": @(exists) }, error);
}

- (NSData *)keysForStore:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    sqlite3 *db = [self openDatabaseForStore:store createIfNeeded:NO error:error];
    if (db == NULL) {
        if (error != NULL && *error != nil) {
            return nil;
        }
        return EJSKVJSONData(@{ @"keys": @[] }, error);
    }

    unsigned long long count = 0ull;
    if (![self countKeysInDatabase:db count:&count error:error]) {
        return nil;
    }
    if (count > _policy.maxKeysPerList) {
        if (error != NULL) {
            *error = EJSKVProviderError(EJSProviderErrorCodeSecurity, @"kv keys exceeds maxKeysPerList");
        }
        return nil;
    }

    sqlite3_stmt *statement = [self prepareSQL:"SELECT key FROM kv_entries"
                                      database:db
                                         error:error];
    if (statement == NULL) {
        return nil;
    }

    NSMutableArray<NSString *> *keys = [[NSMutableArray alloc] initWithCapacity:(NSUInteger)count];
    int rc = SQLITE_OK;
    while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
        const void *bytes = sqlite3_column_blob(statement, 0);
        int length = sqlite3_column_bytes(statement, 0);
        NSString *key = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
        if (key == nil) {
            if (error != NULL) {
                *error = EJSKVProviderError(EJSProviderErrorCodeInternal, @"kv stored key is not valid UTF-8");
            }
            sqlite3_finalize(statement);
            return nil;
        }
        [keys addObject:key];
    }
#ifdef EJS_TEST
    if (g_ejs_kv_apple_test_force_keys_step_failure) {
        rc = SQLITE_ERROR;
    }
#endif
    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSKVSQLiteProviderError(db, @"Failed to list kv keys");
        }
        sqlite3_finalize(statement);
        return nil;
    }

    sqlite3_finalize(statement);
    NSArray *sortedKeys = [keys sortedArrayUsingSelector:@selector(compare:)];
    return EJSKVJSONData(@{ @"keys": sortedKeys }, error);
}

- (NSData *)clearStore:(EJSKeyValueStorePolicy *)store error:(NSError **)error {
    sqlite3 *db = [self openDatabaseForStore:store createIfNeeded:YES error:error];
    if (db == NULL) {
        return nil;
    }

    if (![self runSQL:"DELETE FROM kv_entries" database:db error:error]) {
        return nil;
    }
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

@end

#ifdef EJS_TEST

#define EJSKV_TEST_NOINSTR __attribute__((no_profile_instrument_function))

static BOOL EJSKV_TEST_NOINSTR EJSKVTestFail(NSError **error, NSString *message) {
    if (error != NULL) {
        *error = EJSKVProviderError(EJSProviderErrorCodeInternal,
                                    [NSString stringWithFormat:@"EJSKV test helper failed: %@", message ?: @"unknown"]);
    }
    return NO;
}

static BOOL EJSKV_TEST_NOINSTR EJSKVTestExpect(BOOL condition, NSError **error, NSString *message) {
    return condition ? YES : EJSKVTestFail(error, message);
}

static NSString * EJSKV_TEST_NOINSTR EJSKVTestJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL EJSKV_TEST_NOINSTR EJSKVTestErrorContains(NSError *error, NSString *needle) {
    return needle.length == 0u || [error.localizedDescription rangeOfString:needle].location != NSNotFound;
}

static BOOL EJSKV_TEST_NOINSTR EJSKVTestExpectPolicyFailure(NSString *json, NSString *needle, NSError **error) {
    NSError *localError = nil;
    EJSKeyValuePolicy *policy = EJSKeyValuePolicyFromJSON(json, &localError);
    if (policy != nil) {
        return EJSKVTestFail(error, @"policy parse unexpectedly succeeded");
    }
    if (!EJSKVTestErrorContains(localError, needle)) {
        return EJSKVTestFail(error,
                             [NSString stringWithFormat:@"policy error mismatch: expected '%@' got '%@'",
                                                        needle ?: @"",
                                                        localError.localizedDescription ?: @""]);
    }
    return YES;
}

static BOOL EJSKV_TEST_NOINSTR EJSKVTestExpectProviderFailure(EJSKeyValueProvider *provider,
                                                              NSString *methodID,
                                                              NSDictionary *request,
                                                              NSData *transferBuffer,
                                                              NSString *needle,
                                                              NSError **error) {
    NSError *localError = nil;
    NSData *data = [provider resultForMethod:methodID request:request transferBuffer:transferBuffer error:&localError];
    if (data != nil || localError == nil || !EJSKVTestErrorContains(localError, needle)) {
        return EJSKVTestFail(error,
                             [NSString stringWithFormat:@"provider error mismatch for %@: expected '%@' got '%@'",
                                                        methodID,
                                                        needle ?: @"",
                                                        localError.localizedDescription ?: @""]);
    }
    return YES;
}

BOOL EJSKV_TEST_NOINSTR EJSKeyValueStoreAppleTestRunInternalCoverage(NSString *basePath, NSError **error) {
    if (!EJSKVStringIsNonEmpty(basePath)) {
        return EJSKVTestFail(error, @"basePath is required");
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:basePath withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    if (!EJSKVTestExpect(EJSKVBoolValue(@"not-a-number", YES) == YES, error, @"bool default branch") ||
        !EJSKVTestExpect(EJSKVUnsignedLimit(@"bad", 123ull) == 123ull, error, @"non-number unsigned default") ||
        !EJSKVTestExpect(EJSKVUnsignedLimit(@(-1), 456ull) == 456ull, error, @"negative unsigned default")) {
        return NO;
    }

    NSError *localError = nil;
    if (!EJSKVTestExpect(EJSKVSQLiteProviderError(NULL, nil) != nil, error, @"sqlite null error fallback") ||
        !EJSKVTestExpect(EJSKVJSONObjectFromData([NSData data], &localError) == nil &&
                         EJSKVTestErrorContains(localError, @"JSON object"),
                         error,
                         @"empty JSON payload error")) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect(EJSKVJSONObjectFromData([@"[]" dataUsingEncoding:NSUTF8StringEncoding], &localError) == nil &&
                         EJSKVTestErrorContains(localError, @"JSON object"),
                         error,
                         @"array JSON payload error")) {
        return NO;
    }

    NSString *validPath = [basePath stringByAppendingPathComponent:@"parse-valid"];
    NSString *parseNoCreatePath = [basePath stringByAppendingPathComponent:@"parse-no-create"];
    NSString *fileBackedStore = [basePath stringByAppendingPathComponent:@"parse-file-store"];
    if (![@"file" writeToFile:fileBackedStore atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        return NO;
    }

    if (!EJSKVTestExpectPolicyFailure(nil, @"Missing ejs.kv configuration", error) ||
        !EJSKVTestExpectPolicyFailure(@"[", nil, error) ||
        !EJSKVTestExpectPolicyFailure(@"[]", @"JSON object", error) ||
        !EJSKVTestExpectPolicyFailure(EJSKVTestJSONString(@{ @"version": @1 }), @"requires version", error) ||
        !EJSKVTestExpectPolicyFailure(EJSKVTestJSONString(@{
            @"version": @1,
            @"defaultStore": @"default",
            @"stores": @{ @"": @{ @"path": validPath, @"permissions": @[ @"read" ] } }
        }), @"store names", error) ||
        !EJSKVTestExpectPolicyFailure(EJSKVTestJSONString(@{
            @"version": @1,
            @"defaultStore": @"default",
            @"stores": @{ @"default": @{ @"path": @"relative", @"permissions": @[] } }
        }), @"absolute paths", error) ||
        !EJSKVTestExpectPolicyFailure(EJSKVTestJSONString(@{
            @"version": @1,
            @"defaultStore": @"missing",
            @"stores": @{ @"default": @{ @"path": validPath, @"permissions": @[ @"read" ] } }
        }), @"defaultStore", error) ||
        !EJSKVTestExpectPolicyFailure(EJSKVTestJSONString(@{
            @"version": @1,
            @"defaultStore": @"default",
            @"stores": @{ @"default": @{
                @"path": fileBackedStore,
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @YES
            } }
        }), nil, error)) {
        return NO;
    }

    localError = nil;
    EJSKeyValuePolicy *parsedPolicy = EJSKeyValuePolicyFromJSON(EJSKVTestJSONString(@{
        @"version": @1,
        @"defaultStore": @"default",
        @"stores": @{
            @"default": @{
                @"path": validPath,
                @"permissions": @[ @"read", @"write" ],
                @"createIfMissing": @YES
            },
            @"noCreate": @{
                @"path": parseNoCreatePath,
                @"permissions": @[ @"read" ],
                @"createIfMissing": @NO
            }
        },
        @"limits": @{
            @"maxKeyBytes": @"bad",
            @"maxValueBytes": @(-1),
            @"maxKeysPerList": [NSNull null]
        }
    }), &localError);
    if (!EJSKVTestExpect(parsedPolicy != nil &&
                         parsedPolicy.maxKeyBytes == EJSKVDefaultMaxKeyBytes &&
                         parsedPolicy.maxValueBytes == EJSKVDefaultMaxValueBytes &&
                         parsedPolicy.maxKeysPerList == EJSKVDefaultMaxKeysPerList,
                         error,
                         @"default limit parsing")) {
        return NO;
    }

    NSString *defaultDir = [basePath stringByAppendingPathComponent:@"provider-default"];
    NSString *writeOnlyDir = [basePath stringByAppendingPathComponent:@"provider-write-only"];
    NSString *readOnlyDir = [basePath stringByAppendingPathComponent:@"provider-read-only"];
    NSString *noCreateDir = [basePath stringByAppendingPathComponent:@"provider-no-create"];
    NSString *fileStorePath = [basePath stringByAppendingPathComponent:@"provider-file-store"];

    if (![@"file" writeToFile:fileStorePath atomically:YES encoding:NSUTF8StringEncoding error:error] ||
        ![fileManager createDirectoryAtPath:writeOnlyDir withIntermediateDirectories:YES attributes:nil error:error] ||
        ![fileManager createDirectoryAtPath:readOnlyDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    EJSKeyValueStorePolicy *defaultStore =
        [[EJSKeyValueStorePolicy alloc] initWithName:@"default" path:defaultDir canRead:YES canWrite:YES createIfMissing:YES];
    EJSKeyValuePolicy *providerPolicy =
        [[EJSKeyValuePolicy alloc] initWithDefaultStore:@"default"
                                                 stores:@{
            @"default": defaultStore,
            @"writeOnly": [[EJSKeyValueStorePolicy alloc] initWithName:@"writeOnly" path:writeOnlyDir canRead:NO canWrite:YES createIfMissing:YES],
            @"readOnly": [[EJSKeyValueStorePolicy alloc] initWithName:@"readOnly" path:readOnlyDir canRead:YES canWrite:NO createIfMissing:YES],
            @"noCreate": [[EJSKeyValueStorePolicy alloc] initWithName:@"noCreate" path:noCreateDir canRead:YES canWrite:YES createIfMissing:NO],
            @"fileStore": [[EJSKeyValueStorePolicy alloc] initWithName:@"fileStore" path:fileStorePath canRead:YES canWrite:YES createIfMissing:NO]
        }
                                            maxKeyBytes:8ull
                                          maxValueBytes:8ull
                                         maxKeysPerList:1ull];
    EJSKeyValueProvider *provider = [[EJSKeyValueProvider alloc] initWithPolicy:providerPolicy];

    NSData *emptyValue = [NSData data];
    NSData *smallValue = [@"v" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *largeValue = [NSMutableData dataWithLength:16u];
    if (!EJSKVTestExpectProviderFailure(provider, @"get", @{ @"store": @"" }, nil, @"store", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"get", @{ @"store": @7, @"key": @"k" }, nil, @"store", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"get", @{ @"store": @"missing", @"key": @"k" }, nil, @"store is not allowed", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"get", @{ @"store": @"writeOnly", @"key": @"k" }, nil, @"reads", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"set", @{ @"store": @"readOnly", @"key": @"k" }, smallValue, @"writes", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"set", @{ @"store": @"noCreate", @"key": @"k" }, smallValue, @"createIfMissing", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"set", @{ @"store": @"fileStore", @"key": @"k" }, smallValue, @"not a directory", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"get", @{ @"key": @"" }, nil, @"key", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"get", @{ @"key": @"too-long-key" }, nil, @"maxKeyBytes", error) ||
        !EJSKVTestExpectProviderFailure(provider, @"set", @{ @"key": @"large" }, largeValue, @"maxValueBytes", error)) {
        return NO;
    }

    if (!EJSKVTestExpect([provider resultForMethod:@"keys" request:@{} transferBuffer:nil error:NULL] != nil,
                         error,
                         @"missing sqlite keys JSON")) {
        return NO;
    }
    NSData *missingDeleteData = [provider resultForMethod:@"delete"
                                                  request:@{ @"key": @"m" }
                                           transferBuffer:nil
                                                    error:NULL];
    if (!EJSKVTestExpect(missingDeleteData != nil,
                         error,
                         @"missing sqlite delete JSON")) {
        return NO;
    }
    if (!EJSKVTestExpect([provider resultForMethod:@"has" request:@{ @"key": @"m" } transferBuffer:nil error:NULL] != nil,
                         error,
                         @"missing sqlite has JSON")) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect([provider resultForMethod:@"set" request:@{ @"key": @"empty" } transferBuffer:emptyValue error:&localError] != nil &&
                         localError == nil,
                         error,
                         @"empty sqlite value write")) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect(((NSData *)[provider resultForMethod:@"get" request:@{ @"key": @"empty" } transferBuffer:nil error:&localError]).length == 0u &&
                         localError == nil,
                         error,
                         @"empty sqlite value read")) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect([provider resultForMethod:@"set" request:@{ @"key": @"a" } transferBuffer:smallValue error:&localError] != nil &&
                         localError == nil,
                         error,
                         @"sqlite value write a")) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect([provider resultForMethod:@"set" request:@{ @"key": @"b" } transferBuffer:smallValue error:&localError] != nil &&
                         localError == nil,
                         error,
                         @"sqlite value write b") ||
        !EJSKVTestExpectProviderFailure(provider, @"keys", @{}, nil, @"maxKeysPerList", error)) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect([provider resultForMethod:@"delete" request:@{ @"key": @"missing" } transferBuffer:nil error:&localError] != nil &&
                         localError == nil,
                         error,
                         @"missing delete JSON")) {
        return NO;
    }
    localError = nil;
    if (!EJSKVTestExpect([provider resultForMethod:@"has" request:@{ @"key": @"missing" } transferBuffer:nil error:&localError] != nil &&
                         localError == nil,
                         error,
                         @"missing has JSON")) {
        return NO;
    }

    NSString *readOnlyDatabasePath = [readOnlyDir stringByAppendingPathComponent:@"kv.sqlite3"];
    sqlite3 *rawDB = NULL;
    if (!EJSKVTestExpect(sqlite3_open(readOnlyDatabasePath.fileSystemRepresentation, &rawDB) == SQLITE_OK,
                         error,
                         @"open read-only fixture db") ||
        !EJSKVTestExpect(sqlite3_exec(rawDB,
                                      "CREATE TABLE kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL);"
                                      "INSERT INTO kv_entries(key, value, updated_at) VALUES('ro', X'72', 1);",
                                      NULL,
                                      NULL,
                                      NULL) == SQLITE_OK,
                         error,
                         @"seed read-only fixture db")) {
        if (rawDB != NULL) {
            sqlite3_close(rawDB);
        }
        return NO;
    }
    sqlite3_close(rawDB);
    rawDB = NULL;
    localError = nil;
    NSData *readOnlyValue = [provider resultForMethod:@"get"
                                              request:@{ @"store": @"readOnly", @"key": @"ro" }
                                       transferBuffer:nil
                                                error:&localError];
    if (!EJSKVTestExpect(readOnlyValue.length == 1u && ((const unsigned char *)readOnlyValue.bytes)[0] == 'r' && localError == nil,
                         error,
                         @"read-only sqlite get") ||
        !EJSKVTestExpect([provider resultForMethod:@"keys" request:@{ @"store": @"readOnly" } transferBuffer:nil error:&localError] != nil &&
                         localError == nil,
                         error,
                         @"read-only sqlite keys")) {
        return NO;
    }

    sqlite3 *memoryDB = NULL;
    sqlite3_stmt *statement = NULL;
    localError = nil;
    if (!EJSKVTestExpect(sqlite3_open(":memory:", &memoryDB) == SQLITE_OK, error, @"open memory sqlite") ||
        !EJSKVTestExpect([provider runSQL:"SELECT 1" database:memoryDB error:&localError] && localError == nil,
                         error,
                         @"runSQL row iteration") ||
        !EJSKVTestExpect(![provider runSQL:"not valid sql" database:memoryDB error:&localError] &&
                         EJSKVTestErrorContains(localError, @"prepare"),
                         error,
                         @"runSQL prepare failure") ||
        !EJSKVTestExpect([provider runSQL:"CREATE TABLE unique_values(value INTEGER PRIMARY KEY)" database:memoryDB error:&localError],
                         error,
                         @"runSQL create unique table") ||
        !EJSKVTestExpect([provider runSQL:"INSERT INTO unique_values(value) VALUES(1)" database:memoryDB error:&localError],
                         error,
                         @"runSQL insert unique row") ||
        !EJSKVTestExpect(![provider runSQL:"INSERT INTO unique_values(value) VALUES(1)" database:memoryDB error:&localError] &&
                         EJSKVTestErrorContains(localError, @"execute"),
                         error,
                         @"runSQL step failure") ||
        !EJSKVTestExpect([provider prepareSQL:"not valid sql" database:memoryDB error:&localError] == NULL &&
                         EJSKVTestErrorContains(localError, @"prepare"),
                         error,
                         @"prepareSQL failure")) {
        if (memoryDB != NULL) {
            sqlite3_close(memoryDB);
        }
        return NO;
    }
    statement = [provider prepareSQL:"SELECT ?" database:memoryDB error:&localError];
    if (!EJSKVTestExpect(statement != NULL, error, @"prepare bind range fixture") ||
        !EJSKVTestExpect(![provider bindKey:@"k" statement:statement index:2 database:memoryDB error:&localError] &&
                         EJSKVTestErrorContains(localError, @"bind kv key"),
                         error,
                         @"bindKey range failure")) {
        if (statement != NULL) {
            sqlite3_finalize(statement);
        }
        sqlite3_close(memoryDB);
        return NO;
    }
    sqlite3_finalize(statement);
    statement = [provider prepareSQL:"SELECT ?" database:memoryDB error:&localError];
    if (!EJSKVTestExpect(statement != NULL, error, @"prepare value bind range fixture") ||
        !EJSKVTestExpect(![provider bindValue:smallValue statement:statement index:2 database:memoryDB error:&localError] &&
                         EJSKVTestErrorContains(localError, @"bind kv value"),
                         error,
                         @"bindValue range failure")) {
        if (statement != NULL) {
            sqlite3_finalize(statement);
        }
        sqlite3_close(memoryDB);
        return NO;
    }
    sqlite3_finalize(statement);
    sqlite3_close(memoryDB);

    NSString *openFailureDir = [basePath stringByAppendingPathComponent:@"provider-open-failure"];
    if (!EJSKVTestExpect([fileManager createDirectoryAtPath:openFailureDir withIntermediateDirectories:YES attributes:nil error:error],
                         error,
                         @"create open failure store") ||
        !EJSKVTestExpect([fileManager createDirectoryAtPath:[openFailureDir stringByAppendingPathComponent:@"kv.sqlite3"]
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error],
                         error,
                         @"create sqlite directory sentinel")) {
        return NO;
    }
    EJSKeyValueProvider *openFailureProvider =
        [[EJSKeyValueProvider alloc] initWithPolicy:[[EJSKeyValuePolicy alloc] initWithDefaultStore:@"default"
                                                                                             stores:@{
            @"default": [[EJSKeyValueStorePolicy alloc] initWithName:@"default" path:openFailureDir canRead:YES canWrite:YES createIfMissing:YES]
        }
                                                                                        maxKeyBytes:8ull
                                                                                      maxValueBytes:8ull
                                                                                     maxKeysPerList:8ull]];
    if (!EJSKVTestExpectProviderFailure(openFailureProvider, @"set", @{ @"key": @"k" }, smallValue, @"open kv sqlite database", error)) {
        return NO;
    }

    NSString *blockedParent = [basePath stringByAppendingPathComponent:@"blocked-parent"];
    NSString *blockedChild = [blockedParent stringByAppendingPathComponent:@"child"];
    if (!EJSKVTestExpect([@"blocked" writeToFile:blockedParent atomically:YES encoding:NSUTF8StringEncoding error:error],
                         error,
                         @"create blocked parent file")) {
        return NO;
    }
    EJSKeyValueProvider *createFailureProvider =
        [[EJSKeyValueProvider alloc] initWithPolicy:[[EJSKeyValuePolicy alloc] initWithDefaultStore:@"default"
                                                                                             stores:@{
            @"default": [[EJSKeyValueStorePolicy alloc] initWithName:@"default" path:blockedChild canRead:YES canWrite:YES createIfMissing:YES]
        }
                                                                                        maxKeyBytes:8ull
                                                                                      maxValueBytes:8ull
                                                                                     maxKeysPerList:8ull]];
    if (!EJSKVTestExpectProviderFailure(createFailureProvider, @"set", @{ @"key": @"k" }, smallValue, @"blocked-parent", error)) {
        return NO;
    }

    NSString *invalidKeyDir = [basePath stringByAppendingPathComponent:@"provider-invalid-key"];
    NSString *invalidKeyDatabasePath = [invalidKeyDir stringByAppendingPathComponent:@"kv.sqlite3"];
    const unsigned char invalidKeyBytes[] = { 0xff, 0xfe };
    if (!EJSKVTestExpect([fileManager createDirectoryAtPath:invalidKeyDir withIntermediateDirectories:YES attributes:nil error:error],
                         error,
                         @"create invalid-key store") ||
        !EJSKVTestExpect(sqlite3_open(invalidKeyDatabasePath.fileSystemRepresentation, &rawDB) == SQLITE_OK,
                         error,
                         @"open invalid-key fixture db") ||
        !EJSKVTestExpect(sqlite3_exec(rawDB,
                                      "CREATE TABLE kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL)",
                                      NULL,
                                      NULL,
                                      NULL) == SQLITE_OK,
                         error,
                         @"create invalid-key table") ||
        !EJSKVTestExpect(sqlite3_prepare_v2(rawDB,
                                            "INSERT INTO kv_entries(key, value, updated_at) VALUES(?, X'76', 1)",
                                            -1,
                                            &statement,
                                            NULL) == SQLITE_OK,
                         error,
                         @"prepare invalid-key insert") ||
        !EJSKVTestExpect(sqlite3_bind_text(statement, 1, (const char *)invalidKeyBytes, 2, SQLITE_TRANSIENT) == SQLITE_OK &&
                         sqlite3_step(statement) == SQLITE_DONE,
                         error,
                         @"insert invalid-key row")) {
        if (statement != NULL) {
            sqlite3_finalize(statement);
        }
        if (rawDB != NULL) {
            sqlite3_close(rawDB);
        }
        return NO;
    }
    sqlite3_finalize(statement);
    statement = NULL;
    sqlite3_close(rawDB);
    rawDB = NULL;
    EJSKeyValueProvider *invalidKeyProvider =
        [[EJSKeyValueProvider alloc] initWithPolicy:[[EJSKeyValuePolicy alloc] initWithDefaultStore:@"default"
                                                                                             stores:@{
            @"default": [[EJSKeyValueStorePolicy alloc] initWithName:@"default" path:invalidKeyDir canRead:YES canWrite:YES createIfMissing:NO]
        }
                                                                                        maxKeyBytes:8ull
                                                                                      maxValueBytes:8ull
                                                                                     maxKeysPerList:8ull]];
    if (!EJSKVTestExpectProviderFailure(invalidKeyProvider, @"keys", @{}, nil, @"not valid UTF-8", error)) {
        return NO;
    }

    NSString *triggerDir = [basePath stringByAppendingPathComponent:@"provider-trigger-failure"];
    NSString *triggerDatabasePath = [triggerDir stringByAppendingPathComponent:@"kv.sqlite3"];
    if (!EJSKVTestExpect([fileManager createDirectoryAtPath:triggerDir withIntermediateDirectories:YES attributes:nil error:error],
                         error,
                         @"create trigger store") ||
        !EJSKVTestExpect(sqlite3_open(triggerDatabasePath.fileSystemRepresentation, &rawDB) == SQLITE_OK,
                         error,
                         @"open trigger fixture db") ||
        !EJSKVTestExpect(sqlite3_exec(rawDB,
                                      "CREATE TABLE kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL);"
                                      "INSERT INTO kv_entries(key, value, updated_at) VALUES('k', X'76', 1);"
                                      "CREATE TRIGGER block_insert BEFORE INSERT ON kv_entries BEGIN SELECT RAISE(ABORT, 'blocked insert'); END;"
                                      "CREATE TRIGGER block_delete BEFORE DELETE ON kv_entries BEGIN SELECT RAISE(ABORT, 'blocked delete'); END;",
                                      NULL,
                                      NULL,
                                      NULL) == SQLITE_OK,
                         error,
                         @"seed trigger fixture db")) {
        if (rawDB != NULL) {
            sqlite3_close(rawDB);
        }
        return NO;
    }
    sqlite3_close(rawDB);
    rawDB = NULL;
    EJSKeyValueProvider *triggerProvider =
        [[EJSKeyValueProvider alloc] initWithPolicy:[[EJSKeyValuePolicy alloc] initWithDefaultStore:@"default"
                                                                                             stores:@{
            @"default": [[EJSKeyValueStorePolicy alloc] initWithName:@"default" path:triggerDir canRead:YES canWrite:YES createIfMissing:NO]
        }
                                                                                        maxKeyBytes:8ull
                                                                                      maxValueBytes:8ull
                                                                                     maxKeysPerList:8ull]];
    if (!EJSKVTestExpectProviderFailure(triggerProvider, @"set", @{ @"key": @"new" }, smallValue, @"write kv value", error) ||
        !EJSKVTestExpectProviderFailure(triggerProvider, @"delete", @{ @"key": @"k" }, nil, @"delete kv value", error) ||
        !EJSKVTestExpectProviderFailure(triggerProvider, @"clear", @{}, nil, @"execute kv sqlite statement", error)) {
        return NO;
    }

    return YES;
}

#undef EJSKV_TEST_NOINSTR

#endif

BOOL EJSKeyValueStoreInstallIntoContext(EJSContext *context, NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    NSString *json = [context configurationValueForKey:EJSKeyValueStoreConfigurationKey];
    EJSKeyValuePolicy *policy = EJSKeyValuePolicyFromJSON(json, error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSKV", @"EJSStorage" ], error)) {
        return NO;
    }

    EJSKeyValueProvider *provider = [[EJSKeyValueProvider alloc] initWithPolicy:policy];
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, provider, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < ejs_kv_scripts_count; ++i) {
#ifdef EJS_TEST
        if (g_ejs_kv_apple_test_fail_script_index >= 0 &&
            (size_t)g_ejs_kv_apple_test_fail_script_index == i) {
            if (error != NULL) {
                *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInternal, @"EJSKV test install sentinel");
            }
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
#endif

        const EJSKVBundledScript *script = &ejs_kv_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSKVRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                           @"EJSKV bundled script must be valid UTF-8");
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
