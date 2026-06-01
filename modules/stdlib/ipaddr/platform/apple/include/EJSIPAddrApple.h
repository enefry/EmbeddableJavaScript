#ifndef EJS_IPADDR_APPLE_H
#define EJS_IPADDR_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSIPAddrInstallIntoContext(EJSContext *context,
                                                   NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT BOOL EJSIPAddrInstallBundledScriptForTesting(EJSContext *context,
                                                               const char *name,
                                                               const unsigned char *code,
                                                               size_t length,
                                                               NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_IPADDR_APPLE_H */
