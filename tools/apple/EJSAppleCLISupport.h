#ifndef EJS_APPLE_CLI_SUPPORT_H
#define EJS_APPLE_CLI_SUPPORT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EJSCLIRunOptions : NSObject

@property (nonatomic, copy) NSString *runtimeName;
@property (nonatomic, copy) NSString *contextID;
@property (nonatomic, assign) NSTimeInterval timeoutSeconds;
@property (nonatomic, assign) BOOL daemonMode;
#ifdef EJS_TEST
@property (nonatomic, copy, nullable) NSString *testFailurePoint;
#endif

@end

FOUNDATION_EXPORT int EJSCLIRunMain(int argc, const char * _Nonnull argv[_Nonnull], EJSCLIRunOptions *options);

NS_ASSUME_NONNULL_END

#endif /* EJS_APPLE_CLI_SUPPORT_H */
