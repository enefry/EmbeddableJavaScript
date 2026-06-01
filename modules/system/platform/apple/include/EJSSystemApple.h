#ifndef EJS_SYSTEM_APPLE_H
#define EJS_SYSTEM_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSSystemInstallIntoContext(EJSContext *context,
                                                   NSError **error);

NS_ASSUME_NONNULL_END

#endif /* EJS_SYSTEM_APPLE_H */
