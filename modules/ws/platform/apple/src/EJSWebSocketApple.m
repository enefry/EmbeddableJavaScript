#import "EJSWebSocketApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_ws_js_bundle.h"
#include <arpa/inet.h>
#include <math.h>
#include <netinet/in.h>

static NSString * const EJSWSNetworkConfigurationKey = @"ejs.network";
static const NSUInteger EJSWSMaxMessageBytes = 16u * 1024u * 1024u;

static NSError *EJSWSRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError *EJSWSProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"websocket provider failed");
}

static BOOL EJSWSValidateMessageBytes(NSUInteger byteLength, NSError **error) {
    if (byteLength > EJSWSMaxMessageBytes) {
        if (error != NULL) *error = EJSWSProviderError(EJSProviderErrorCodeSecurity, @"websocket message exceeds maxMessageBytes");
        return NO;
    }
    return YES;
}

static BOOL EJSWSStringIsNonEmpty(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0u;
}

static BOOL EJSWSValueIsJSONBoolean(id value) {
    return value != nil && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL EJSWSNumberIsIntegerInRange(id value, NSInteger min, NSInteger max) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    double doubleValue = [(NSNumber *)value doubleValue];
    NSInteger integerValue = [(NSNumber *)value integerValue];
    return floor(doubleValue) == doubleValue && integerValue >= min && integerValue <= max;
}

static NSData *EJSWSAddressBytesFromString(NSString *address, int *familyOut) {
    unsigned char bytes[16] = { 0 };
    if (inet_pton(AF_INET, address.UTF8String, bytes) == 1) {
        if (familyOut != NULL) *familyOut = 4;
        return [NSData dataWithBytes:bytes length:4u];
    }
    if (inet_pton(AF_INET6, address.UTF8String, bytes) == 1) {
        if (familyOut != NULL) *familyOut = 6;
        return [NSData dataWithBytes:bytes length:16u];
    }
    return nil;
}

@interface EJSWSCIDR : NSObject
@property (nonatomic, assign, readonly) int family;
@property (nonatomic, assign, readonly) NSInteger prefixLength;
@property (nonatomic, copy, readonly) NSData *bytes;
- (instancetype)initWithFamily:(int)family prefixLength:(NSInteger)prefixLength bytes:(NSData *)bytes;
- (BOOL)containsAddressBytes:(NSData *)bytes family:(int)family;
@end

@implementation EJSWSCIDR
- (instancetype)initWithFamily:(int)family prefixLength:(NSInteger)prefixLength bytes:(NSData *)bytes {
    self = [super init];
    if (self != nil) {
        _family = family;
        _prefixLength = prefixLength;
        _bytes = [bytes copy];
    }
    return self;
}

- (BOOL)containsAddressBytes:(NSData *)bytes family:(int)family {
    if (family != self.family || bytes.length != self.bytes.length) {
        return NO;
    }
    const unsigned char *lhs = self.bytes.bytes;
    const unsigned char *rhs = bytes.bytes;
    NSInteger remaining = self.prefixLength;
    for (NSUInteger i = 0u; i < self.bytes.length && remaining > 0; ++i) {
        if (remaining >= 8) {
            if (lhs[i] != rhs[i]) {
                return NO;
            }
            remaining -= 8;
            continue;
        }
        unsigned char mask = (unsigned char)((0xff << (8 - remaining)) & 0xff);
        return (lhs[i] & mask) == (rhs[i] & mask);
    }
    return YES;
}
@end

@interface EJSWSAllowRule : NSObject
@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, copy, readonly) NSString *hostSuffix;
@property (nonatomic, strong, readonly, nullable) EJSWSCIDR *cidr;
@property (nonatomic, copy, readonly) NSSet<NSString *> *protocols;
@property (nonatomic, copy, readonly) NSSet<NSNumber *> *ports;
@property (nonatomic, assign, readonly) NSInteger portRangeStart;
@property (nonatomic, assign, readonly) NSInteger portRangeEnd;
- (instancetype)initWithHost:(NSString *)host
                  hostSuffix:(NSString *)hostSuffix
                        cidr:(nullable EJSWSCIDR *)cidr
                   protocols:(NSSet<NSString *> *)protocols
                       ports:(NSSet<NSNumber *> *)ports
              portRangeStart:(NSInteger)portRangeStart
                portRangeEnd:(NSInteger)portRangeEnd;
- (BOOL)matchesHost:(NSString *)host;
- (BOOL)matchesAddress:(NSString *)address family:(int)family;
- (BOOL)matchesExactAddress:(NSString *)address family:(int)family;
- (BOOL)allowsProtocol:(NSString *)protocol port:(NSInteger)port;
@end

@implementation EJSWSAllowRule
- (instancetype)initWithHost:(NSString *)host
                  hostSuffix:(NSString *)hostSuffix
                        cidr:(EJSWSCIDR *)cidr
                   protocols:(NSSet<NSString *> *)protocols
                       ports:(NSSet<NSNumber *> *)ports
              portRangeStart:(NSInteger)portRangeStart
                portRangeEnd:(NSInteger)portRangeEnd {
    self = [super init];
    if (self != nil) {
        _host = [host.lowercaseString copy] ?: @"";
        _hostSuffix = [hostSuffix.lowercaseString copy] ?: @"";
        _cidr = cidr;
        _protocols = [protocols copy] ?: [NSSet set];
        _ports = [ports copy] ?: [NSSet set];
        _portRangeStart = portRangeStart;
        _portRangeEnd = portRangeEnd;
    }
    return self;
}

- (BOOL)matchesHost:(NSString *)host {
    NSString *lower = host.lowercaseString ?: @"";
    if (self.host.length > 0u && [lower isEqualToString:self.host]) {
        return YES;
    }
    if (self.hostSuffix.length > 0u && [lower hasSuffix:self.hostSuffix]) {
        return YES;
    }
    if (self.cidr != nil) {
        int family = 0;
        NSData *bytes = EJSWSAddressBytesFromString(lower, &family);
        return bytes != nil && [self.cidr containsAddressBytes:bytes family:family];
    }
    return NO;
}

- (BOOL)matchesAddress:(NSString *)address family:(int)family {
    if (self.cidr == nil) {
        return NO;
    }
    int parsedFamily = 0;
    NSData *bytes = EJSWSAddressBytesFromString(address, &parsedFamily);
    return bytes != nil && parsedFamily == family && [self.cidr containsAddressBytes:bytes family:family];
}

- (BOOL)matchesExactAddress:(NSString *)address family:(int)family {
    NSString *lower = address.lowercaseString ?: @"";
    if (self.host.length > 0u && [lower isEqualToString:self.host]) {
        return YES;
    }
    if (self.host.length > 0u) {
        int hostFamily = 0;
        int addressFamily = 0;
        NSData *hostBytes = EJSWSAddressBytesFromString(self.host, &hostFamily);
        NSData *addressBytes = EJSWSAddressBytesFromString(lower, &addressFamily);
        if (hostBytes != nil && addressBytes != nil) {
            return hostFamily == family && addressFamily == family && [hostBytes isEqualToData:addressBytes];
        }
    }
    if (self.cidr != nil) {
        int parsedFamily = 0;
        NSData *bytes = EJSWSAddressBytesFromString(lower, &parsedFamily);
        return bytes != nil && parsedFamily == family && [self.cidr containsAddressBytes:bytes family:family];
    }
    return NO;
}

- (BOOL)allowsProtocol:(NSString *)protocol port:(NSInteger)port {
    if (self.protocols.count > 0u && ![self.protocols containsObject:protocol]) {
        return NO;
    }
    if (self.ports.count == 0u && self.portRangeStart < 0) {
        return YES;
    }
    if ([self.ports containsObject:@(port)]) {
        return YES;
    }
    return self.portRangeStart >= 0 && port >= self.portRangeStart && port <= self.portRangeEnd;
}
@end

static BOOL EJSWSAddressIsLinkLocal(NSData *bytes, int family) {
    const unsigned char *value = bytes.bytes;
    if (family == 4 && bytes.length == 4u) {
        return value[0] == 169 && value[1] == 254;
    }
    if (family == 6 && bytes.length == 16u) {
        return value[0] == 0xfe && (value[1] & 0xc0) == 0x80;
    }
    return NO;
}

static BOOL EJSWSAddressIsPrivate(NSData *bytes, int family) {
    const unsigned char *value = bytes.bytes;
    if (family == 4 && bytes.length == 4u) {
        return value[0] == 10 ||
            value[0] == 127 ||
            (value[0] == 172 && value[1] >= 16 && value[1] <= 31) ||
            (value[0] == 192 && value[1] == 168) ||
            EJSWSAddressIsLinkLocal(bytes, family);
    }
    if (family == 6 && bytes.length == 16u) {
        BOOL loopback = YES;
        for (NSUInteger i = 0u; i < 15u; ++i) {
            if (value[i] != 0) {
                loopback = NO;
                break;
            }
        }
        return loopback && value[15] == 1 ? YES : ((value[0] & 0xfe) == 0xfc || EJSWSAddressIsLinkLocal(bytes, family));
    }
    return NO;
}

@interface EJSWSPolicy : NSObject
@property (nonatomic, assign, readonly) BOOL configured;
@property (nonatomic, assign, readonly) BOOL wsEnabled;
@property (nonatomic, assign, readonly) BOOL outboundDefaultAllow;
@property (nonatomic, assign, readonly) BOOL denyPrivateNetworks;
@property (nonatomic, assign, readonly) BOOL denyLinkLocal;
@property (nonatomic, copy, readonly) NSArray<EJSWSAllowRule *> *outboundAllowRules;
+ (instancetype)disabledPolicy;
- (instancetype)initWithConfigured:(BOOL)configured
                         wsEnabled:(BOOL)wsEnabled
               outboundDefaultAllow:(BOOL)outboundDefaultAllow
                denyPrivateNetworks:(BOOL)denyPrivateNetworks
                       denyLinkLocal:(BOOL)denyLinkLocal
                  outboundAllowRules:(NSArray<EJSWSAllowRule *> *)outboundAllowRules;
- (BOOL)allowsURL:(NSURL *)url;
- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family port:(NSInteger)port;
- (BOOL)allowsUnpinnedHostnameResolution;
@end

@implementation EJSWSPolicy
+ (instancetype)disabledPolicy {
    return [[EJSWSPolicy alloc] initWithConfigured:NO
                                         wsEnabled:NO
                               outboundDefaultAllow:NO
                                denyPrivateNetworks:NO
                                       denyLinkLocal:YES
                                  outboundAllowRules:@[]];
}

- (instancetype)initWithConfigured:(BOOL)configured
                         wsEnabled:(BOOL)wsEnabled
               outboundDefaultAllow:(BOOL)outboundDefaultAllow
                denyPrivateNetworks:(BOOL)denyPrivateNetworks
                       denyLinkLocal:(BOOL)denyLinkLocal
                  outboundAllowRules:(NSArray<EJSWSAllowRule *> *)outboundAllowRules {
    self = [super init];
    if (self != nil) {
        _configured = configured;
        _wsEnabled = wsEnabled;
        _outboundDefaultAllow = outboundDefaultAllow;
        _denyPrivateNetworks = denyPrivateNetworks;
        _denyLinkLocal = denyLinkLocal;
        _outboundAllowRules = [outboundAllowRules copy] ?: @[];
    }
    return self;
}

- (BOOL)allowsURL:(NSURL *)url {
    if (!self.configured || !self.wsEnabled) {
        return NO;
    }
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"ws"] && ![scheme isEqualToString:@"wss"]) {
        return NO;
    }
    NSString *host = url.host.lowercaseString ?: @"";
    if (host.length == 0u) {
        return NO;
    }
    NSInteger port = url.port != nil ? url.port.integerValue : [scheme isEqualToString:@"wss"] ? 443 : 80;
    for (EJSWSAllowRule *rule in self.outboundAllowRules) {
        if ([rule matchesHost:host] && [rule allowsProtocol:@"ws" port:port]) {
            return YES;
        }
    }
    return self.outboundDefaultAllow;
}

- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family port:(NSInteger)port {
    int parsedFamily = 0;
    NSData *bytes = EJSWSAddressBytesFromString(address, &parsedFamily);
    if (bytes == nil || parsedFamily != family) {
        return NO;
    }
    if (self.denyLinkLocal && EJSWSAddressIsLinkLocal(bytes, family)) {
        return NO;
    }
    if (self.denyPrivateNetworks && EJSWSAddressIsPrivate(bytes, family)) {
        return NO;
    }
    if (self.outboundDefaultAllow) {
        return YES;
    }
    for (EJSWSAllowRule *rule in self.outboundAllowRules) {
        if (([rule matchesAddress:address family:family] || [rule matchesExactAddress:address family:family]) &&
            [rule allowsProtocol:@"ws" port:port]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)allowsUnpinnedHostnameResolution {
    return self.outboundDefaultAllow && !self.denyPrivateNetworks && !self.denyLinkLocal;
}
@end

static EJSWSCIDR *EJSWSCIDRFromString(NSString *value, NSError **error) {
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"/"];
    if (parts.count != 2u || parts[0].length == 0u || parts[1].length == 0u) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr must be address/prefix");
        return nil;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([parts[1] rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr prefix must be an integer");
        return nil;
    }
    int family = 0;
    NSData *bytes = EJSWSAddressBytesFromString(parts[0], &family);
    NSInteger prefix = parts[1].integerValue;
    NSInteger maxPrefix = family == 4 ? 32 : family == 6 ? 128 : -1;
    if (bytes == nil || prefix < 0 || prefix > maxPrefix) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr is invalid");
        return nil;
    }
    return [[EJSWSCIDR alloc] initWithFamily:family prefixLength:prefix bytes:bytes];
}

static BOOL EJSWSValidatePortFields(NSDictionary *rule, NSError **error) {
    id ports = rule[@"ports"];
    if (ports != nil) {
        if (![ports isKindOfClass:[NSArray class]]) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule ports must be an array");
            return NO;
        }
        for (id port in (NSArray *)ports) {
            if (!EJSWSNumberIsIntegerInRange(port, 1, 65535)) {
                if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule ports must be 1-65535");
                return NO;
            }
        }
    }
    id portRange = rule[@"portRange"];
    if (portRange != nil) {
        if (![portRange isKindOfClass:[NSArray class]] || [(NSArray *)portRange count] != 2u ||
            !EJSWSNumberIsIntegerInRange(((NSArray *)portRange)[0], 0, 65535) ||
            !EJSWSNumberIsIntegerInRange(((NSArray *)portRange)[1], 0, 65535) ||
            [((NSArray *)portRange)[0] integerValue] > [((NSArray *)portRange)[1] integerValue]) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule portRange must be [min,max]");
            return NO;
        }
    }
    return YES;
}

static BOOL EJSWSValidateOptionalBoolean(NSDictionary *object, NSString *key, NSString *field, NSError **error) {
    id value = object[key];
    if (value == nil) {
        return YES;
    }
    if (!EJSWSValueIsJSONBoolean(value)) {
        if (error != NULL) {
            *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, [NSString stringWithFormat:@"%@ must be boolean", field]);
        }
        return NO;
    }
    return YES;
}

static EJSWSPolicy *EJSWSPolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0u) {
        return [EJSWSPolicy disabledPolicy];
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id value = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network configuration must be a JSON object");
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    if (!EJSWSNumberIsIntegerInRange(object[@"version"], 1, 1)) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network requires version 1");
        return nil;
    }
    NSDictionary *capabilities = [object[@"capabilities"] isKindOfClass:[NSDictionary class]] ? object[@"capabilities"] : nil;
    NSDictionary *outbound = [object[@"outbound"] isKindOfClass:[NSDictionary class]] ? object[@"outbound"] : nil;
    if (capabilities == nil || outbound == nil) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network requires capabilities and outbound");
        return nil;
    }
    if (!EJSWSValidateOptionalBoolean(capabilities, @"ws", @"ejs.network capabilities.ws", error) ||
        !EJSWSValidateOptionalBoolean(outbound, @"denyPrivateNetworks", @"ejs.network outbound.denyPrivateNetworks", error) ||
        !EJSWSValidateOptionalBoolean(outbound, @"denyLinkLocal", @"ejs.network outbound.denyLinkLocal", error)) {
        return nil;
    }

    NSString *defaultRule = [outbound[@"default"] isKindOfClass:[NSString class]] ? outbound[@"default"] : @"deny";
    BOOL defaultAllow = [defaultRule isEqualToString:@"allow"];
    if (!defaultAllow && ![defaultRule isEqualToString:@"deny"]) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network outbound.default must be allow or deny");
        return nil;
    }

    NSArray *allowObjects = [outbound[@"allow"] isKindOfClass:[NSArray class]] ? outbound[@"allow"] : @[];
    if (outbound[@"allow"] != nil && ![outbound[@"allow"] isKindOfClass:[NSArray class]]) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network outbound.allow must be an array");
        return nil;
    }
    NSDictionary *http = [object[@"http"] isKindOfClass:[NSDictionary class]] ? object[@"http"] : @{};
    if (object[@"http"] != nil && ![object[@"http"] isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network http must be an object");
        return nil;
    }
    if (!EJSWSValidateOptionalBoolean(http, @"useSystemProxy", @"ejs.network http.useSystemProxy", error)) {
        return nil;
    }
    if ([http[@"useSystemProxy"] boolValue]) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"websocket phase 5A does not support ejs.network http.useSystemProxy=true");
        return nil;
    }

    NSMutableArray<EJSWSAllowRule *> *rules = [[NSMutableArray alloc] initWithCapacity:allowObjects.count];
    for (id entry in allowObjects) {
        NSDictionary *rule = [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
        if (rule == nil) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network allow rule must be an object");
            return nil;
        }
        NSString *host = [rule[@"host"] isKindOfClass:[NSString class]] ? [rule[@"host"] lowercaseString] : @"";
        NSString *hostSuffix = [rule[@"hostSuffix"] isKindOfClass:[NSString class]] ? [rule[@"hostSuffix"] lowercaseString] : @"";
        NSString *cidrValue = [rule[@"cidr"] isKindOfClass:[NSString class]] ? rule[@"cidr"] : nil;
        if (host.length == 0u && hostSuffix.length == 0u && cidrValue.length == 0u) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network allow rule requires host, hostSuffix, or cidr");
            return nil;
        }
        if (![host isEqualToString:@""] && [host hasPrefix:@"."]) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule host must not start with dot");
            return nil;
        }
        if (![hostSuffix isEqualToString:@""] && ![hostSuffix hasPrefix:@"."]) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule hostSuffix must start with dot");
            return nil;
        }
        if (!EJSWSValidatePortFields(rule, error)) {
            return nil;
        }
        EJSWSCIDR *cidr = nil;
        if (cidrValue != nil) {
            cidr = EJSWSCIDRFromString(cidrValue, error);
            if (cidr == nil) {
                return nil;
            }
        }

        NSArray *protocolList = [rule[@"protocols"] isKindOfClass:[NSArray class]] ? rule[@"protocols"] : @[];
        if (rule[@"protocols"] != nil && ![rule[@"protocols"] isKindOfClass:[NSArray class]]) {
            if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule protocols must be an array");
            return nil;
        }
        NSMutableSet<NSString *> *protocols = [[NSMutableSet alloc] init];
        for (id protocolEntry in protocolList) {
            NSString *protocolName = [protocolEntry isKindOfClass:[NSString class]] ? [protocolEntry lowercaseString] : nil;
            if (protocolName == nil || protocolName.length == 0u) {
                if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule protocol entries must be non-empty strings");
                return nil;
            }
            [protocols addObject:protocolName];
        }

        NSArray *ports = [rule[@"ports"] isKindOfClass:[NSArray class]] ? rule[@"ports"] : @[];
        NSMutableSet<NSNumber *> *portSet = [[NSMutableSet alloc] initWithCapacity:ports.count];
        for (NSNumber *port in ports) {
            [portSet addObject:@(port.integerValue)];
        }
        NSInteger rangeStart = -1;
        NSInteger rangeEnd = -1;
        NSArray *portRange = [rule[@"portRange"] isKindOfClass:[NSArray class]] ? rule[@"portRange"] : nil;
        if (portRange != nil) {
            rangeStart = [portRange[0] integerValue];
            rangeEnd = [portRange[1] integerValue];
        }
        [rules addObject:[[EJSWSAllowRule alloc] initWithHost:host
                                                    hostSuffix:hostSuffix
                                                          cidr:cidr
                                                     protocols:protocols
                                                         ports:portSet
                                                portRangeStart:rangeStart
                                                  portRangeEnd:rangeEnd]];
    }

    BOOL wsEnabled = [capabilities[@"ws"] boolValue];
    return [[EJSWSPolicy alloc] initWithConfigured:YES
                                         wsEnabled:wsEnabled
                               outboundDefaultAllow:defaultAllow
                                denyPrivateNetworks:[outbound[@"denyPrivateNetworks"] boolValue]
                                       denyLinkLocal:outbound[@"denyLinkLocal"] == nil ? YES : [outbound[@"denyLinkLocal"] boolValue]
                                  outboundAllowRules:rules];
}

static NSDictionary *EJSWSJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        return @{};
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket payload must be a JSON object");
        }
        return nil;
    }
    return value;
}

static NSData *EJSWSJSONData(id object, NSError **error) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
}

static NSString *EJSWSUTF8StringFromData(NSData *data) {
    if (data.length == 0u) {
        return @"";
    }
    NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return result != nil ? result : @"";
}

static EJSProviderErrorCode EJSWSProviderCodeForNSError(NSError *error) {
    if (error == nil) {
        return EJSProviderErrorCodeInternal;
    }
    if ([error.domain isEqualToString:EJSProviderErrorDomain]) {
        switch ((EJSProviderErrorCode)error.code) {
            case EJSProviderErrorCodeInvalidArgument:
            case EJSProviderErrorCodeAborted:
            case EJSProviderErrorCodeNetwork:
            case EJSProviderErrorCodeTLS:
            case EJSProviderErrorCodeTimeout:
            case EJSProviderErrorCodeUnsupported:
            case EJSProviderErrorCodeSecurity:
            case EJSProviderErrorCodeInternal:
                return (EJSProviderErrorCode)error.code;
            default:
                return EJSProviderErrorCodeInternal;
        }
    }
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorCancelled:
                return EJSProviderErrorCodeAborted;
            case NSURLErrorTimedOut:
                return EJSProviderErrorCodeTimeout;
            case NSURLErrorSecureConnectionFailed:
            case NSURLErrorServerCertificateHasBadDate:
            case NSURLErrorServerCertificateUntrusted:
            case NSURLErrorServerCertificateHasUnknownRoot:
            case NSURLErrorServerCertificateNotYetValid:
            case NSURLErrorClientCertificateRejected:
            case NSURLErrorClientCertificateRequired:
                return EJSProviderErrorCodeTLS;
            default:
                return EJSProviderErrorCodeNetwork;
        }
    }
    return EJSProviderErrorCodeInternal;
}

@interface EJSWSWaiter : NSObject
@property (nonatomic, strong) EJSProviderResponder *responder;
@property (nonatomic, assign) BOOL active;
@end

@implementation EJSWSWaiter
@end

@interface EJSWSSocketState : NSObject
@property (nonatomic, copy, readonly) NSString *socketID;
@property (nonatomic, strong, readonly) NSURLSessionWebSocketTask *task;
@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, strong, readonly) NSMutableArray<NSDictionary *> *events;
@property (nonatomic, strong, readonly) NSMutableArray<EJSWSWaiter *> *waiters;
@property (nonatomic, assign) BOOL openDispatched;
@property (nonatomic, assign) BOOL terminalQueued;
- (instancetype)initWithSocketID:(NSString *)socketID task:(NSURLSessionWebSocketTask *)task;
@end

@implementation EJSWSSocketState
- (instancetype)initWithSocketID:(NSString *)socketID task:(NSURLSessionWebSocketTask *)task {
    self = [super init];
    if (self != nil) {
        _socketID = [socketID copy];
        _task = task;
        _lock = [[NSLock alloc] init];
        _events = [[NSMutableArray alloc] init];
        _waiters = [[NSMutableArray alloc] init];
        _openDispatched = NO;
        _terminalQueued = NO;
    }
    return self;
}
@end

@interface EJSWSProvider : NSObject <EJSProvider, NSURLSessionWebSocketDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSWSPolicy *)policy;
@end

@implementation EJSWSProvider {
    EJSWSPolicy *_policy;
    NSURLSession *_session;
    dispatch_queue_t _queue;
    NSLock *_lock;
    NSMutableDictionary<NSString *, EJSWSSocketState *> *_socketsByID;
    NSMutableDictionary<NSNumber *, NSString *> *_socketIDsByTaskID;
}

- (instancetype)initWithPolicy:(EJSWSPolicy *)policy {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.ws";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.ws.provider", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache = nil;
        configuration.HTTPCookieStorage = nil;
        configuration.connectionProxyDictionary = @{};
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
        _lock = [[NSLock alloc] init];
        _socketsByID = [[NSMutableDictionary alloc] init];
        _socketIDsByTaskID = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_lock lock];
    NSArray<EJSWSSocketState *> *states = _socketsByID.allValues;
    [_socketsByID removeAllObjects];
    [_socketIDsByTaskID removeAllObjects];
    [_lock unlock];

    for (EJSWSSocketState *state in states) {
        [state.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        [state.lock lock];
        NSArray<EJSWSWaiter *> *waiters = [state.waiters copy];
        [state.waiters removeAllObjects];
        [state.events removeAllObjects];
        [state.lock unlock];
        for (EJSWSWaiter *waiter in waiters) {
            if (waiter.active) {
                waiter.active = NO;
                [waiter.responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeAborted, @"websocket socket is closed")];
            }
        }
    }
    [_session invalidateAndCancel];
}

- (EJSWSSocketState *)socketStateForID:(NSString *)socketID {
    [_lock lock];
    EJSWSSocketState *state = _socketsByID[socketID];
    [_lock unlock];
    return state;
}

- (void)removeSocketForID:(NSString *)socketID {
    if (socketID.length == 0u) {
        return;
    }
    EJSWSSocketState *state = nil;
    [_lock lock];
    state = _socketsByID[socketID];
    if (state != nil) {
        [_socketIDsByTaskID removeObjectForKey:@(state.task.taskIdentifier)];
        [_socketsByID removeObjectForKey:socketID];
    }
    [_lock unlock];
    if (state == nil) {
        return;
    }

    NSArray<EJSWSWaiter *> *waiters = nil;
    [state.lock lock];
    waiters = [state.waiters copy];
    [state.waiters removeAllObjects];
    [state.events removeAllObjects];
    [state.lock unlock];
    for (EJSWSWaiter *waiter in waiters) {
        if (waiter.active) {
            waiter.active = NO;
            [waiter.responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeAborted, @"websocket socket is closed")];
        }
    }
}

- (void)enqueueEvent:(NSDictionary *)event forSocket:(EJSWSSocketState *)state {
    if (state == nil || event == nil) {
        return;
    }
    NSString *eventKind = [event[@"event"] isKindOfClass:[NSString class]] ? event[@"event"] : @"";
    EJSProviderResponder *responder = nil;
    BOOL cleanupAfterDirectClose = NO;
    [state.lock lock];
    if (state.terminalQueued) {
        [state.lock unlock];
        return;
    }
    EJSWSWaiter *waiter = nil;
    while (state.waiters.count > 0u && waiter == nil) {
        EJSWSWaiter *candidate = state.waiters.firstObject;
        [state.waiters removeObjectAtIndex:0u];
        if (candidate.active) {
            waiter = candidate;
        }
    }
    if (waiter != nil) {
        waiter.active = NO;
        responder = waiter.responder;
    } else {
        [state.events addObject:event];
    }
    if ([eventKind isEqualToString:@"open"]) {
        state.openDispatched = YES;
    } else if ([eventKind isEqualToString:@"close"]) {
        state.terminalQueued = YES;
        cleanupAfterDirectClose = responder != nil;
    }
    [state.lock unlock];

    if (responder != nil) {
        NSError *encodeError = nil;
        NSData *data = EJSWSJSONData(event, &encodeError);
        [responder finishWithData:data error:encodeError];
        if (cleanupAfterDirectClose) {
            [self removeSocketForID:state.socketID];
        }
    }
}

- (void)enqueueError:(NSError *)error forSocket:(EJSWSSocketState *)state {
    NSDictionary *event = @{
        @"event": @"error",
        @"error": @{
            @"code": @((NSInteger)EJSWSProviderCodeForNSError(error)),
            @"message": error.localizedDescription ?: @"websocket error"
        }
    };
    [self enqueueEvent:event forSocket:state];
}

- (void)enqueueCloseForSocket:(EJSWSSocketState *)state
                         code:(NSInteger)code
                       reason:(NSString *)reason
                     wasClean:(BOOL)wasClean {
    if (state == nil) {
        return;
    }
    BOOL shouldQueue = NO;
    [state.lock lock];
    if (!state.terminalQueued) {
        shouldQueue = YES;
    }
    [state.lock unlock];
    if (!shouldQueue) {
        return;
    }
    [self enqueueEvent:@{
        @"event": @"close",
        @"code": @(code),
        @"reason": reason ?: @"",
        @"wasClean": @(wasClean)
    } forSocket:state];
}

- (void)failForOversizedMessageForSocket:(EJSWSSocketState *)state {
    if (state == nil) {
        return;
    }
    [self enqueueError:EJSWSProviderError(EJSProviderErrorCodeSecurity, @"websocket message exceeds maxMessageBytes")
             forSocket:state];
    [self enqueueCloseForSocket:state code:1009 reason:@"message too large" wasClean:NO];
    [state.task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1009 reason:nil];
}

- (void)drainReceiveLoopForSocketID:(NSString *)socketID {
    EJSWSSocketState *state = [self socketStateForID:socketID];
    if (state == nil) {
        return;
    }
    [state.task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(self->_queue, ^{
            EJSWSSocketState *innerState = [self socketStateForID:socketID];
            if (innerState == nil) {
                return;
            }
            if (error != nil) {
                [self enqueueError:error forSocket:innerState];
                [self enqueueCloseForSocket:innerState code:1006 reason:@"" wasClean:NO];
                return;
            }
            if (message.type == NSURLSessionWebSocketMessageTypeString) {
                NSString *text = message.string ?: @"";
                if (!EJSWSValidateMessageBytes([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding], NULL)) {
                    [self failForOversizedMessageForSocket:innerState];
                    return;
                }
                [self enqueueEvent:@{
                    @"event": @"message",
                    @"messageType": @"text",
                    @"data": text
                } forSocket:innerState];
            } else {
                NSData *data = message.data ?: [NSData data];
                if (!EJSWSValidateMessageBytes(data.length, NULL)) {
                    [self failForOversizedMessageForSocket:innerState];
                    return;
                }
                [self enqueueEvent:@{
                    @"event": @"message",
                    @"messageType": @"binary",
                    @"dataBase64": [data base64EncodedStringWithOptions:0] ?: @""
                } forSocket:innerState];
            }
            BOOL shouldContinue = NO;
            [innerState.lock lock];
            shouldContinue = !innerState.terminalQueued;
            [innerState.lock unlock];
            if (shouldContinue) {
                [self drainReceiveLoopForSocketID:socketID];
            }
        });
    }];
}

- (void)cancelWaiter:(EJSWSWaiter *)waiter socketID:(NSString *)socketID {
    dispatch_async(_queue, ^{
        EJSWSSocketState *state = [self socketStateForID:socketID];
        if (state == nil) {
            return;
        }
        BOOL wasActive = NO;
        [state.lock lock];
        if (waiter.active) {
            waiter.active = NO;
            [state.waiters removeObject:waiter];
            wasActive = YES;
        }
        [state.lock unlock];
        if (wasActive) {
            [waiter.responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeAborted, @"websocket nextEvent cancelled")];
        }
    });
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;
    NSDictionary *request = EJSWSJSONObjectFromData(payload, NULL);

    if ([methodID isEqualToString:@"connect"]) {
        NSDictionary *requestCopy = [request copy] ?: @{};
        dispatch_async(_queue, ^{
            NSString *socketID = EJSWSStringIsNonEmpty(requestCopy[@"socketID"]) ? requestCopy[@"socketID"] : nil;
            NSString *urlText = EJSWSStringIsNonEmpty(requestCopy[@"url"]) ? requestCopy[@"url"] : nil;
            NSArray *protocols = [requestCopy[@"protocols"] isKindOfClass:[NSArray class]] ? requestCopy[@"protocols"] : @[];
            if (socketID.length == 0u || urlText.length == 0u) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket connect requires socketID and url")];
                return;
            }
            for (id value in protocols) {
                if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0u) {
                    [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket protocols must be non-empty strings")];
                    return;
                }
            }
            NSURL *url = [NSURL URLWithString:urlText];
            NSString *scheme = url.scheme.lowercaseString ?: @"";
            if (url == nil || url.host.length == 0u || (![scheme isEqualToString:@"ws"] && ![scheme isEqualToString:@"wss"])) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket url is invalid")];
                return;
            }
            if (![_policy allowsURL:url]) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeSecurity, @"websocket request denied by ejs.network policy")];
                return;
            }
            NSInteger port = url.port != nil ? url.port.integerValue : [scheme isEqualToString:@"wss"] ? 443 : 80;
            int urlHostFamily = 0;
            BOOL urlHostIsLiteral = EJSWSAddressBytesFromString(url.host ?: @"", &urlHostFamily) != nil;
            if (!urlHostIsLiteral && ![_policy allowsUnpinnedHostnameResolution]) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeSecurity, @"websocket hostname requires unpinned default-allow policy")];
                return;
            }
            if (urlHostIsLiteral && ![_policy allowsResolvedAddress:url.host ?: @"" family:urlHostFamily port:port]) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeSecurity, @"websocket resolved address denied by ejs.network policy")];
                return;
            }
            if ([self socketStateForID:socketID] != nil) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket socketID already exists")];
                return;
            }

            NSURLSessionWebSocketTask *task = [_session webSocketTaskWithURL:url protocols:protocols];
            EJSWSSocketState *state = [[EJSWSSocketState alloc] initWithSocketID:socketID task:task];
            [_lock lock];
            _socketsByID[socketID] = state;
            _socketIDsByTaskID[@(task.taskIdentifier)] = socketID;
            [_lock unlock];

            [task resume];
            [self drainReceiveLoopForSocketID:socketID];

            NSError *encodeError = nil;
            NSData *result = EJSWSJSONData(@{ @"socketID": socketID }, &encodeError);
            [responder finishWithData:result error:encodeError];
        });
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"send"]) {
        NSDictionary *requestCopy = [request copy] ?: @{};
        NSData *transfer = [transferBuffer copy];
        dispatch_async(_queue, ^{
            NSString *socketID = EJSWSStringIsNonEmpty(requestCopy[@"socketID"]) ? requestCopy[@"socketID"] : nil;
            NSString *messageType = [requestCopy[@"messageType"] isKindOfClass:[NSString class]] ? requestCopy[@"messageType"] : nil;
            EJSWSSocketState *state = [self socketStateForID:socketID];
            if (socketID.length == 0u || state == nil || messageType.length == 0u) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket send requires valid socketID and messageType")];
                return;
            }

            NSURLSessionWebSocketMessage *message = nil;
            if ([messageType isEqualToString:@"text"]) {
                NSString *text = [requestCopy[@"data"] isKindOfClass:[NSString class]] ? requestCopy[@"data"] : nil;
                if (text == nil) {
                    [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket text send requires string data")];
                    return;
                }
                NSError *limitError = nil;
                if (!EJSWSValidateMessageBytes([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding], &limitError)) {
                    [responder finishWithData:nil error:limitError];
                    return;
                }
                message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
            } else if ([messageType isEqualToString:@"binary"]) {
                NSData *transferData = transfer != nil ? transfer : [NSData data];
                NSError *limitError = nil;
                if (!EJSWSValidateMessageBytes(transferData.length, &limitError)) {
                    [responder finishWithData:nil error:limitError];
                    return;
                }
                message = [[NSURLSessionWebSocketMessage alloc] initWithData:transferData];
            } else {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket messageType must be text or binary")];
                return;
            }

            [state.task sendMessage:message completionHandler:^(NSError *error) {
                dispatch_async(self->_queue, ^{
                    EJSWSSocketState *innerState = [self socketStateForID:socketID];
                    if (error != nil) {
                        if (innerState != nil) {
                            [self enqueueError:error forSocket:innerState];
                            [self enqueueCloseForSocket:innerState code:1006 reason:@"" wasClean:NO];
                        }
                        [responder finishWithData:nil error:EJSWSProviderError(EJSWSProviderCodeForNSError(error), error.localizedDescription ?: @"websocket send failed")];
                        return;
                    }
                    NSError *encodeError = nil;
                    NSData *result = EJSWSJSONData(@{ @"ok": @YES }, &encodeError);
                    [responder finishWithData:result error:encodeError];
                });
            }];
        });
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"close"]) {
        NSDictionary *requestCopy = [request copy] ?: @{};
        dispatch_async(_queue, ^{
            NSString *socketID = EJSWSStringIsNonEmpty(requestCopy[@"socketID"]) ? requestCopy[@"socketID"] : nil;
            NSNumber *codeValue = [requestCopy[@"code"] isKindOfClass:[NSNumber class]] ? requestCopy[@"code"] : nil;
            NSString *reason = [requestCopy[@"reason"] isKindOfClass:[NSString class]] ? requestCopy[@"reason"] : @"";
            EJSWSSocketState *state = [self socketStateForID:socketID];
            if (socketID.length == 0u || state == nil) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket close requires a valid socketID")];
                return;
            }

            NSInteger code = codeValue != nil ? codeValue.integerValue : 1000;
            if (code != 1000 && (code < 3000 || code > 4999)) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket close code must be 1000 or 3000-4999")];
                return;
            }
            NSData *reasonData = [reason dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            if (reasonData.length > 123u) {
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket close reason must be <= 123 UTF-8 bytes")];
                return;
            }
            [state.task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:reasonData.length > 0u ? reasonData : nil];
            NSError *encodeError = nil;
            NSData *result = EJSWSJSONData(@{ @"ok": @YES }, &encodeError);
            [responder finishWithData:result error:encodeError];
        });
        return [[EJSImmediateOperation alloc] init];
    }

    if ([methodID isEqualToString:@"nextEvent"]) {
        NSDictionary *requestCopy = [request copy] ?: @{};
        NSString *socketID = EJSWSStringIsNonEmpty(requestCopy[@"socketID"]) ? requestCopy[@"socketID"] : nil;
        if (socketID.length == 0u) {
            [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket nextEvent requires socketID")];
            return [[EJSImmediateOperation alloc] init];
        }
        EJSWSWaiter *waiter = [[EJSWSWaiter alloc] init];
        waiter.responder = responder;
        waiter.active = YES;
        dispatch_async(_queue, ^{
            EJSWSSocketState *state = [self socketStateForID:socketID];
            if (state == nil) {
                waiter.active = NO;
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket socketID is unknown")];
                return;
            }
            NSDictionary *event = nil;
            BOOL alreadyWaiting = NO;
            BOOL shouldCleanup = NO;
            [state.lock lock];
            if (!waiter.active) {
                [state.lock unlock];
                return;
            }
            if (state.events.count > 0u) {
                event = state.events.firstObject;
                [state.events removeObjectAtIndex:0u];
                if ([event[@"event"] isEqualToString:@"close"] && state.events.count == 0u) {
                    shouldCleanup = YES;
                }
            } else if (state.waiters.count > 0u) {
                alreadyWaiting = YES;
            } else {
                [state.waiters addObject:waiter];
            }
            [state.lock unlock];
            if (alreadyWaiting) {
                waiter.active = NO;
                [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeInvalidArgument, @"websocket nextEvent already pending")];
                return;
            }
            if (event != nil) {
                waiter.active = NO;
                NSError *encodeError = nil;
                NSData *data = EJSWSJSONData(event, &encodeError);
                [responder finishWithData:data error:encodeError];
                if (shouldCleanup) {
                    [self removeSocketForID:socketID];
                }
            }
        });
        return [[EJSBlockOperation alloc] initWithCancelBlock:^{
            [self cancelWaiter:waiter socketID:socketID];
        }];
    }

    [responder finishWithData:nil error:EJSWSProviderError(EJSProviderErrorCodeUnsupported, @"unsupported ejs.ws method")];
    return [[EJSImmediateOperation alloc] init];
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol {
    (void)session;
    dispatch_async(_queue, ^{
        [_lock lock];
        NSString *socketID = _socketIDsByTaskID[@(webSocketTask.taskIdentifier)];
        [_lock unlock];
        EJSWSSocketState *state = [self socketStateForID:socketID];
        if (state == nil) {
            return;
        }
        [self enqueueEvent:@{
            @"event": @"open",
            @"protocol": protocol ?: @""
        } forSocket:state];
    });
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(NSData *)reason {
    (void)session;
    dispatch_async(_queue, ^{
        [_lock lock];
        NSString *socketID = _socketIDsByTaskID[@(webSocketTask.taskIdentifier)];
        [_lock unlock];
        EJSWSSocketState *state = [self socketStateForID:socketID];
        if (state == nil) {
            return;
        }
        [self enqueueCloseForSocket:state code:(NSInteger)closeCode reason:EJSWSUTF8StringFromData(reason) wasClean:YES];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (error == nil) {
        return;
    }
    dispatch_async(_queue, ^{
        [_lock lock];
        NSString *socketID = _socketIDsByTaskID[@(task.taskIdentifier)];
        [_lock unlock];
        EJSWSSocketState *state = [self socketStateForID:socketID];
        if (state == nil) {
            return;
        }
        [self enqueueError:error forSocket:state];
        [self enqueueCloseForSocket:state code:1006 reason:@"" wasClean:NO];
    });
}
@end

#ifdef EJS_TEST
BOOL EJSWebSocketRunMessageLimitSelfTest(NSError **error) {
    NSError *localError = nil;
    if (!EJSWSValidateMessageBytes(EJSWSMaxMessageBytes, &localError)) {
        if (error != NULL) *error = localError ?: EJSWSProviderError(EJSProviderErrorCodeInternal, @"websocket max message size was rejected");
        return NO;
    }
    if (EJSWSValidateMessageBytes(EJSWSMaxMessageBytes + 1u, &localError) ||
        localError.code != EJSProviderErrorCodeSecurity) {
        if (error != NULL) *error = localError ?: EJSWSProviderError(EJSProviderErrorCodeInternal, @"websocket oversized message was accepted");
        return NO;
    }
    return YES;
}
#endif

static BOOL EJSWSInstallBundledScriptsIntoContext(EJSContext *context,
                                                  const EJSWSBundledScript *scripts,
                                                  size_t scriptCount,
                                                  NSError **error) {
    if (context == nil) {
        if (error != NULL) *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        return NO;
    }

    EJSWSPolicy *policy = EJSWSPolicyFromJSON([context configurationValueForKey:EJSWSNetworkConfigurationKey], error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction,
                                         context,
                                         @[ @"WebSocket", @"EJSWebSocket", @"EJSWebSocketError" ],
                                         error)) {
        return NO;
    }
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, [[EJSWSProvider alloc] initWithPolicy:policy], error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSWSBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSWSRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"EJSWS bundled script must be valid UTF-8");
            }
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
        if (![context evaluateScript:source filename:filename error:error]) {
            EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
            return NO;
        }
    }

    if (!EJSAppleInstallTransactionCommit(&transaction, error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }
    return YES;
}

BOOL EJSWebSocketInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSWSInstallBundledScriptsIntoContext(context, ejs_ws_scripts, ejs_ws_scripts_count, error);
}
