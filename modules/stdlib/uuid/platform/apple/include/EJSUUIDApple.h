#ifndef EJS_UUID_APPLE_H
#define EJS_UUID_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSUUIDInstallIntoContext(EJSContext *context,
                                                 NSError **error);

#ifdef EJS_TEST
typedef NS_ENUM(NSInteger, EJSUUIDInstallFailureModeForTesting) {
    EJSUUIDInstallFailureModeNoneForTesting = 0,
    EJSUUIDInstallFailureModeBeginForTesting = 1,
    EJSUUIDInstallFailureModeRegisterProviderForTesting = 2,
    EJSUUIDInstallFailureModeCommitForTesting = 3
};

FOUNDATION_EXPORT void EJSUUIDSetInstallFailureModeForTesting(EJSUUIDInstallFailureModeForTesting mode);
FOUNDATION_EXPORT BOOL EJSUUIDInstallBundledScriptForTesting(EJSContext *context,
                                                             const char *name,
                                                             const unsigned char *code,
                                                             size_t length,
                                                             NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_UUID_APPLE_H */
