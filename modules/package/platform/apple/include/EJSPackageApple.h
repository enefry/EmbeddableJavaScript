#ifndef EJS_PACKAGE_APPLE_H
#define EJS_PACKAGE_APPLE_H

#import <Foundation/Foundation.h>

#import "EJSApplePlatform.h"

FOUNDATION_EXPORT NSErrorDomain _Nonnull const EJSPackageErrorDomain;

typedef NS_ENUM(NSInteger, EJSPackageErrorCode) {
    EJSPackageErrorCodeInvalidArgument = 1,
    EJSPackageErrorCodeUnsupported     = 2,
    EJSPackageErrorCodeMalformed       = 3,
    EJSPackageErrorCodeSecurity        = 4,
    EJSPackageErrorCodeHashMismatch    = 5,
    EJSPackageErrorCodeApprovalMissing = 6,
    EJSPackageErrorCodeIO              = 7
};

NS_ASSUME_NONNULL_BEGIN

@interface EJSPackageInstallOptions : NSObject <NSCopying>

@property (nonatomic, copy, nullable) NSURL *approvalManifestURL;
@property (nonatomic, copy, nullable) NSString *expectedPackageSHA256;
@property (nonatomic, copy) NSSet<NSString *> *approvedManifestSHA256Values;
@property (nonatomic, copy) NSSet<NSString *> *approvedPackageSHA256Values;
@property (nonatomic, copy) NSSet<NSString *> *allowedCapabilities;
@property (nonatomic, assign) BOOL allowDynamicImport;

@end

FOUNDATION_EXPORT BOOL EJSPackageInstallIntoContext(EJSContext *context,
                                                    NSURL *packageURL,
                                                    EJSPackageInstallOptions *options,
                                                    NSError **error);

NS_ASSUME_NONNULL_END

#endif /* EJS_PACKAGE_APPLE_H */
