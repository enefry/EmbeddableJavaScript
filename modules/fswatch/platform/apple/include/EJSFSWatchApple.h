#ifndef EJS_FSWATCH_APPLE_H
#define EJS_FSWATCH_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EJSFSWatchConfigurationKey;

FOUNDATION_EXPORT BOOL EJSFSWatchInstallIntoContext(EJSContext *context,
                                                    NSError **error);

NS_ASSUME_NONNULL_END

#endif /* EJS_FSWATCH_APPLE_H */
