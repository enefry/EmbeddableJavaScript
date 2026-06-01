#ifndef EJS_CONTEXT_CONFIGURATION_H
#define EJS_CONTEXT_CONFIGURATION_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EJSContextConfiguration : NSObject <NSCopying>

@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *values;

@end

NS_ASSUME_NONNULL_END

#endif /* EJS_CONTEXT_CONFIGURATION_H */
