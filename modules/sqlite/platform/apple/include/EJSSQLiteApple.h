#ifndef EJS_SQLITE_APPLE_H
#define EJS_SQLITE_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EJSSQLiteConfigurationKey;

FOUNDATION_EXPORT BOOL EJSSQLiteInstallIntoContext(EJSContext *context,
                                                   NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT void EJSSQLiteAppleTestSetInstallFailScriptIndex(NSInteger index);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_SQLITE_APPLE_H */
