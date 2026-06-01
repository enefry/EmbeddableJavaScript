#ifndef EJS_RUNTIME_CONFIGURATION_H
#define EJS_RUNTIME_CONFIGURATION_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EJSRuntimeConfiguration : NSObject <NSCopying>

@property (nonatomic, copy, nullable) NSString *runtimeName;
@property (nonatomic, copy, nullable) NSString *runtimeVersion;
@property (nonatomic, assign) uint64_t memoryLimitBytes;
@property (nonatomic, assign) uint32_t maxStackSize;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *contextDefaults;

@end

NS_ASSUME_NONNULL_END

#endif
