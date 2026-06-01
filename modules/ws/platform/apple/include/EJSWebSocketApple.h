#ifndef EJS_WEBSOCKET_APPLE_H
#define EJS_WEBSOCKET_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL EJSWebSocketInstallIntoContext(EJSContext *context,
                                                       NSError **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT BOOL EJSWebSocketRunMessageLimitSelfTest(NSError **error);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_WEBSOCKET_APPLE_H */
