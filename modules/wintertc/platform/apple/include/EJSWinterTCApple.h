#ifndef EJS_WINTERTC_APPLE_H
#define EJS_WINTERTC_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSContext.h"

NS_ASSUME_NONNULL_BEGIN

@interface EJSWinterTCInstallOptions : NSObject <NSCopying>

@property (nonatomic, assign) BOOL installDefaultProviders;

@end

FOUNDATION_EXPORT BOOL EJSWinterTCInstallIntoContext(EJSContext *context, NSError **error);
FOUNDATION_EXPORT BOOL EJSWinterTCInstallIntoContextWithOptions(EJSContext                           *context,
                                                                EJSWinterTCInstallOptions *_Nullable options,
                                                                NSError                              **error);

#ifdef EJS_TEST
FOUNDATION_EXPORT void EJSWinterTCAppleTestSetInitSource(const char *_Nullable source);
FOUNDATION_EXPORT void EJSWinterTCAppleTestSetInstallFailScriptIndex(NSInteger index);
FOUNDATION_EXPORT void EJSWinterTCAppleTestSetInstallFailProviderIndex(NSInteger index);
FOUNDATION_EXPORT void EJSWinterTCAppleTestSetFetchMaxBufferedBytes(NSUInteger maxBufferedBytes);
#endif

NS_ASSUME_NONNULL_END

#endif /* EJS_WINTERTC_APPLE_H */
