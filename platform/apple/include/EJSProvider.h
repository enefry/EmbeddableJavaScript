#ifndef EJS_PROVIDER_H
#define EJS_PROVIDER_H

#import <dispatch/dispatch.h>
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSErrorDomain _Nonnull const EJSProviderErrorDomain;

typedef NS_ENUM(NSInteger, EJSProviderErrorCode) {
    EJSProviderErrorCodeUnknown         = -1,
    EJSProviderErrorCodeInvalidArgument = 1,
    EJSProviderErrorCodeAborted         = 2,
    EJSProviderErrorCodeNetwork         = 3,
    EJSProviderErrorCodeTLS             = 4,
    EJSProviderErrorCodeTimeout         = 5,
    EJSProviderErrorCodeUnsupported     = 6,
    EJSProviderErrorCodeSecurity        = 7,
    EJSProviderErrorCodeInternal        = 8
};

@class EJSContext;
@class EJSProviderResponder;

NS_ASSUME_NONNULL_BEGIN

@protocol EJSProviderOperation <NSObject>
@optional
- (void)cancel;
@end

@interface EJSImmediateOperation : NSObject <EJSProviderOperation>
@end

@interface EJSBlockOperation : NSObject <EJSProviderOperation>

- (instancetype)initWithCancelBlock:(dispatch_block_t)cancelBlock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface EJSProviderResponder : NSObject

- (BOOL)finishWithData:(nullable NSData *)resultData error:(nullable NSError *)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@protocol EJSProvider <NSObject>

@property (nonatomic, copy, readonly) NSString *moduleID;

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                          payload:(nullable NSData *)payload
                                   transferBuffer:(nullable NSData *)transferBuffer
                                          context:(EJSContext *)context
                                        responder:(EJSProviderResponder *)responder;

@optional
/**
 * Synchronous provider entry for __ejs_native__.invokeSync.
 *
 * This method runs on the core owner-thread callback path. Implementations must
 * finish bounded, non-blocking work inline only; do not wait for asynchronous
 * callbacks, perform network/file I/O, or run any operation that can block the
 * owner thread for an unbounded amount of time.
 */
- (nullable NSData *)invokeSyncMethod:(NSString *)methodID
                              payload:(nullable NSData *)payload
                       transferBuffer:(nullable NSData *)transferBuffer
                              context:(EJSContext *)context
                                error:(NSError **)error;

@end

FOUNDATION_EXPORT NSError * EJSProviderMakeError(EJSProviderErrorCode code, NSString *message);

NS_ASSUME_NONNULL_END

#endif /* ifndef EJS_PROVIDER_H */
