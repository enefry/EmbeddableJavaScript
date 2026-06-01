#ifndef EJS_APPLE_INSTALL_TRANSACTION_INTERNAL_H
#define EJS_APPLE_INSTALL_TRANSACTION_INTERNAL_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"
#import "EJSProvider.h"

typedef struct {
    __unsafe_unretained EJSContext *context;
    __strong NSArray<NSString *> *ownedGlobalNames;
    __strong NSString *snapshotKey;
    __strong NSMutableArray<NSString *> *registeredProviderModuleIDs;
    BOOL active;
} EJSAppleInstallTransaction;

static inline NSError * EJSAppleInstallTransactionError(NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{
        NSLocalizedDescriptionKey: message
    } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:EJSRuntimeErrorCodeInternal userInfo:userInfo];
}

static inline NSString * EJSAppleInstallTransactionJSONString(id value, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:error];
    if (data == nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static inline BOOL EJSAppleInstallTransactionEvaluateRollbackScript(EJSAppleInstallTransaction *transaction,
                                                                    NSString                   *scriptSuffix,
                                                                    NSError                   **error) {
    if (transaction == NULL || transaction->context == nil || transaction->snapshotKey.length == 0u) {
        if (error != NULL) {
            *error = EJSAppleInstallTransactionError(@"Install transaction context is missing");
        }
        return NO;
    }

    NSString *payload = EJSAppleInstallTransactionJSONString(@{
        @"key": transaction->snapshotKey,
        @"names": transaction->ownedGlobalNames ?: @[]
    }, error);
    if (payload == nil) {
        if (error != NULL && *error == nil) {
            *error = EJSAppleInstallTransactionError(@"Failed to encode install transaction payload");
        }
        return NO;
    }

    NSString *script = [NSString stringWithFormat:
        @"(function(payload){"
         "const globalObject = globalThis;"
         "const names = Array.isArray(payload.names) ? payload.names : [];"
         "const snapshotKey = String(payload.key || '');"
         "if (snapshotKey.length === 0) return;"
         "if (%@) {"
         "  const snapshot = Object.create(null);"
         "  for (const name of names) {"
         "    const own = Object.prototype.hasOwnProperty.call(globalObject, name);"
         "    snapshot[name] = own ? Object.getOwnPropertyDescriptor(globalObject, name) : null;"
         "  }"
         "  Object.defineProperty(globalObject, snapshotKey, {"
         "    value: snapshot,"
         "    configurable: true,"
         "    writable: true,"
         "    enumerable: false"
         "  });"
         "  return;"
         "}"
         "const snapshot = Object.prototype.hasOwnProperty.call(globalObject, snapshotKey) ? globalObject[snapshotKey] : Object.create(null);"
         "for (const name of names) {"
         "  const before = Object.prototype.hasOwnProperty.call(snapshot, name) ? snapshot[name] : null;"
         "  if (before === null) {"
         "    if (!Object.prototype.hasOwnProperty.call(globalObject, name)) {"
         "      continue;"
         "    }"
         "    const currentDescriptor = Object.getOwnPropertyDescriptor(globalObject, name);"
         "    if (currentDescriptor && currentDescriptor.configurable === false) {"
         "      throw new Error('install rollback cannot delete non-configurable global: ' + name);"
         "    }"
         "    delete globalObject[name];"
         "    continue;"
         "  }"
         "  Object.defineProperty(globalObject, name, before);"
         "}"
         "delete globalObject[snapshotKey];"
         "})(%@);",
        [scriptSuffix isEqualToString:@"capture"] ? @"true" : @"false",
        payload];

    NSString *filename = [NSString stringWithFormat:@"apple_install_%@.js", scriptSuffix];
    return [transaction->context evaluateScript:script filename:filename error:error];
}

static inline BOOL EJSAppleInstallTransactionBegin(EJSAppleInstallTransaction *transaction,
                                                   EJSContext                  *context,
                                                   NSArray<NSString *>         *ownedGlobalNames,
                                                   NSError                     **error) {
    if (transaction == NULL || context == nil) {
        if (error != NULL) {
            *error = EJSAppleInstallTransactionError(@"Install transaction requires a context");
        }
        return NO;
    }

    transaction->context = context;
    transaction->ownedGlobalNames = [ownedGlobalNames copy] ?: @[];
    transaction->snapshotKey = [NSString stringWithFormat:@"__ejs_install_snapshot_%@", NSUUID.UUID.UUIDString];
    transaction->registeredProviderModuleIDs = [[NSMutableArray alloc] init];
    transaction->active = NO;

    if (!EJSAppleInstallTransactionEvaluateRollbackScript(transaction, @"capture", error)) {
        return NO;
    }

    transaction->active = YES;
    return YES;
}

static inline BOOL EJSAppleInstallTransactionRegisterProvider(EJSAppleInstallTransaction *transaction,
                                                              id<EJSProvider>             provider,
                                                              NSError                    **error) {
    if (transaction == NULL || transaction->context == nil || provider == nil) {
        if (error != NULL) {
            *error = EJSAppleInstallTransactionError(@"Install transaction provider registration is invalid");
        }
        return NO;
    }

    if (![transaction->context registerProvider:provider error:error]) {
        return NO;
    }

    NSString *moduleID = provider.moduleID ?: @"";
    if (moduleID.length > 0u) {
        [transaction->registeredProviderModuleIDs addObject:moduleID];
    }
    return YES;
}

static inline void EJSAppleInstallTransactionUnregisterProviders(EJSAppleInstallTransaction *transaction) {
    if (transaction == NULL || transaction->context == nil) {
        return;
    }

    for (NSInteger i = (NSInteger)transaction->registeredProviderModuleIDs.count - 1; i >= 0; --i) {
        NSString *moduleID = transaction->registeredProviderModuleIDs[(NSUInteger)i];
        [transaction->context unregisterProviderForModuleID:moduleID];
    }
    [transaction->registeredProviderModuleIDs removeAllObjects];
}

static inline BOOL EJSAppleInstallTransactionRollback(EJSAppleInstallTransaction *transaction,
                                                      NSError                    **error) {
    if (transaction == NULL) {
        return YES;
    }

    if (!transaction->active) {
        EJSAppleInstallTransactionUnregisterProviders(transaction);
        return YES;
    }

    NSError *rollbackError = nil;
    BOOL restoredGlobals = EJSAppleInstallTransactionEvaluateRollbackScript(transaction, @"rollback", &rollbackError);
    EJSAppleInstallTransactionUnregisterProviders(transaction);
    transaction->active = NO;

    if (!restoredGlobals && error != NULL) {
        *error = rollbackError;
    }
    return restoredGlobals;
}

static inline void EJSAppleInstallTransactionRollbackPreservingError(EJSAppleInstallTransaction *transaction,
                                                                     NSError                    **error) {
    NSError *primaryError = error != NULL ? *error : nil;
    NSError *rollbackError = nil;

    if (EJSAppleInstallTransactionRollback(transaction, &rollbackError)) {
        return;
    }

    if (error == NULL) {
        return;
    }

    if (primaryError == nil) {
        *error = rollbackError;
        return;
    }

    NSMutableDictionary *userInfo = [primaryError.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    if (rollbackError != nil) {
        userInfo[NSUnderlyingErrorKey] = rollbackError;
        userInfo[NSLocalizedFailureReasonErrorKey] =
            [NSString stringWithFormat:@"Install rollback failed: %@", rollbackError.localizedDescription ?: @"unknown error"];
    }
    *error = [NSError errorWithDomain:primaryError.domain code:primaryError.code userInfo:userInfo];
}

static inline BOOL EJSAppleInstallTransactionCommit(EJSAppleInstallTransaction *transaction,
                                                    NSError                    **error) {
    if (transaction == NULL || !transaction->active) {
        return YES;
    }

    NSString *payload = EJSAppleInstallTransactionJSONString(@{
        @"key": transaction->snapshotKey ?: @""
    }, error);
    if (payload == nil) {
        return NO;
    }

    NSString *script = [NSString stringWithFormat:
        @"(function(payload){"
         "const globalObject = globalThis;"
         "const key = String(payload.key || '');"
         "if (key.length > 0) {"
         "  delete globalObject[key];"
         "}"
         "})(%@);",
        payload];

    BOOL success = [transaction->context evaluateScript:script
                                                filename:@"apple_install_commit.js"
                                                   error:error];
    if (success) {
        transaction->active = NO;
        [transaction->registeredProviderModuleIDs removeAllObjects];
    }
    return success;
}

#endif /* EJS_APPLE_INSTALL_TRANSACTION_INTERNAL_H */
