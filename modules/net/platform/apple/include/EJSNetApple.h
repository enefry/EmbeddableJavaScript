#ifndef EJS_NET_APPLE_H
#define EJS_NET_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const EJSNetworkConfigurationKey;

FOUNDATION_EXPORT BOOL EJSNetInstallIntoContext(EJSContext *context,
                                                NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT BOOL EJSNetInstallBundledScriptForTesting(EJSContext *context,
                                                            const char *name,
                                                            const unsigned char *code,
                                                            size_t length,
                                                            NSError **error);
FOUNDATION_EXPORT BOOL EJSNetRunOperationCancellationSelfTest(NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_NET_APPLE_H */
