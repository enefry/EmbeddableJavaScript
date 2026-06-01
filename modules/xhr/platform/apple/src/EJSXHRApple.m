#import "EJSXHRApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_xhr_js_bundle.h"
#include <arpa/inet.h>
#include <math.h>
#include <netdb.h>
#include <netinet/in.h>
#include <string.h>

static NSString * const EJSXHRNetworkConfigurationKey = @"ejs.network";

static NSError *EJSXHRRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError *EJSXHRProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"xhr provider failed");
}

static BOOL EJSXHRStringIsNonEmpty(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0u;
}

static BOOL EJSXHRValueIsJSONBoolean(id value) {
    return value != nil && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL EJSXHRNumberIsIntegerInRange(id value, NSInteger min, NSInteger max) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    double doubleValue = [(NSNumber *)value doubleValue];
    NSInteger integerValue = [(NSNumber *)value integerValue];
    return floor(doubleValue) == doubleValue && integerValue >= min && integerValue <= max;
}

static NSData *EJSXHRAddressBytesFromString(NSString *address, int *familyOut) {
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

@interface EJSXHRCIDR : NSObject
@property (nonatomic, assign, readonly) int family;
@property (nonatomic, assign, readonly) NSInteger prefixLength;
@property (nonatomic, copy, readonly) NSData *bytes;
- (instancetype)initWithFamily:(int)family prefixLength:(NSInteger)prefixLength bytes:(NSData *)bytes;
- (BOOL)containsAddressBytes:(NSData *)bytes family:(int)family;
@end

@implementation EJSXHRCIDR
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

@interface EJSXHRAllowRule : NSObject
@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, copy, readonly) NSString *hostSuffix;
@property (nonatomic, strong, readonly, nullable) EJSXHRCIDR *cidr;
@property (nonatomic, copy, readonly) NSSet<NSString *> *protocols;
@property (nonatomic, copy, readonly) NSSet<NSNumber *> *ports;
@property (nonatomic, assign, readonly) NSInteger portRangeStart;
@property (nonatomic, assign, readonly) NSInteger portRangeEnd;
- (instancetype)initWithHost:(NSString *)host
                  hostSuffix:(NSString *)hostSuffix
                        cidr:(nullable EJSXHRCIDR *)cidr
                   protocols:(NSSet<NSString *> *)protocols
                       ports:(NSSet<NSNumber *> *)ports
              portRangeStart:(NSInteger)portRangeStart
                portRangeEnd:(NSInteger)portRangeEnd;
- (BOOL)matchesHost:(NSString *)host;
- (BOOL)matchesAddress:(NSString *)address family:(int)family;
- (BOOL)matchesExactAddress:(NSString *)address family:(int)family;
- (BOOL)allowsProtocol:(NSString *)protocol port:(NSInteger)port;
@end

@implementation EJSXHRAllowRule
- (instancetype)initWithHost:(NSString *)host
                  hostSuffix:(NSString *)hostSuffix
                        cidr:(EJSXHRCIDR *)cidr
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
        NSData *bytes = EJSXHRAddressBytesFromString(lower, &family);
        return bytes != nil && [self.cidr containsAddressBytes:bytes family:family];
    }
    return NO;
}

- (BOOL)matchesAddress:(NSString *)address family:(int)family {
    if (self.cidr == nil) {
        return NO;
    }
    int parsedFamily = 0;
    NSData *bytes = EJSXHRAddressBytesFromString(address, &parsedFamily);
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
        NSData *hostBytes = EJSXHRAddressBytesFromString(self.host, &hostFamily);
        NSData *addressBytes = EJSXHRAddressBytesFromString(lower, &addressFamily);
        if (hostBytes != nil && addressBytes != nil) {
            return hostFamily == family && addressFamily == family && [hostBytes isEqualToData:addressBytes];
        }
    }
    if (self.cidr != nil) {
        int parsedFamily = 0;
        NSData *bytes = EJSXHRAddressBytesFromString(lower, &parsedFamily);
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

static BOOL EJSXHRAddressIsLinkLocal(NSData *bytes, int family) {
    const unsigned char *value = bytes.bytes;
    if (family == 4 && bytes.length == 4u) {
        return value[0] == 169 && value[1] == 254;
    }
    if (family == 6 && bytes.length == 16u) {
        return value[0] == 0xfe && (value[1] & 0xc0) == 0x80;
    }
    return NO;
}

static BOOL EJSXHRAddressIsPrivate(NSData *bytes, int family) {
    const unsigned char *value = bytes.bytes;
    if (family == 4 && bytes.length == 4u) {
        return value[0] == 10 ||
            value[0] == 127 ||
            (value[0] == 172 && value[1] >= 16 && value[1] <= 31) ||
            (value[0] == 192 && value[1] == 168) ||
            EJSXHRAddressIsLinkLocal(bytes, family);
    }
    if (family == 6 && bytes.length == 16u) {
        BOOL loopback = YES;
        for (NSUInteger i = 0u; i < 15u; ++i) {
            if (value[i] != 0) {
                loopback = NO;
                break;
            }
        }
        return loopback && value[15] == 1 ? YES : ((value[0] & 0xfe) == 0xfc || EJSXHRAddressIsLinkLocal(bytes, family));
    }
    return NO;
}

@interface EJSXHRPolicy : NSObject
@property (nonatomic, assign, readonly) BOOL configured;
@property (nonatomic, assign, readonly) BOOL xhrEnabled;
@property (nonatomic, assign, readonly) BOOL outboundDefaultAllow;
@property (nonatomic, assign, readonly) BOOL denyPrivateNetworks;
@property (nonatomic, assign, readonly) BOOL denyLinkLocal;
@property (nonatomic, assign, readonly) NSInteger requestTimeoutMs;
@property (nonatomic, assign, readonly) NSInteger maxHeaderBytes;
@property (nonatomic, assign, readonly) NSInteger maxBodyBytes;
@property (nonatomic, copy, readonly) NSArray<EJSXHRAllowRule *> *outboundAllowRules;
+ (instancetype)disabledPolicy;
- (instancetype)initWithConfigured:(BOOL)configured
                        xhrEnabled:(BOOL)xhrEnabled
              outboundDefaultAllow:(BOOL)outboundDefaultAllow
               denyPrivateNetworks:(BOOL)denyPrivateNetworks
                      denyLinkLocal:(BOOL)denyLinkLocal
                   requestTimeoutMs:(NSInteger)requestTimeoutMs
                      maxHeaderBytes:(NSInteger)maxHeaderBytes
                         maxBodyBytes:(NSInteger)maxBodyBytes
                 outboundAllowRules:(NSArray<EJSXHRAllowRule *> *)outboundAllowRules;
- (BOOL)allowsURL:(NSURL *)url;
- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family port:(NSInteger)port;
- (BOOL)allowsUnpinnedHostnameResolution;
@end

@implementation EJSXHRPolicy
+ (instancetype)disabledPolicy {
    return [[EJSXHRPolicy alloc] initWithConfigured:NO
                                         xhrEnabled:NO
                               outboundDefaultAllow:NO
                                denyPrivateNetworks:NO
                                       denyLinkLocal:YES
                                   requestTimeoutMs:30000
                                      maxHeaderBytes:65536
                                         maxBodyBytes:8 * 1024 * 1024
                                  outboundAllowRules:@[]];
}

- (instancetype)initWithConfigured:(BOOL)configured
                        xhrEnabled:(BOOL)xhrEnabled
              outboundDefaultAllow:(BOOL)outboundDefaultAllow
               denyPrivateNetworks:(BOOL)denyPrivateNetworks
                      denyLinkLocal:(BOOL)denyLinkLocal
                   requestTimeoutMs:(NSInteger)requestTimeoutMs
                      maxHeaderBytes:(NSInteger)maxHeaderBytes
                         maxBodyBytes:(NSInteger)maxBodyBytes
                 outboundAllowRules:(NSArray<EJSXHRAllowRule *> *)outboundAllowRules {
    self = [super init];
    if (self != nil) {
        _configured = configured;
        _xhrEnabled = xhrEnabled;
        _outboundDefaultAllow = outboundDefaultAllow;
        _denyPrivateNetworks = denyPrivateNetworks;
        _denyLinkLocal = denyLinkLocal;
        _requestTimeoutMs = requestTimeoutMs;
        _maxHeaderBytes = maxHeaderBytes;
        _maxBodyBytes = maxBodyBytes;
        _outboundAllowRules = [outboundAllowRules copy] ?: @[];
    }
    return self;
}

- (BOOL)allowsURL:(NSURL *)url {
    if (!self.configured || !self.xhrEnabled) {
        return NO;
    }
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return NO;
    }
    NSString *host = url.host.lowercaseString ?: @"";
    if (host.length == 0u) {
        return NO;
    }
    NSInteger port = url.port != nil ? url.port.integerValue : [scheme isEqualToString:@"https"] ? 443 : 80;
    for (EJSXHRAllowRule *rule in self.outboundAllowRules) {
        if ([rule matchesHost:host] && [rule allowsProtocol:@"xhr" port:port]) {
            return YES;
        }
    }
    return self.outboundDefaultAllow;
}

- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family port:(NSInteger)port {
    int parsedFamily = 0;
    NSData *bytes = EJSXHRAddressBytesFromString(address, &parsedFamily);
    if (bytes == nil || parsedFamily != family) {
        return NO;
    }
    if (self.denyLinkLocal && EJSXHRAddressIsLinkLocal(bytes, family)) {
        return NO;
    }
    if (self.denyPrivateNetworks && EJSXHRAddressIsPrivate(bytes, family)) {
        return NO;
    }
    if (self.outboundDefaultAllow) {
        return YES;
    }
    for (EJSXHRAllowRule *rule in self.outboundAllowRules) {
        if (([rule matchesAddress:address family:family] || [rule matchesExactAddress:address family:family]) &&
            [rule allowsProtocol:@"xhr" port:port]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)allowsUnpinnedHostnameResolution {
    return self.outboundDefaultAllow && !self.denyPrivateNetworks && !self.denyLinkLocal;
}
@end

static EJSXHRCIDR *EJSXHRCIDRFromString(NSString *value, NSError **error) {
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"/"];
    if (parts.count != 2u || parts[0].length == 0u || parts[1].length == 0u) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr must be address/prefix");
        return nil;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([parts[1] rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr prefix must be an integer");
        return nil;
    }
    int family = 0;
    NSData *bytes = EJSXHRAddressBytesFromString(parts[0], &family);
    NSInteger prefix = parts[1].integerValue;
    NSInteger maxPrefix = family == 4 ? 32 : family == 6 ? 128 : -1;
    if (bytes == nil || prefix < 0 || prefix > maxPrefix) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr is invalid");
        return nil;
    }
    return [[EJSXHRCIDR alloc] initWithFamily:family prefixLength:prefix bytes:bytes];
}

static BOOL EJSXHRValidatePortFields(NSDictionary *rule, NSError **error) {
    id ports = rule[@"ports"];
    if (ports != nil) {
        if (![ports isKindOfClass:[NSArray class]]) {
            if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule ports must be an array");
            return NO;
        }
        for (id port in (NSArray *)ports) {
            if (!EJSXHRNumberIsIntegerInRange(port, 1, 65535)) {
                if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule ports must be 1-65535");
                return NO;
            }
        }
    }
    id portRange = rule[@"portRange"];
    if (portRange != nil) {
        if (![portRange isKindOfClass:[NSArray class]] || [(NSArray *)portRange count] != 2u ||
            !EJSXHRNumberIsIntegerInRange(((NSArray *)portRange)[0], 0, 65535) ||
            !EJSXHRNumberIsIntegerInRange(((NSArray *)portRange)[1], 0, 65535) ||
            [((NSArray *)portRange)[0] integerValue] > [((NSArray *)portRange)[1] integerValue]) {
            if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule portRange must be [min,max]");
            return NO;
        }
    }
    return YES;
}

static BOOL EJSXHRValidateOptionalBoolean(NSDictionary *object, NSString *key, NSString *field, NSError **error) {
    id value = object[key];
    if (value == nil) {
        return YES;
    }
    if (!EJSXHRValueIsJSONBoolean(value)) {
        if (error != NULL) {
            *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, [NSString stringWithFormat:@"%@ must be boolean", field]);
        }
        return NO;
    }
    return YES;
}

static NSInteger EJSXHRPolicyLimit(NSDictionary *limits,
                                   NSString *key,
                                   NSInteger defaultValue,
                                   NSInteger minimum,
                                   NSInteger maximum,
                                   NSError **error) {
    id value = limits[key];
    if (value == nil) {
        return defaultValue;
    }
    if (!EJSXHRNumberIsIntegerInRange(value, minimum, maximum)) {
        if (error != NULL) {
            *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument,
                                        [NSString stringWithFormat:@"ejs.network limits.%@ is invalid", key]);
        }
        return -1;
    }
    return [(NSNumber *)value integerValue];
}

static EJSXHRPolicy *EJSXHRPolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0u) {
        return [EJSXHRPolicy disabledPolicy];
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id value = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network configuration must be a JSON object");
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    if (!EJSXHRNumberIsIntegerInRange(object[@"version"], 1, 1)) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network requires version 1");
        return nil;
    }
    NSDictionary *capabilities = [object[@"capabilities"] isKindOfClass:[NSDictionary class]] ? object[@"capabilities"] : nil;
    NSDictionary *outbound = [object[@"outbound"] isKindOfClass:[NSDictionary class]] ? object[@"outbound"] : nil;
    if (capabilities == nil || outbound == nil) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network requires capabilities and outbound");
        return nil;
    }
    if (!EJSXHRValidateOptionalBoolean(capabilities, @"xhr", @"ejs.network capabilities.xhr", error) ||
        !EJSXHRValidateOptionalBoolean(outbound, @"denyPrivateNetworks", @"ejs.network outbound.denyPrivateNetworks", error) ||
        !EJSXHRValidateOptionalBoolean(outbound, @"denyLinkLocal", @"ejs.network outbound.denyLinkLocal", error)) {
        return nil;
    }

    NSString *defaultRule = [outbound[@"default"] isKindOfClass:[NSString class]] ? outbound[@"default"] : @"deny";
    BOOL defaultAllow = [defaultRule isEqualToString:@"allow"];
    if (!defaultAllow && ![defaultRule isEqualToString:@"deny"]) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network outbound.default must be allow or deny");
        return nil;
    }

    NSArray *allowObjects = [outbound[@"allow"] isKindOfClass:[NSArray class]] ? outbound[@"allow"] : @[];
    if (outbound[@"allow"] != nil && ![outbound[@"allow"] isKindOfClass:[NSArray class]]) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network outbound.allow must be an array");
        return nil;
    }
    NSDictionary *limits = [object[@"limits"] isKindOfClass:[NSDictionary class]] ? object[@"limits"] : @{};
    if (object[@"limits"] != nil && ![object[@"limits"] isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network limits must be an object");
        return nil;
    }
    NSDictionary *http = [object[@"http"] isKindOfClass:[NSDictionary class]] ? object[@"http"] : @{};
    if (object[@"http"] != nil && ![object[@"http"] isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network http must be an object");
        return nil;
    }
    if (!EJSXHRValidateOptionalBoolean(http, @"useSystemProxy", @"ejs.network http.useSystemProxy", error)) {
        return nil;
    }
    if ([http[@"useSystemProxy"] boolValue]) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network http.useSystemProxy is not supported by xhr Phase 4C");
        return nil;
    }
    NSInteger requestTimeoutMs = EJSXHRPolicyLimit(limits, @"requestTimeoutMs", 30000, 1, 300000, error);
    if (requestTimeoutMs < 0) {
        return nil;
    }
    NSInteger maxHeaderBytes = EJSXHRPolicyLimit(limits, @"maxHeaderBytes", 65536, 1, 1024 * 1024, error);
    if (maxHeaderBytes < 0) {
        return nil;
    }
    NSInteger maxBodyBytes = EJSXHRPolicyLimit(limits, @"maxBodyBytes", 8 * 1024 * 1024, 0, 64 * 1024 * 1024, error);
    if (maxBodyBytes < 0) {
        return nil;
    }

    NSMutableArray<EJSXHRAllowRule *> *outboundRules = [[NSMutableArray alloc] init];
    for (id item in allowObjects) {
        NSDictionary *rule = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        if (rule == nil) {
            if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network allow rules must be objects");
            return nil;
        }

        NSString *host = EJSXHRStringIsNonEmpty(rule[@"host"]) ? rule[@"host"] : @"";
        NSString *hostSuffix = EJSXHRStringIsNonEmpty(rule[@"hostSuffix"]) ? rule[@"hostSuffix"] : @"";
        EJSXHRCIDR *cidr = nil;
        if (rule[@"cidr"] != nil) {
            if (!EJSXHRStringIsNonEmpty(rule[@"cidr"])) {
                if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule cidr must be a string");
                return nil;
            }
            cidr = EJSXHRCIDRFromString(rule[@"cidr"], error);
            if (cidr == nil) {
                return nil;
            }
        }
        if (host.length == 0u && hostSuffix.length == 0u && cidr == nil) {
            if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network allow rule requires host, hostSuffix, or cidr");
            return nil;
        }

        NSArray *protocolValues = [rule[@"protocols"] isKindOfClass:[NSArray class]] ? rule[@"protocols"] : @[];
        for (id protocol in protocolValues) {
            if (![protocol isKindOfClass:[NSString class]]) {
                if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule protocols must be strings");
                return nil;
            }
        }
        if (!EJSXHRValidatePortFields(rule, error)) {
            return nil;
        }

        NSMutableSet<NSString *> *protocols = [[NSMutableSet alloc] init];
        for (NSString *protocol in protocolValues) {
            NSString *lower = protocol.lowercaseString;
            if (![lower isEqualToString:@"dns"] &&
                ![lower isEqualToString:@"tcp"] &&
                ![lower isEqualToString:@"udp"] &&
                ![lower isEqualToString:@"xhr"] &&
                ![lower isEqualToString:@"ws"]) {
                if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule protocol is unsupported");
                return nil;
            }
            [protocols addObject:lower];
        }

        NSMutableSet<NSNumber *> *ports = [[NSMutableSet alloc] init];
        for (NSNumber *port in ([rule[@"ports"] isKindOfClass:[NSArray class]] ? rule[@"ports"] : @[])) {
            [ports addObject:@(port.integerValue)];
        }
        NSInteger portRangeStart = -1;
        NSInteger portRangeEnd = -1;
        if ([rule[@"portRange"] isKindOfClass:[NSArray class]]) {
            portRangeStart = [rule[@"portRange"][0] integerValue];
            portRangeEnd = [rule[@"portRange"][1] integerValue];
        }

        [outboundRules addObject:[[EJSXHRAllowRule alloc] initWithHost:host
                                                             hostSuffix:hostSuffix
                                                                   cidr:cidr
                                                              protocols:protocols
                                                                  ports:ports
                                                         portRangeStart:portRangeStart
                                                           portRangeEnd:portRangeEnd]];
    }

    return [[EJSXHRPolicy alloc] initWithConfigured:YES
                                         xhrEnabled:[capabilities[@"xhr"] boolValue]
                               outboundDefaultAllow:defaultAllow
                                denyPrivateNetworks:[outbound[@"denyPrivateNetworks"] boolValue]
                                       denyLinkLocal:outbound[@"denyLinkLocal"] == nil ? YES : [outbound[@"denyLinkLocal"] boolValue]
                                   requestTimeoutMs:requestTimeoutMs
                                      maxHeaderBytes:maxHeaderBytes
                                         maxBodyBytes:maxBodyBytes
                                  outboundAllowRules:outboundRules];
}

static NSDictionary *EJSXHRJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr payload is required");
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData *EJSXHRJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSXHRProviderError(EJSProviderErrorCodeInternal, @"Failed to encode xhr response");
    }
    return data;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *EJSXHRHeadersFromResponse(NSHTTPURLResponse *response) {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *headers = [[NSMutableArray alloc] init];
    for (id key in response.allHeaderFields) {
        NSString *name = [key isKindOfClass:[NSString class]] ? (NSString *)key : [key description];
        NSString *value = [response.allHeaderFields[key] isKindOfClass:[NSString class]]
            ? (NSString *)response.allHeaderFields[key]
            : [[response.allHeaderFields[key] description] copy];
        if (name.length == 0u || value.length == 0u) {
            continue;
        }
        [headers addObject:@{
            @"name": name,
            @"value": value
        }];
    }
    return headers;
}

static BOOL EJSXHRIsForbiddenRequestHeader(NSString *name) {
    static NSSet<NSString *> *forbidden = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        forbidden = [NSSet setWithArray:@[
            @"accept-charset",
            @"accept-encoding",
            @"authorization",
            @"connection",
            @"content-length",
            @"cookie",
            @"cookie2",
            @"host",
            @"keep-alive",
            @"proxy-connection",
            @"proxy-authorization",
            @"te",
            @"trailer",
            @"transfer-encoding",
            @"upgrade"
        ]];
    });
    return [forbidden containsObject:name.lowercaseString];
}

static NSUInteger EJSXHRHeaderBytes(NSString *name, NSString *value) {
    return [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
        4u;
}

static NSDictionary<NSString *, id> *EJSXHRProgressPayloadFromResponse(NSHTTPURLResponse *response, NSData *data) {
    NSUInteger loadedBytes = data.length;
    NSString *contentLengthValue = nil;
    id rawContentLength = response.allHeaderFields[@"Content-Length"];
    if ([rawContentLength isKindOfClass:[NSString class]]) {
        contentLengthValue = [(NSString *)rawContentLength stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if ([rawContentLength respondsToSelector:@selector(stringValue)]) {
        contentLengthValue = [[rawContentLength stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if (rawContentLength != nil) {
        contentLengthValue = [[rawContentLength description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    BOOL lengthComputable = NO;
    NSUInteger totalBytes = loadedBytes;
    if (contentLengthValue.length > 0u) {
        NSScanner *scanner = [NSScanner scannerWithString:contentLengthValue];
        long long parsed = 0;
        if ([scanner scanLongLong:&parsed] && scanner.isAtEnd && parsed >= 0) {
            lengthComputable = YES;
            totalBytes = (NSUInteger)parsed;
        }
    }
    return @{
        @"loaded": @(loadedBytes),
        @"total": @(totalBytes),
        @"lengthComputable": @(lengthComputable)
    };
}

#ifdef EJS_TEST
static BOOL EJSXHRTestShouldCancelBeforeTaskRegistration(NSURL *url) {
    return [url.path isEqualToString:@"/cancel-before-register"];
}
#endif

static NSString *EJSXHRAddressFromSockaddr(const struct sockaddr *addr) {
    char addressBuffer[INET6_ADDRSTRLEN] = { 0 };
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *in4 = (const struct sockaddr_in *)addr;
        if (inet_ntop(AF_INET, &in4->sin_addr, addressBuffer, sizeof(addressBuffer)) == NULL) {
            return @"";
        }
        return [NSString stringWithUTF8String:addressBuffer] ?: @"";
    }
    if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        if (inet_ntop(AF_INET6, &in6->sin6_addr, addressBuffer, sizeof(addressBuffer)) == NULL) {
            return @"";
        }
        return [NSString stringWithUTF8String:addressBuffer] ?: @"";
    }
    return @"";
}

static BOOL EJSXHRValidateResolvedURL(EJSXHRPolicy *policy, NSURL *url, NSError **error) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSString *service = [NSString stringWithFormat:@"%ld",
                         (long)(url.port != nil ? url.port.integerValue : [scheme isEqualToString:@"https"] ? 443 : 80)];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *addresses = NULL;
    int rc = getaddrinfo(url.host.UTF8String, service.UTF8String, &hints, &addresses);
    if (rc != 0) {
        if (error != NULL) {
            *error = EJSXHRProviderError(EJSProviderErrorCodeNetwork,
                                         [NSString stringWithFormat:@"xhr lookup %@ failed: %s", url.host ?: @"", gai_strerror(rc)]);
        }
        return NO;
    }

    BOOL sawAddress = NO;
    BOOL allowed = YES;
    NSInteger port = service.integerValue;
    for (struct addrinfo *cursor = addresses; cursor != NULL; cursor = cursor->ai_next) {
        int family = cursor->ai_family == AF_INET ? 4 : cursor->ai_family == AF_INET6 ? 6 : 0;
        if (family == 0) {
            continue;
        }
        NSString *address = EJSXHRAddressFromSockaddr(cursor->ai_addr);
        if (address.length == 0u) {
            continue;
        }
        sawAddress = YES;
        if (![policy allowsResolvedAddress:address family:family port:port]) {
            allowed = NO;
            break;
        }
    }
    freeaddrinfo(addresses);

    if (!sawAddress) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeNetwork, @"xhr lookup returned no usable addresses");
        return NO;
    }
    if (!allowed) {
        if (error != NULL) {
            *error = EJSXHRProviderError(EJSProviderErrorCodeSecurity,
                                         [NSString stringWithFormat:@"xhr %@ resolved address denied by ejs.network policy", url.host ?: @""]);
        }
        return NO;
    }
    return YES;
}

@interface EJSXHRTaskState : NSObject
@property (nonatomic, copy, readonly) NSString *requestID;
@property (nonatomic, copy, readonly) NSString *responseType;
@property (nonatomic, strong, readonly) EJSProviderResponder *responder;
@property (nonatomic, strong, readonly) NSMutableData *bodyData;
@property (nonatomic, strong, nullable) NSHTTPURLResponse *httpResponse;
@property (nonatomic, assign) BOOL finished;
- (instancetype)initWithRequestID:(NSString *)requestID
                     responseType:(NSString *)responseType
                        responder:(EJSProviderResponder *)responder;
@end

@implementation EJSXHRTaskState
- (instancetype)initWithRequestID:(NSString *)requestID
                     responseType:(NSString *)responseType
                        responder:(EJSProviderResponder *)responder {
    self = [super init];
    if (self != nil) {
        _requestID = [requestID copy] ?: @"";
        _responseType = [responseType copy] ?: @"";
        _responder = responder;
        _bodyData = [[NSMutableData alloc] init];
        _httpResponse = nil;
        _finished = NO;
    }
    return self;
}
@end

@interface EJSXHRProvider : NSObject <EJSProvider, NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSXHRPolicy *)policy;
@end

@implementation EJSXHRProvider {
    EJSXHRPolicy *_policy;
    NSURLSession *_session;
    dispatch_queue_t _queue;
    NSLock *_tasksLock;
    NSMutableDictionary<NSString *, NSURLSessionDataTask *> *_tasksByRequestID;
    NSMutableDictionary<NSNumber *, EJSXHRTaskState *> *_statesByTaskID;
    NSMutableSet<NSString *> *_pendingRequestIDs;
    NSMutableSet<NSString *> *_cancelledRequestIDs;
}

- (instancetype)initWithPolicy:(EJSXHRPolicy *)policy {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.xhr";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.xhr.provider", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache = nil;
        configuration.HTTPCookieStorage = nil;
        configuration.connectionProxyDictionary = @{};
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
        _tasksLock = [[NSLock alloc] init];
        _tasksByRequestID = [[NSMutableDictionary alloc] init];
        _statesByTaskID = [[NSMutableDictionary alloc] init];
        _pendingRequestIDs = [[NSMutableSet alloc] init];
        _cancelledRequestIDs = [[NSMutableSet alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_tasksLock lock];
    NSArray<NSURLSessionDataTask *> *tasks = _tasksByRequestID.allValues;
    [_tasksByRequestID removeAllObjects];
    [_statesByTaskID removeAllObjects];
    [_pendingRequestIDs removeAllObjects];
    [_cancelledRequestIDs removeAllObjects];
    [_tasksLock unlock];
    for (NSURLSessionDataTask *task in tasks) {
        [task cancel];
    }
    [_session invalidateAndCancel];
}

- (void)cancelRequestID:(NSString *)requestID {
    if (requestID.length == 0u) {
        return;
    }
    [_tasksLock lock];
    NSURLSessionDataTask *task = _tasksByRequestID[requestID];
    if (task == nil && [_pendingRequestIDs containsObject:requestID]) {
        [_cancelledRequestIDs addObject:requestID];
    }
    [_tasksLock unlock];
    if (task != nil) {
        [task cancel];
    }
}

- (BOOL)consumeCancelledRequestID:(NSString *)requestID {
    [_tasksLock lock];
    BOOL cancelled = [_cancelledRequestIDs containsObject:requestID];
    if (cancelled) {
        [_cancelledRequestIDs removeObject:requestID];
    }
    [_tasksLock unlock];
    return cancelled;
}

- (void)addPendingRequestID:(NSString *)requestID {
    if (requestID.length == 0u) {
        return;
    }
    [_tasksLock lock];
    [_pendingRequestIDs addObject:requestID];
    [_tasksLock unlock];
}

- (void)removePendingRequestID:(NSString *)requestID {
    if (requestID.length == 0u) {
        return;
    }
    [_tasksLock lock];
    [_pendingRequestIDs removeObject:requestID];
    [_cancelledRequestIDs removeObject:requestID];
    [_tasksLock unlock];
}

- (NSError *)taskErrorAsProviderError:(NSError *)taskError {
    EJSProviderErrorCode providerCode = EJSProviderErrorCodeNetwork;
    NSString *message = @"xhr request failed";
    if (taskError.code == NSURLErrorCancelled) {
        providerCode = EJSProviderErrorCodeAborted;
        message = @"xhr request cancelled";
    } else if (taskError.code == NSURLErrorTimedOut) {
        providerCode = EJSProviderErrorCodeTimeout;
        message = @"xhr request timed out";
    } else if (taskError.code == NSURLErrorServerCertificateUntrusted ||
               taskError.code == NSURLErrorServerCertificateHasBadDate ||
               taskError.code == NSURLErrorServerCertificateHasUnknownRoot ||
               taskError.code == NSURLErrorServerCertificateNotYetValid ||
               taskError.code == NSURLErrorSecureConnectionFailed) {
        providerCode = EJSProviderErrorCodeTLS;
        message = @"xhr tls handshake failed";
    }
    return [NSError errorWithDomain:EJSProviderErrorDomain
                               code:providerCode
                           userInfo:@{
                               NSLocalizedDescriptionKey: message,
                               NSUnderlyingErrorKey: taskError
                           }];
}

- (EJSXHRTaskState *)taskStateForTaskIdentifier:(NSUInteger)taskIdentifier {
    [_tasksLock lock];
    EJSXHRTaskState *state = _statesByTaskID[@(taskIdentifier)];
    [_tasksLock unlock];
    return state;
}

- (void)finishTaskState:(EJSXHRTaskState *)state
            taskAndMaps:(NSURLSessionTask *)task
                   data:(NSData *)data
                  error:(NSError *)error {
    EJSProviderResponder *responder = nil;
    [_tasksLock lock];
    EJSXHRTaskState *stored = _statesByTaskID[@(task.taskIdentifier)];
    if (stored == state && !state.finished) {
        state.finished = YES;
        [_statesByTaskID removeObjectForKey:@(task.taskIdentifier)];
        [_tasksByRequestID removeObjectForKey:state.requestID];
        [_pendingRequestIDs removeObject:state.requestID];
        [_cancelledRequestIDs removeObject:state.requestID];
        responder = state.responder;
    }
    [_tasksLock unlock];
    if (responder != nil) {
        EJSProviderResponder *heldResponder = responder;
        NSData *heldData = data;
        NSError *heldError = error;
        dispatch_async(_queue, ^{
            [heldResponder finishWithData:heldData error:heldError];
        });
    }
}

- (void)finishTaskStateWithError:(EJSXHRTaskState *)state
                            task:(NSURLSessionTask *)task
                           error:(NSError *)error {
    [self finishTaskState:state taskAndMaps:task data:nil error:error];
}

- (void)finishTaskStateWithSuccess:(EJSXHRTaskState *)state
                              task:(NSURLSessionTask *)task {
    NSHTTPURLResponse *httpResponse = state.httpResponse;
    if (httpResponse == nil) {
        [self finishTaskStateWithError:state
                                  task:task
                                 error:EJSXHRProviderError(EJSProviderErrorCodeUnsupported, @"xhr did not return an HTTP response")];
        return;
    }

    NSData *data = [state.bodyData copy];
    NSMutableDictionary<NSString *, id> *result = [@{
        @"status": @(httpResponse.statusCode),
        @"statusText": [NSHTTPURLResponse localizedStringForStatusCode:httpResponse.statusCode] ?: @"",
        @"responseURL": httpResponse.URL.absoluteString ?: @"",
        @"headers": EJSXHRHeadersFromResponse(httpResponse)
    } mutableCopy];

    [result addEntriesFromDictionary:EJSXHRProgressPayloadFromResponse(httpResponse, data)];
    if ([state.responseType isEqualToString:@"arraybuffer"]) {
        result[@"bodyBase64"] = data.length > 0u ? [data base64EncodedStringWithOptions:0] : @"";
    } else {
        NSString *bodyTextResult = @"";
        if (data.length > 0u) {
            bodyTextResult = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (bodyTextResult == nil) {
                [self finishTaskStateWithError:state
                                          task:task
                                         error:EJSXHRProviderError(EJSProviderErrorCodeUnsupported, @"xhr response body is not UTF-8 text")];
                return;
            }
        }
        result[@"bodyText"] = bodyTextResult ?: @"";
    }
    NSError *jsonError = nil;
    NSData *resultData = EJSXHRJSONData(result, &jsonError);
    [self finishTaskState:state taskAndMaps:task data:resultData error:jsonError];
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)context;
    if ([methodID isEqualToString:@"send"]) {
        NSError *parseError = nil;
        NSDictionary *request = EJSXHRJSONObjectFromData(payload, &parseError);
        if (request == nil) {
            [responder finishWithData:nil error:parseError];
            return [[EJSImmediateOperation alloc] init];
        }
        NSDictionary *requestCopy = [request copy];
        NSData *requestTransfer = [transferBuffer copy];
        NSString *requestID = EJSXHRStringIsNonEmpty(requestCopy[@"requestID"]) ? requestCopy[@"requestID"] : @"";
        [self addPendingRequestID:requestID];
        dispatch_async(_queue, ^{
            @autoreleasepool {
                NSError *sendError = nil;
                NSURLSessionDataTask *task = [self sendWithRequest:requestCopy
                                                    transferBuffer:requestTransfer
                                                         responder:responder
                                                             error:&sendError];
                if (task == nil) {
                    [self removePendingRequestID:requestID];
                    [responder finishWithData:nil error:sendError];
                }
            }
        });
        return [[EJSBlockOperation alloc] initWithCancelBlock:^{
            [self cancelRequestID:requestID];
        }];
    }
    if ([methodID isEqualToString:@"abort"]) {
        NSError *parseError = nil;
        NSDictionary *request = EJSXHRJSONObjectFromData(payload, &parseError);
        if (request == nil) {
            [responder finishWithData:nil error:parseError];
            return [[EJSImmediateOperation alloc] init];
        }
        NSString *requestID = EJSXHRStringIsNonEmpty(request[@"requestID"]) ? request[@"requestID"] : nil;
        if (requestID == nil) {
            [responder finishWithData:nil error:EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr abort requires requestID")];
            return [[EJSImmediateOperation alloc] init];
        }
        [self cancelRequestID:requestID];
        NSData *result = EJSXHRJSONData(@{ @"ok": @YES }, &parseError);
        [responder finishWithData:result error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    [responder finishWithData:nil error:EJSXHRProviderError(EJSProviderErrorCodeUnsupported, @"unsupported ejs.xhr method")];
    return [[EJSImmediateOperation alloc] init];
}

- (NSURLSessionDataTask *)sendWithRequest:(NSDictionary *)request
                           transferBuffer:(NSData *)transferBuffer
                                responder:(EJSProviderResponder *)responder
                                    error:(NSError **)error {
    NSString *requestID = EJSXHRStringIsNonEmpty(request[@"requestID"]) ? request[@"requestID"] : nil;
    NSString *method = EJSXHRStringIsNonEmpty(request[@"method"]) ? request[@"method"] : nil;
    NSString *urlText = EJSXHRStringIsNonEmpty(request[@"url"]) ? request[@"url"] : nil;
    NSString *responseType = [request[@"responseType"] isKindOfClass:[NSString class]] ? request[@"responseType"] : @"";
    NSInteger timeoutMs = [request[@"timeoutMs"] isKindOfClass:[NSNumber class]] ? [request[@"timeoutMs"] integerValue] : 0;
    NSString *bodyText = [request[@"bodyText"] isKindOfClass:[NSString class]] ? request[@"bodyText"] : nil;
    NSArray *headers = [request[@"headers"] isKindOfClass:[NSArray class]] ? request[@"headers"] : @[];
    if (requestID.length == 0u || method.length == 0u || urlText.length == 0u) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr send requires requestID, method, and url");
        return nil;
    }
    if ([self consumeCancelledRequestID:requestID]) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeAborted, @"xhr request is cancelled");
        return nil;
    }
    if (![responseType isEqualToString:@""] &&
        ![responseType isEqualToString:@"text"] &&
        ![responseType isEqualToString:@"arraybuffer"] &&
        ![responseType isEqualToString:@"json"]) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeUnsupported, @"xhr responseType supports only empty, text, arraybuffer, and json");
        return nil;
    }
    if (timeoutMs < 0) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr timeoutMs must be >= 0");
        return nil;
    }

    NSURL *url = [NSURL URLWithString:urlText];
    if (url == nil || url.scheme.length == 0u || url.host.length == 0u) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr url is invalid");
        return nil;
    }
    if (![_policy allowsURL:url]) {
        if (error != NULL) {
            *error = EJSXHRProviderError(EJSProviderErrorCodeSecurity,
                                         [NSString stringWithFormat:@"xhr %@ denied by ejs.network policy", url.host ?: @""]);
        }
        return nil;
    }
    int urlHostFamily = 0;
    BOOL urlHostIsLiteral = EJSXHRAddressBytesFromString(url.host ?: @"", &urlHostFamily) != nil;
    if (!urlHostIsLiteral && ![_policy allowsUnpinnedHostnameResolution]) {
        if (error != NULL) {
            *error = EJSXHRProviderError(EJSProviderErrorCodeSecurity,
                                         @"xhr hostname requests require outbound default allow without private/link-local restrictions in Phase 4C");
        }
        return nil;
    }
    if (!EJSXHRValidateResolvedURL(_policy, url, error)) {
        return nil;
    }

    NSMutableURLRequest *urlRequest = [[NSMutableURLRequest alloc] initWithURL:url];
    urlRequest.HTTPMethod = method.uppercaseString;
    NSInteger effectiveTimeoutMs = timeoutMs > 0 ? MIN(timeoutMs, _policy.requestTimeoutMs) : _policy.requestTimeoutMs;
    urlRequest.timeoutInterval = (NSTimeInterval)effectiveTimeoutMs / 1000.0;

    NSUInteger requestHeaderBytes = 0u;
    for (id item in headers) {
        NSDictionary *entry = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        NSString *name = entry != nil && [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : nil;
        NSString *value = entry != nil && [entry[@"value"] isKindOfClass:[NSString class]] ? entry[@"value"] : nil;
        if (name.length == 0u || value == nil) {
            if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeInvalidArgument, @"xhr header entries must include name and value");
            return nil;
        }
        if (EJSXHRIsForbiddenRequestHeader(name)) {
            if (error != NULL) {
                *error = EJSXHRProviderError(EJSProviderErrorCodeSecurity,
                                             [NSString stringWithFormat:@"xhr request header is forbidden: %@", name]);
            }
            return nil;
        }
        requestHeaderBytes += EJSXHRHeaderBytes(name, value);
        if (requestHeaderBytes > (NSUInteger)_policy.maxHeaderBytes) {
            if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeSecurity, @"xhr request headers exceed policy limit");
            return nil;
        }
        [urlRequest setValue:value forHTTPHeaderField:name];
    }

    NSData *bodyData = nil;
    if (transferBuffer.length > 0u) {
        bodyData = transferBuffer;
    } else if (bodyText != nil) {
        bodyData = [bodyText dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    }
    if (bodyData.length > (NSUInteger)_policy.maxBodyBytes) {
        if (error != NULL) *error = EJSXHRProviderError(EJSProviderErrorCodeSecurity, @"xhr request body exceeds policy limit");
        return nil;
    }
    if (bodyData != nil) {
        urlRequest.HTTPBody = bodyData;
    }

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:urlRequest];
    EJSXHRTaskState *taskState = [[EJSXHRTaskState alloc] initWithRequestID:requestID
                                                                responseType:responseType
                                                                   responder:responder];

#ifdef EJS_TEST
    if (EJSXHRTestShouldCancelBeforeTaskRegistration(url)) {
        [self cancelRequestID:requestID];
    }
#endif

    BOOL cancelImmediately = NO;
    [_tasksLock lock];
    [_pendingRequestIDs removeObject:requestID];
    if ([_cancelledRequestIDs containsObject:requestID]) {
        [_cancelledRequestIDs removeObject:requestID];
        cancelImmediately = YES;
    } else {
        _tasksByRequestID[requestID] = task;
        _statesByTaskID[@(task.taskIdentifier)] = taskState;
    }
    [_tasksLock unlock];
    if (cancelImmediately) {
        [task cancel];
        if (error != NULL) {
            *error = EJSXHRProviderError(EJSProviderErrorCodeAborted, @"xhr request is cancelled");
        }
        return nil;
    }
    [task resume];
    return task;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    EJSXHRTaskState *state = [self taskStateForTaskIdentifier:dataTask.taskIdentifier];
    if (state == nil || state.finished) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)response
        : nil;
    if (httpResponse == nil) {
        [self finishTaskStateWithError:state
                                  task:dataTask
                                 error:EJSXHRProviderError(EJSProviderErrorCodeUnsupported, @"xhr did not return an HTTP response")];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSUInteger responseHeaderBytes = 0u;
    for (id key in httpResponse.allHeaderFields) {
        NSString *name = [key isKindOfClass:[NSString class]] ? (NSString *)key : [key description];
        NSString *value = [httpResponse.allHeaderFields[key] isKindOfClass:[NSString class]]
            ? (NSString *)httpResponse.allHeaderFields[key]
            : [[httpResponse.allHeaderFields[key] description] copy];
        responseHeaderBytes += EJSXHRHeaderBytes(name ?: @"", value ?: @"");
        if (responseHeaderBytes > (NSUInteger)_policy.maxHeaderBytes) {
            [self finishTaskStateWithError:state
                                      task:dataTask
                                     error:EJSXHRProviderError(EJSProviderErrorCodeSecurity, @"xhr response headers exceed policy limit")];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
    }
    state.httpResponse = httpResponse;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (data.length == 0u) {
        return;
    }
    EJSXHRTaskState *state = [self taskStateForTaskIdentifier:dataTask.taskIdentifier];
    if (state == nil || state.finished) {
        return;
    }
    NSUInteger currentLength = state.bodyData.length;
    NSUInteger maxBodyBytes = (NSUInteger)_policy.maxBodyBytes;
    BOOL overflow = data.length > NSUIntegerMax - currentLength;
    NSUInteger nextLength = overflow ? NSUIntegerMax : currentLength + data.length;
    if (overflow || nextLength > maxBodyBytes) {
        [self finishTaskStateWithError:state
                                  task:dataTask
                                 error:EJSXHRProviderError(EJSProviderErrorCodeSecurity, @"xhr response body exceeds policy limit")];
        [dataTask cancel];
        return;
    }
    [state.bodyData appendData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    EJSXHRTaskState *state = [self taskStateForTaskIdentifier:task.taskIdentifier];
    if (state == nil || state.finished) {
        return;
    }
    if (error != nil) {
        [self finishTaskStateWithError:state task:task error:[self taskErrorAsProviderError:error]];
        return;
    }
    [self finishTaskStateWithSuccess:state task:task];
}
@end

static BOOL EJSXHRInstallBundledScriptsIntoContext(EJSContext *context,
                                                   const EJSXHRBundledScript *scripts,
                                                   size_t scriptCount,
                                                   NSError **error) {
    if (context == nil) {
        if (error != NULL) *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        return NO;
    }

    EJSXHRPolicy *policy = EJSXHRPolicyFromJSON([context configurationValueForKey:EJSXHRNetworkConfigurationKey], error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction,
                                         context,
                                         @[ @"XMLHttpRequest", @"EJSXHR", @"EJSXHRError" ],
                                         error)) {
        return NO;
    }
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, [[EJSXHRProvider alloc] initWithPolicy:policy], error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSXHRBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) {
                *error = EJSXHRRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"EJSXHR bundled script must be valid UTF-8");
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

BOOL EJSXHRInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSXHRInstallBundledScriptsIntoContext(context, ejs_xhr_scripts, ejs_xhr_scripts_count, error);
}
