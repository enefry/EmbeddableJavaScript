#import "EJSSQLiteApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include <ctype.h>
#include <math.h>
#include <sqlite3.h>

#include "ejs_sqlite_js_bundle.h"

NSString * const EJSSQLiteConfigurationKey = @"ejs.sqlite";

#ifdef EJS_TEST
static NSInteger g_ejs_sqlite_apple_test_fail_script_index = -1;

void EJSSQLiteAppleTestSetInstallFailScriptIndex(NSInteger index) {
    g_ejs_sqlite_apple_test_fail_script_index = index;
}
#endif

static const unsigned long long EJSSQLiteDefaultMaxRows = 1000ull;
static const unsigned long long EJSSQLiteDefaultMaxStatementBytes = 64ull * 1024ull;
static const unsigned long long EJSSQLiteDefaultMaxBlobBytes = 1024ull * 1024ull;
static const unsigned long long EJSSQLiteDefaultMaxTextBytes = 256ull * 1024ull;
static const unsigned long long EJSSQLiteDefaultMaxResponseBytes = 4ull * 1024ull * 1024ull;
static const int64_t EJSSQLiteJSMaxSafeInteger = 9007199254740991ll;

static NSError * EJSSQLiteRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError * EJSSQLiteProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"SQLite provider failed");
}

static BOOL EJSSQLiteStringIsNonEmpty(NSString *value) {
    return [value isKindOfClass:[NSString class]] && value.length > 0u;
}

static BOOL EJSSQLiteBoolValue(id value, BOOL defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    return [value boolValue];
}

static unsigned long long EJSSQLiteUnsignedLimit(id value, unsigned long long defaultValue) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return defaultValue;
    }
    long long number = [value longLongValue];
    if (number < 0) {
        return defaultValue;
    }
    return (unsigned long long)number;
}

static NSDictionary * EJSSQLiteJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite payload must be a JSON object");
        }
        return nil;
    }

    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData * EJSSQLiteJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, @"Failed to encode sqlite JSON response");
    }
    return data;
}

static BOOL EJSSQLiteTailHasOnlyWhitespace(const char *tail) {
    if (tail == NULL) {
        return YES;
    }
    const unsigned char *cursor = (const unsigned char *)tail;
    while (*cursor != '\0') {
        if (!isspace(*cursor)) {
            return NO;
        }
        cursor++;
    }
    return YES;
}

@interface EJSSQLiteDatabasePolicy : NSObject
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

@implementation EJSSQLiteDatabasePolicy

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

@interface EJSSQLitePolicy : NSObject
@property (nonatomic, copy, readonly) NSDictionary<NSString *, EJSSQLiteDatabasePolicy *> *databases;
@property (nonatomic, assign, readonly) unsigned long long maxRows;
@property (nonatomic, assign, readonly) unsigned long long maxStatementBytes;
@property (nonatomic, assign, readonly) unsigned long long maxBlobBytes;
@property (nonatomic, assign, readonly) unsigned long long maxTextBytes;
@property (nonatomic, assign, readonly) unsigned long long maxResponseBytes;
- (instancetype)initWithDatabases:(NSDictionary<NSString *, EJSSQLiteDatabasePolicy *> *)databases
                          maxRows:(unsigned long long)maxRows
                 maxStatementBytes:(unsigned long long)maxStatementBytes
                      maxBlobBytes:(unsigned long long)maxBlobBytes
                      maxTextBytes:(unsigned long long)maxTextBytes
                  maxResponseBytes:(unsigned long long)maxResponseBytes;
@end

@implementation EJSSQLitePolicy

- (instancetype)initWithDatabases:(NSDictionary<NSString *, EJSSQLiteDatabasePolicy *> *)databases
                          maxRows:(unsigned long long)maxRows
                 maxStatementBytes:(unsigned long long)maxStatementBytes
                      maxBlobBytes:(unsigned long long)maxBlobBytes
                      maxTextBytes:(unsigned long long)maxTextBytes
                  maxResponseBytes:(unsigned long long)maxResponseBytes {
    self = [super init];
    if (self != nil) {
        _databases = [databases copy];
        _maxRows = maxRows;
        _maxStatementBytes = maxStatementBytes;
        _maxBlobBytes = maxBlobBytes;
        _maxTextBytes = maxTextBytes;
        _maxResponseBytes = maxResponseBytes;
    }
    return self;
}

@end

@interface EJSSQLiteConnection : NSObject
@property (nonatomic, copy, readonly) NSString *connectionID;
@property (nonatomic, strong, readonly) EJSSQLiteDatabasePolicy *policy;
@property (nonatomic, assign, readonly) sqlite3 *db;
@property (nonatomic, assign, readonly) BOOL readOnly;
@property (nonatomic, copy, nullable) NSString *activeTransaction;
- (instancetype)initWithConnectionID:(NSString *)connectionID
                              policy:(EJSSQLiteDatabasePolicy *)policy
                                  db:(sqlite3 *)db
                            readOnly:(BOOL)readOnly;
- (void)close;
@end

@implementation EJSSQLiteConnection

- (instancetype)initWithConnectionID:(NSString *)connectionID
                              policy:(EJSSQLiteDatabasePolicy *)policy
                                  db:(sqlite3 *)db
                            readOnly:(BOOL)readOnly {
    self = [super init];
    if (self != nil) {
        _connectionID = [connectionID copy];
        _policy = policy;
        _db = db;
        _readOnly = readOnly;
    }
    return self;
}

- (void)close {
    if (_db != NULL) {
        sqlite3_close_v2(_db);
        _db = NULL;
    }
}

- (void)dealloc {
    [self close];
}

@end

@interface EJSSQLiteCancellation : NSObject
@property (atomic, assign, getter = isCancelled) BOOL cancelled;
@end

@implementation EJSSQLiteCancellation
@end

@interface EJSSQLiteProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSSQLitePolicy *)policy;
@end

static EJSSQLitePolicy * EJSSQLitePolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0) {
        if (error != NULL) {
            *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Missing ejs.sqlite configuration");
        }
        return nil;
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        if (error != NULL) {
            *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.sqlite configuration must be valid UTF-8");
        }
        return nil;
    }

    NSError *jsonError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                           jsonError.localizedDescription ?: @"ejs.sqlite configuration must be a JSON object");
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    NSNumber *version = [object[@"version"] isKindOfClass:[NSNumber class]] ? object[@"version"] : nil;
    NSDictionary *databasesObject = [object[@"databases"] isKindOfClass:[NSDictionary class]] ? object[@"databases"] : nil;
    if (version == nil || version.integerValue != 1 || databasesObject.count == 0u) {
        if (error != NULL) {
            *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.sqlite requires version and databases");
        }
        return nil;
    }

    NSMutableDictionary<NSString *, EJSSQLiteDatabasePolicy *> *databases = [[NSMutableDictionary alloc] init];
    for (NSString *databaseName in databasesObject) {
        if (!EJSSQLiteStringIsNonEmpty(databaseName)) {
            if (error != NULL) {
                *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.sqlite database names must be non-empty strings");
            }
            return nil;
        }

        NSDictionary *databaseObject = [databasesObject[databaseName] isKindOfClass:[NSDictionary class]] ? databasesObject[databaseName] : nil;
        NSString *path = [databaseObject[@"path"] isKindOfClass:[NSString class]] ? databaseObject[@"path"] : nil;
        NSArray *permissions = [databaseObject[@"permissions"] isKindOfClass:[NSArray class]] ? databaseObject[@"permissions"] : nil;
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

        if (!EJSSQLiteStringIsNonEmpty(path) || !path.isAbsolutePath || (!canRead && !canWrite)) {
            if (error != NULL) {
                *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.sqlite databases require absolute paths and permissions");
            }
            return nil;
        }

        databases[databaseName] = [[EJSSQLiteDatabasePolicy alloc] initWithName:databaseName
                                                                            path:path
                                                                         canRead:canRead
                                                                        canWrite:canWrite
                                                                 createIfMissing:EJSSQLiteBoolValue(databaseObject[@"createIfMissing"], NO)];
    }

    NSDictionary *limits = [object[@"limits"] isKindOfClass:[NSDictionary class]] ? object[@"limits"] : @{};
    return [[EJSSQLitePolicy alloc] initWithDatabases:databases
                                             maxRows:EJSSQLiteUnsignedLimit(limits[@"maxRows"], EJSSQLiteDefaultMaxRows)
                                    maxStatementBytes:EJSSQLiteUnsignedLimit(limits[@"maxStatementBytes"], EJSSQLiteDefaultMaxStatementBytes)
                                         maxBlobBytes:EJSSQLiteUnsignedLimit(limits[@"maxBlobBytes"], EJSSQLiteDefaultMaxBlobBytes)
                                         maxTextBytes:EJSSQLiteUnsignedLimit(limits[@"maxTextBytes"], EJSSQLiteDefaultMaxTextBytes)
                                     maxResponseBytes:EJSSQLiteUnsignedLimit(limits[@"maxResponseBytes"], EJSSQLiteDefaultMaxResponseBytes)];
}

@implementation EJSSQLiteProvider {
    EJSSQLitePolicy *_policy;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, EJSSQLiteConnection *> *_connections;
}

- (instancetype)initWithPolicy:(EJSSQLitePolicy *)policy {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.sqlite";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.sqlite.provider", DISPATCH_QUEUE_SERIAL);
        _connections = [[NSMutableDictionary alloc] init];
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

    if (![methodID isEqualToString:@"open"] &&
        ![methodID isEqualToString:@"execute"] &&
        ![methodID isEqualToString:@"query"] &&
        ![methodID isEqualToString:@"begin"] &&
        ![methodID isEqualToString:@"commit"] &&
        ![methodID isEqualToString:@"rollback"] &&
        ![methodID isEqualToString:@"close"]) {
        [responder finishWithData:nil error:EJSSQLiteProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.sqlite method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSSQLiteJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    EJSSQLiteCancellation *cancellation = [[EJSSQLiteCancellation alloc] init];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (cancellation.isCancelled) {
                return;
            }

            NSError *operationError = nil;
            NSData *result = [self resultForMethod:methodID request:request error:&operationError];
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

- (NSData *)resultForMethod:(NSString *)methodID request:(NSDictionary *)request error:(NSError **)error {
    if ([methodID isEqualToString:@"open"]) {
        return [self openConnectionForRequest:request error:error];
    }
    if ([methodID isEqualToString:@"close"]) {
        return [self closeConnectionForRequest:request error:error];
    }

    EJSSQLiteConnection *connection = [self connectionForRequest:request error:error];
    if (connection == nil) {
        return nil;
    }
    if ([methodID isEqualToString:@"execute"]) {
        return [self executeForConnection:connection request:request error:error];
    }
    if ([methodID isEqualToString:@"query"]) {
        return [self queryForConnection:connection request:request error:error];
    }
    if ([methodID isEqualToString:@"begin"]) {
        return [self beginTransactionForConnection:connection request:request error:error];
    }
    if ([methodID isEqualToString:@"commit"]) {
        return [self finishTransactionForConnection:connection request:request sql:"COMMIT" error:error];
    }
    return [self finishTransactionForConnection:connection request:request sql:"ROLLBACK" error:error];
}

- (NSString *)stringForKey:(NSString *)key request:(NSDictionary *)request message:(NSString *)message error:(NSError **)error {
    NSString *value = [request[key] isKindOfClass:[NSString class]] ? request[key] : nil;
    if (!EJSSQLiteStringIsNonEmpty(value)) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, message);
        }
        return nil;
    }
    return value;
}

- (EJSSQLiteConnection *)connectionForRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *connectionID = [self stringForKey:@"connection" request:request message:@"sqlite connection must be a non-empty string" error:error];
    if (connectionID == nil) {
        return nil;
    }
    EJSSQLiteConnection *connection = _connections[connectionID];
    if (connection == nil || connection.db == NULL) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite database is closed");
        }
        return nil;
    }
    return connection;
}

- (NSData *)openConnectionForRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *connectionID = [self stringForKey:@"connection" request:request message:@"sqlite connection must be a non-empty string" error:error];
    NSString *name = [self stringForKey:@"name" request:request message:@"sqlite database name must be a non-empty string" error:error];
    if (connectionID == nil || name == nil) {
        return nil;
    }
    if (_connections[connectionID] != nil) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite connection already exists");
        }
        return nil;
    }

    EJSSQLiteDatabasePolicy *database = _policy.databases[name];
    if (database == nil) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database is not allowed");
        }
        return nil;
    }

    BOOL requestedReadOnly = EJSSQLiteBoolValue(request[@"readOnly"], NO);
    BOOL readOnly = requestedReadOnly || !database.canWrite;
    if (!database.canRead && readOnly) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database does not allow reads");
        }
        return nil;
    }
    if (!readOnly && !database.canWrite) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database does not allow writes");
        }
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [database.path stringByDeletingLastPathComponent];
    if (database.createIfMissing) {
        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&createError]) {
            if (error != NULL) {
                *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal,
                                                createError.localizedDescription ?: @"Failed to create sqlite directory");
            }
            return nil;
        }
    } else if (![fileManager fileExistsAtPath:database.path]) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database is missing and createIfMissing is false");
        }
        return nil;
    }

    int flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | (database.createIfMissing ? SQLITE_OPEN_CREATE : 0));
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(database.path.fileSystemRepresentation, &db, flags, NULL);
    if (rc != SQLITE_OK) {
        NSString *message = db != NULL ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"Failed to open sqlite database";
        if (db != NULL) {
            sqlite3_close_v2(db);
        }
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, message);
        }
        return nil;
    }

    _connections[connectionID] = [[EJSSQLiteConnection alloc] initWithConnectionID:connectionID
                                                                            policy:database
                                                                                db:db
                                                                          readOnly:readOnly];
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)closeConnectionForRequest:(NSDictionary *)request error:(NSError **)error {
    EJSSQLiteConnection *connection = [self connectionForRequest:request error:error];
    if (connection == nil) {
        return nil;
    }
    if (connection.activeTransaction != nil) {
        char *errmsg = NULL;
        sqlite3_exec(connection.db, "ROLLBACK", NULL, NULL, &errmsg);
        if (errmsg != NULL) {
            sqlite3_free(errmsg);
        }
        connection.activeTransaction = nil;
    }
    [connection close];
    [_connections removeObjectForKey:connection.connectionID];
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)validateStatement:(NSString *)sql connection:(EJSSQLiteConnection *)connection write:(BOOL)write error:(NSError **)error {
    NSData *sqlData = [sql dataUsingEncoding:NSUTF8StringEncoding];
    if (!EJSSQLiteStringIsNonEmpty(sql) || sqlData == nil) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite sql must be a non-empty UTF-8 string");
        }
        return NO;
    }
    if (sqlData.length > _policy.maxStatementBytes) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite sql exceeds maxStatementBytes");
        }
        return NO;
    }
    if (write && (connection.readOnly || !connection.policy.canWrite)) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database does not allow writes");
        }
        return NO;
    }
    if (!write && !connection.policy.canRead) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database does not allow reads");
        }
        return NO;
    }
    return YES;
}

- (sqlite3_stmt *)prepareSQL:(NSString *)sql connection:(EJSSQLiteConnection *)connection write:(BOOL)write error:(NSError **)error {
    if (![self validateStatement:sql connection:connection write:write error:error]) {
        return NULL;
    }
    sqlite3_stmt *statement = NULL;
    const char *tail = NULL;
    int rc = sqlite3_prepare_v2(connection.db, sql.UTF8String, -1, &statement, &tail);
    if (rc != SQLITE_OK) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, [NSString stringWithUTF8String:sqlite3_errmsg(connection.db)]);
        }
        return NULL;
    }
    if (!EJSSQLiteTailHasOnlyWhitespace(tail)) {
        sqlite3_finalize(statement);
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite only supports a single statement");
        }
        return NULL;
    }
    if (write && sqlite3_stmt_readonly(statement)) {
        sqlite3_finalize(statement);
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite execute requires a write statement");
        }
        return NULL;
    }
    if (!write && !sqlite3_stmt_readonly(statement)) {
        sqlite3_finalize(statement);
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite query requires a read-only statement");
        }
        return NULL;
    }
    return statement;
}

- (BOOL)bindParams:(NSArray *)params statement:(sqlite3_stmt *)statement error:(NSError **)error {
    if (![params isKindOfClass:[NSArray class]]) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite params must be an array");
        }
        return NO;
    }
    if ((int)params.count != sqlite3_bind_parameter_count(statement)) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite params count does not match statement");
        }
        return NO;
    }
    for (NSUInteger i = 0u; i < params.count; ++i) {
        NSDictionary *param = [params[i] isKindOfClass:[NSDictionary class]] ? params[i] : nil;
        NSString *type = [param[@"type"] isKindOfClass:[NSString class]] ? param[@"type"] : nil;
        id value = param[@"value"];
        int index = (int)i + 1;
        int rc = SQLITE_MISUSE;
        if ([type isEqualToString:@"null"]) {
            rc = sqlite3_bind_null(statement, index);
        } else if ([type isEqualToString:@"boolean"]) {
            if (value != (id)kCFBooleanTrue && value != (id)kCFBooleanFalse) {
                if (error != NULL) {
                    *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite boolean param value must be true or false");
                }
                return NO;
            }
            rc = sqlite3_bind_int(statement, index, [value boolValue] ? 1 : 0);
        } else if ([type isEqualToString:@"number"]) {
            NSNumber *number = [value isKindOfClass:[NSNumber class]] ? value : nil;
            if (number == nil || number == (id)kCFBooleanTrue || number == (id)kCFBooleanFalse) {
                if (error != NULL) {
                    *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite number param value must be a finite number");
                }
                return NO;
            }
            double numberValue = [number doubleValue];
            if (!isfinite(numberValue)) {
                if (error != NULL) {
                    *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite number param value must be a finite number");
                }
                return NO;
            }
            rc = sqlite3_bind_double(statement, index, numberValue);
        } else if ([type isEqualToString:@"string"]) {
            NSString *string = [value isKindOfClass:[NSString class]] ? value : nil;
            if (string == nil) {
                if (error != NULL) {
                    *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite string param value must be a string");
                }
                return NO;
            }
            rc = sqlite3_bind_text(statement, index, string.UTF8String, -1, SQLITE_TRANSIENT);
        }
        if (rc != SQLITE_OK) {
            if (error != NULL) {
                *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite param type is unsupported");
            }
            return NO;
        }
    }
    return YES;
}

- (BOOL)validateTransactionForRequest:(NSDictionary *)request
                           connection:(EJSSQLiteConnection *)connection
                                error:(NSError **)error {
    NSString *requestTransaction = [request[@"transaction"] isKindOfClass:[NSString class]] ? request[@"transaction"] : nil;
    if (connection.activeTransaction == nil) {
        if (requestTransaction != nil && requestTransaction.length > 0u) {
            if (error != NULL) {
                *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite transaction is not active");
            }
            return NO;
        }
        return YES;
    }

    if (![connection.activeTransaction isEqualToString:requestTransaction]) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite transaction does not match active transaction");
        }
        return NO;
    }

    return YES;
}

- (NSData *)executeForConnection:(EJSSQLiteConnection *)connection request:(NSDictionary *)request error:(NSError **)error {
    if (![self validateTransactionForRequest:request connection:connection error:error]) {
        return nil;
    }
    NSString *sql = [request[@"sql"] isKindOfClass:[NSString class]] ? request[@"sql"] : nil;
    sqlite3_stmt *statement = [self prepareSQL:sql connection:connection write:YES error:error];
    if (statement == NULL) {
        return nil;
    }
    NSArray *params = [request[@"params"] isKindOfClass:[NSArray class]] ? request[@"params"] : @[];
    if (![self bindParams:params statement:statement error:error]) {
        sqlite3_finalize(statement);
        return nil;
    }

    int rc = sqlite3_step(statement);
    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, [NSString stringWithUTF8String:sqlite3_errmsg(connection.db)]);
        }
        sqlite3_finalize(statement);
        return nil;
    }
    sqlite3_finalize(statement);
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)queryForConnection:(EJSSQLiteConnection *)connection request:(NSDictionary *)request error:(NSError **)error {
    if (![self validateTransactionForRequest:request connection:connection error:error]) {
        return nil;
    }
    NSString *sql = [request[@"sql"] isKindOfClass:[NSString class]] ? request[@"sql"] : nil;
    sqlite3_stmt *statement = [self prepareSQL:sql connection:connection write:NO error:error];
    if (statement == NULL) {
        return nil;
    }
    NSArray *params = [request[@"params"] isKindOfClass:[NSArray class]] ? request[@"params"] : @[];
    if (![self bindParams:params statement:statement error:error]) {
        sqlite3_finalize(statement);
        return nil;
    }

    NSMutableArray<NSDictionary *> *rows = [[NSMutableArray alloc] init];
    unsigned long long responseBytes = 0ull;
    int columnCount = sqlite3_column_count(statement);
    int rc = SQLITE_ROW;
    while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
        if ((unsigned long long)rows.count >= _policy.maxRows) {
            if (error != NULL) {
                *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite query exceeds maxRows");
            }
            sqlite3_finalize(statement);
            return nil;
        }
        NSMutableDictionary *row = [[NSMutableDictionary alloc] init];
        for (int column = 0; column < columnCount; ++column) {
            NSString *name = [NSString stringWithUTF8String:sqlite3_column_name(statement, column) ?: ""];
            int type = sqlite3_column_type(statement, column);
            id value = [NSNull null];
            if (type == SQLITE_INTEGER) {
                int64_t integerValue = sqlite3_column_int64(statement, column);
                if (integerValue > EJSSQLiteJSMaxSafeInteger || integerValue < -EJSSQLiteJSMaxSafeInteger) {
                    NSString *encodedInteger = [NSString stringWithFormat:@"%lld", integerValue];
                    value = @{
                        @"type": @"int64",
                        @"value": encodedInteger
                    };
                    responseBytes += (unsigned long long)[encodedInteger lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                } else {
                    value = @(integerValue);
                    responseBytes += sizeof(double);
                }
            } else if (type == SQLITE_FLOAT) {
                value = @(sqlite3_column_double(statement, column));
                responseBytes += sizeof(double);
            } else if (type == SQLITE_TEXT) {
                int byteCount = sqlite3_column_bytes(statement, column);
                if ((unsigned long long)byteCount > _policy.maxTextBytes) {
                    if (error != NULL) {
                        *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite text exceeds maxTextBytes");
                    }
                    sqlite3_finalize(statement);
                    return nil;
                }
                const unsigned char *text = sqlite3_column_text(statement, column);
                NSString *textValue = @"";
                if (text != NULL && byteCount > 0) {
                    textValue = [[NSString alloc] initWithBytes:text
                                                          length:(NSUInteger)byteCount
                                                        encoding:NSUTF8StringEncoding];
                    if (textValue == nil) {
                        if (error != NULL) {
                            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, @"sqlite text is not valid UTF-8");
                        }
                        sqlite3_finalize(statement);
                        return nil;
                    }
                }
                value = textValue;
                responseBytes += (unsigned long long)byteCount;
            } else if (type == SQLITE_BLOB) {
                int byteCount = sqlite3_column_bytes(statement, column);
                if ((unsigned long long)byteCount > _policy.maxBlobBytes) {
                    if (error != NULL) {
                        *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite blob exceeds maxBlobBytes");
                    }
                    sqlite3_finalize(statement);
                    return nil;
                }
                NSData *data = [NSData dataWithBytes:sqlite3_column_blob(statement, column) length:(NSUInteger)byteCount];
                value = @{
                    @"type": @"blob",
                    @"base64": [data base64EncodedStringWithOptions:0]
                };
                responseBytes += (unsigned long long)byteCount;
            }
            if (responseBytes > _policy.maxResponseBytes) {
                if (error != NULL) {
                    *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite query exceeds maxResponseBytes");
                }
                sqlite3_finalize(statement);
                return nil;
            }
            row[name] = value;
        }
        [rows addObject:row];
    }

    if (rc != SQLITE_DONE) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, [NSString stringWithUTF8String:sqlite3_errmsg(connection.db)]);
        }
        sqlite3_finalize(statement);
        return nil;
    }
    sqlite3_finalize(statement);
    return EJSSQLiteJSONData(@{ @"rows": rows }, error);
}

- (NSData *)beginTransactionForConnection:(EJSSQLiteConnection *)connection request:(NSDictionary *)request error:(NSError **)error {
    NSString *transaction = [self stringForKey:@"transaction" request:request message:@"sqlite transaction must be a non-empty string" error:error];
    if (transaction == nil) {
        return nil;
    }
    if (connection.activeTransaction != nil) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite transaction is already active");
        }
        return nil;
    }
    if (connection.readOnly || !connection.policy.canWrite) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeSecurity, @"sqlite database does not allow writes");
        }
        return nil;
    }

    char *errmsg = NULL;
    int rc = sqlite3_exec(connection.db, "BEGIN IMMEDIATE", NULL, NULL, &errmsg);
    if (rc != SQLITE_OK) {
        NSString *message = errmsg != NULL ? [NSString stringWithUTF8String:errmsg] : @"Failed to begin sqlite transaction";
        if (errmsg != NULL) {
            sqlite3_free(errmsg);
        }
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, message);
        }
        return nil;
    }
    connection.activeTransaction = transaction;
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)finishTransactionForConnection:(EJSSQLiteConnection *)connection
                                   request:(NSDictionary *)request
                                       sql:(const char *)sql
                                     error:(NSError **)error {
    NSString *transaction = [self stringForKey:@"transaction" request:request message:@"sqlite transaction must be a non-empty string" error:error];
    if (transaction == nil) {
        return nil;
    }
    if (![connection.activeTransaction isEqualToString:transaction]) {
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInvalidArgument, @"sqlite transaction is not active");
        }
        return nil;
    }

    char *errmsg = NULL;
    int rc = sqlite3_exec(connection.db, sql, NULL, NULL, &errmsg);
    if (rc == SQLITE_OK || sqlite3_get_autocommit(connection.db) != 0) {
        connection.activeTransaction = nil;
    }
    if (rc != SQLITE_OK) {
        NSString *message = errmsg != NULL ? [NSString stringWithUTF8String:errmsg] : @"Failed to finish sqlite transaction";
        if (errmsg != NULL) {
            sqlite3_free(errmsg);
        }
        if (error != NULL) {
            *error = EJSSQLiteProviderError(EJSProviderErrorCodeInternal, message);
        }
        return nil;
    }
    return [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
}

@end

BOOL EJSSQLiteInstallIntoContext(EJSContext *context, NSError **error) {
    if (context == nil) {
        if (error != NULL) {
            *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        }
        return NO;
    }

    NSString *json = [context configurationValueForKey:EJSSQLiteConfigurationKey];
    EJSSQLitePolicy *policy = EJSSQLitePolicyFromJSON(json, error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSSQLite" ], error)) {
        return NO;
    }

    EJSSQLiteProvider *provider = [[EJSSQLiteProvider alloc] initWithPolicy:policy];
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, provider, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < ejs_sqlite_scripts_count; ++i) {
#ifdef EJS_TEST
        if (g_ejs_sqlite_apple_test_fail_script_index >= 0 &&
            (size_t)g_ejs_sqlite_apple_test_fail_script_index == i) {
            if (error != NULL) {
                *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInternal, @"EJSSQLite test install sentinel");
            }
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
#endif

        const EJSSQLiteBundledScript *script = &ejs_sqlite_scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code
                                                    length:script->len
                                                  encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];

        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSSQLiteRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                               @"EJSSQLite bundled script must be valid UTF-8");
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
