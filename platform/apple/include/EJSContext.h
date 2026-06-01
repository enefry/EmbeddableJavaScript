#ifndef EJS_CONTEXT_H
#define EJS_CONTEXT_H

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSErrorDomain _Nonnull const EJSRuntimeErrorDomain;

typedef NS_ENUM(NSInteger, EJSRuntimeErrorCode) {
    EJSRuntimeErrorCodeUnknown            = -1,
    EJSRuntimeErrorCodeInvalidArgument    = 1,
    EJSRuntimeErrorCodeAborted            = 2,
    EJSRuntimeErrorCodeNetwork            = 3,
    EJSRuntimeErrorCodeTLS                = 4,
    EJSRuntimeErrorCodeTimeout            = 5,
    EJSRuntimeErrorCodeUnsupported        = 6,
    EJSRuntimeErrorCodeSecurity           = 7,
    EJSRuntimeErrorCodeInternal           = 8,
    EJSRuntimeErrorCodeDuplicateContextID = 1000,
    EJSRuntimeErrorCodeInvalidated        = 1001
};

@class EJSRuntime;
@protocol EJSProvider;

NS_ASSUME_NONNULL_BEGIN

@interface EJSModuleSource : NSObject <NSCopying>

@property (nonatomic, copy, readonly) NSString *specifier;
@property (nonatomic, copy, readonly) NSString *sourceURL;
@property (nonatomic, copy, readonly) NSString *source;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithSpecifier:(NSString *)specifier
                        sourceURL:(nullable NSString *)sourceURL
                           source:(NSString *)source NS_DESIGNATED_INITIALIZER;

@end

@interface EJSContext : NSObject

@property (nonatomic, strong, nullable, readonly) EJSRuntime *runtime;
@property (nonatomic, copy, readonly) NSString *contextID;

- (BOOL)evaluateScript:(NSString *)source filename:(NSString *)filename error:(NSError **)error;
- (BOOL)evaluateModule:(NSString *)source
             specifier:(NSString *)specifier
             sourceURL:(nullable NSString *)sourceURL
                 error:(NSError **)error;
- (BOOL)registerModuleSources:(NSArray<EJSModuleSource *> *)sources error:(NSError **)error;
- (BOOL)registerProvider:(id<EJSProvider>)provider error:(NSError **)error;
- (void)unregisterProviderForModuleID:(NSString *)moduleID;
- (void)unregisterAllProviders;
- (nullable NSString *)configurationValueForKey:(NSString *)key;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

#endif /* ifndef EJS_CONTEXT_H */
