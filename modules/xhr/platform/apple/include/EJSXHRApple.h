#ifndef EJS_XHR_APPLE_H
#define EJS_XHR_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSXHRInstallIntoContext(EJSContext *context,
                                                NSError **error);

NS_ASSUME_NONNULL_END

#endif /* EJS_XHR_APPLE_H */
