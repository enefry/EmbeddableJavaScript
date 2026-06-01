#ifndef EJS_FILE_SYSTEM_APPLE_H
#define EJS_FILE_SYSTEM_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EJSFileSystemConfigurationKey;

FOUNDATION_EXPORT BOOL EJSFileSystemInstallIntoContext(EJSContext *context,
                                                       NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT void EJSFileSystemAppleTestSetInstallFailScriptIndex(NSInteger index);
FOUNDATION_EXPORT BOOL EJSFileSystemAppleTestExerciseInternalCoverage(NSString *basePath,
                                                                      NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_FILE_SYSTEM_APPLE_H */
