#ifndef EJS_KEY_VALUE_STORE_APPLE_H
#define EJS_KEY_VALUE_STORE_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EJSKeyValueStoreConfigurationKey;

FOUNDATION_EXPORT BOOL EJSKeyValueStoreInstallIntoContext(EJSContext *context,
                                                          NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT void EJSKeyValueStoreAppleTestSetInstallFailScriptIndex(NSInteger index);
FOUNDATION_EXPORT BOOL EJSKeyValueStoreAppleTestRunInternalCoverage(NSString *basePath,
                                                                    NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_KEY_VALUE_STORE_APPLE_H */
