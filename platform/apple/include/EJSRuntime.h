#ifndef EJS_PLATFORM_RUNTIME_H
#define EJS_PLATFORM_RUNTIME_H

#import <Foundation/Foundation.h>

@class EJSContext;
@class EJSContextConfiguration;
@class EJSRuntimeConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface EJSRuntime : NSObject

- (instancetype)init;
- (instancetype)initWithConfiguration:(nullable EJSRuntimeConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (nullable EJSContext *)createContextWithID:(NSString *)contextID error:(NSError **)error;
- (nullable EJSContext *)createContextWithID:(NSString *)contextID
                               configuration:(nullable EJSContextConfiguration *)configuration
                                       error:(NSError **)error;
- (void)requestInterrupt;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

#endif /* ifndef EJS_PLATFORM_RUNTIME_H */
