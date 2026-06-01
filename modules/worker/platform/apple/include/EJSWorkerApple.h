#ifndef EJS_WORKER_APPLE_H
#define EJS_WORKER_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EJSWorkerConfigurationKey;

@interface EJSWorkerInstallOptions : NSObject <NSCopying>

@property (nonatomic, copy, nullable) BOOL (^installWorkerContext)(EJSContext *workerContext, NSError **error);

@end

FOUNDATION_EXPORT BOOL EJSWorkerInstallIntoContext(EJSContext *context, NSError **error);
FOUNDATION_EXPORT BOOL EJSWorkerInstallIntoContextWithOptions(EJSContext                        *context,
                                                              EJSWorkerInstallOptions *_Nullable options,
                                                              NSError                           **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT void EJSWorkerAppleTestSetInstallFailScriptIndex(NSInteger index);
FOUNDATION_EXPORT BOOL EJSWorkerAppleTestRunInternalCoverage(NSString *rootPath,
                                                             NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_WORKER_APPLE_H */
