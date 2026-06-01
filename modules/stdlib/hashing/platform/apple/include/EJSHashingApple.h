#ifndef EJS_HASHING_APPLE_H
#define EJS_HASHING_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSHashingInstallIntoContext(EJSContext *context,
                                                    NSError **error);

NS_ASSUME_NONNULL_END

#endif /* EJS_HASHING_APPLE_H */
