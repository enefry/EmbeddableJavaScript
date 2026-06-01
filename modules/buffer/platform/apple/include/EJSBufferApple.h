#ifndef EJS_BUFFER_APPLE_H
#define EJS_BUFFER_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSBufferInstallIntoContext(EJSContext *context,
                                                   NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT BOOL EJSBufferInstallBundledScriptForTesting(EJSContext *context,
                                                               const char *name,
                                                               const unsigned char *code,
                                                               size_t length,
                                                               NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_BUFFER_APPLE_H */
