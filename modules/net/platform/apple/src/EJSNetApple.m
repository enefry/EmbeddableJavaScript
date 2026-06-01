#import "EJSNetApple.h"

#import "EJSProvider.h"

#import "../../../../../platform/apple/src/EJSAppleInstallTransactionInternal.h"

#include "ejs_net_js_bundle.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <math.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

NSString * const EJSNetworkConfigurationKey = @"ejs.network";
NSErrorDomain const EJSNetGetAddrInfoErrorDomain = @"EJSNetGetAddrInfoErrorDomain";

static BOOL EJSNetAddressIsLinkLocal(NSData *bytes, int family);
static BOOL EJSNetAddressIsPrivate(NSData *bytes, int family);

static NSError *EJSNetRuntimeError(EJSRuntimeErrorCode code, NSString *message) {
    NSDictionary *userInfo = message.length > 0 ? @{ NSLocalizedDescriptionKey: message } : @{};
    return [NSError errorWithDomain:EJSRuntimeErrorDomain code:code userInfo:userInfo];
}

static NSError *EJSNetProviderError(EJSProviderErrorCode code, NSString *message) {
    return EJSProviderMakeError(code, message.length > 0 ? message : @"Network provider failed");
}

static NSError *EJSNetProviderErrorWithUnderlying(EJSProviderErrorCode code, NSString *message, NSError *underlyingError) {
    NSMutableDictionary<NSString *, id> *userInfo = [[NSMutableDictionary alloc] init];
    if (message.length > 0u) {
        userInfo[NSLocalizedDescriptionKey] = message;
    }
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:EJSProviderErrorDomain
                               code:code
                           userInfo:userInfo.count > 0u ? userInfo : nil];
}

static NSError *EJSNetGetAddrInfoNativeError(int code) {
    NSString *description = [NSString stringWithUTF8String:gai_strerror(code)] ?: @"getaddrinfo failed";
    return [NSError errorWithDomain:EJSNetGetAddrInfoErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static NSError *EJSNetPOSIXNativeError(int code) {
    NSString *description = [NSString stringWithUTF8String:strerror(code)] ?: @"POSIX operation failed";
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static NSError *EJSNetProviderGetAddrInfoError(EJSProviderErrorCode providerCode, NSString *message, int getaddrinfoCode) {
    return EJSNetProviderErrorWithUnderlying(providerCode,
                                             message,
                                             EJSNetGetAddrInfoNativeError(getaddrinfoCode));
}

static NSError *EJSNetProviderPOSIXError(EJSProviderErrorCode providerCode, NSString *message, int posixCode) {
    return EJSNetProviderErrorWithUnderlying(providerCode,
                                             message,
                                             EJSNetPOSIXNativeError(posixCode));
}

static BOOL EJSNetStringIsNonEmpty(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0u;
}

static BOOL EJSNetValueIsJSONBoolean(id value) {
    return value != nil && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL EJSNetValidateOptionalBoolean(NSDictionary *object, NSString *key, NSString *field, NSError **error) {
    id value = object[key];
    if (value == nil) {
        return YES;
    }
    if (!EJSNetValueIsJSONBoolean(value)) {
        if (error != NULL) {
            *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, [NSString stringWithFormat:@"%@ must be boolean", field]);
        }
        return NO;
    }
    return YES;
}

static NSData *EJSNetAddressBytesFromString(NSString *address, int *familyOut) {
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

@interface EJSNetCIDR : NSObject
@property (nonatomic, assign, readonly) int family;
@property (nonatomic, assign, readonly) NSInteger prefixLength;
@property (nonatomic, copy, readonly) NSData *bytes;
- (instancetype)initWithFamily:(int)family prefixLength:(NSInteger)prefixLength bytes:(NSData *)bytes;
- (BOOL)containsAddressBytes:(NSData *)bytes family:(int)family;
@end

@implementation EJSNetCIDR
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

@interface EJSNetAllowRule : NSObject
@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, copy, readonly) NSString *hostSuffix;
@property (nonatomic, strong, readonly) EJSNetCIDR *cidr;
@property (nonatomic, copy, readonly) NSSet<NSString *> *protocols;
@property (nonatomic, copy, readonly) NSSet<NSNumber *> *ports;
@property (nonatomic, assign, readonly) NSInteger portRangeStart;
@property (nonatomic, assign, readonly) NSInteger portRangeEnd;
- (instancetype)initWithHost:(NSString *)host
                  hostSuffix:(NSString *)hostSuffix
                        cidr:(EJSNetCIDR *)cidr
                   protocols:(NSSet<NSString *> *)protocols
                       ports:(NSSet<NSNumber *> *)ports
              portRangeStart:(NSInteger)portRangeStart
                portRangeEnd:(NSInteger)portRangeEnd;
- (BOOL)matchesHost:(NSString *)host;
- (BOOL)matchesAddress:(NSString *)address family:(int)family;
- (BOOL)matchesExactAddress:(NSString *)address family:(int)family;
- (BOOL)hasPortConstraint;
- (BOOL)allowsProtocol:(NSString *)protocol port:(NSInteger)port;
@end

@implementation EJSNetAllowRule
- (instancetype)initWithHost:(NSString *)host
                  hostSuffix:(NSString *)hostSuffix
                        cidr:(EJSNetCIDR *)cidr
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
        NSData *bytes = EJSNetAddressBytesFromString(lower, &family);
        return bytes != nil && [self.cidr containsAddressBytes:bytes family:family];
    }
    return NO;
}

- (BOOL)matchesAddress:(NSString *)address family:(int)family {
    if (self.cidr == nil) {
        return NO;
    }
    int parsedFamily = 0;
    NSData *bytes = EJSNetAddressBytesFromString(address, &parsedFamily);
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
        NSData *hostBytes = EJSNetAddressBytesFromString(self.host, &hostFamily);
        NSData *addressBytes = EJSNetAddressBytesFromString(lower, &addressFamily);
        if (hostBytes != nil && addressBytes != nil) {
            return hostFamily == family && addressFamily == family && [hostBytes isEqualToData:addressBytes];
        }
    }
    if (self.cidr != nil) {
        int parsedFamily = 0;
        NSData *bytes = EJSNetAddressBytesFromString(lower, &parsedFamily);
        return bytes != nil && parsedFamily == family && [self.cidr containsAddressBytes:bytes family:family];
    }
    return NO;
}

- (BOOL)hasPortConstraint {
    return self.ports.count > 0u || self.portRangeStart >= 0;
}

- (BOOL)allowsProtocol:(NSString *)protocol port:(NSInteger)port {
    if (self.protocols.count > 0u && ![self.protocols containsObject:protocol]) {
        return NO;
    }
    if (port < 0) {
        return YES;
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

@interface EJSNetPolicy : NSObject
@property (nonatomic, assign, readonly) BOOL configured;
@property (nonatomic, assign, readonly) BOOL dnsEnabled;
@property (nonatomic, assign, readonly) BOOL tcpConnectEnabled;
@property (nonatomic, assign, readonly) BOOL tcpListenEnabled;
@property (nonatomic, assign, readonly) BOOL udpEnabled;
@property (nonatomic, assign, readonly) BOOL outboundDefaultAllow;
@property (nonatomic, assign, readonly) BOOL inboundDefaultAllow;
@property (nonatomic, assign, readonly) BOOL denyPrivateNetworks;
@property (nonatomic, assign, readonly) BOOL denyLinkLocal;
@property (nonatomic, assign, readonly) NSInteger maxDatagramBytes;
@property (nonatomic, copy, readonly) NSArray<EJSNetAllowRule *> *outboundAllowRules;
@property (nonatomic, copy, readonly) NSArray<EJSNetAllowRule *> *inboundAllowRules;
+ (instancetype)disabledPolicy;
- (instancetype)initWithConfigured:(BOOL)configured
                        dnsEnabled:(BOOL)dnsEnabled
                 tcpConnectEnabled:(BOOL)tcpConnectEnabled
                  tcpListenEnabled:(BOOL)tcpListenEnabled
                        udpEnabled:(BOOL)udpEnabled
              outboundDefaultAllow:(BOOL)outboundDefaultAllow
               inboundDefaultAllow:(BOOL)inboundDefaultAllow
               denyPrivateNetworks:(BOOL)denyPrivateNetworks
                      denyLinkLocal:(BOOL)denyLinkLocal
                  maxDatagramBytes:(NSInteger)maxDatagramBytes
                  outboundAllowRules:(NSArray<EJSNetAllowRule *> *)outboundAllowRules
                   inboundAllowRules:(NSArray<EJSNetAllowRule *> *)inboundAllowRules;
- (BOOL)allowsLookupHost:(NSString *)host;
- (BOOL)allowsConnectHost:(NSString *)host port:(NSInteger)port;
- (BOOL)allowsUDPSendHost:(NSString *)host port:(NSInteger)port;
- (BOOL)allowsListenAddress:(NSString *)address family:(int)family port:(NSInteger)port protocol:(NSString *)protocol;
- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family;
- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family port:(NSInteger)port protocol:(NSString *)protocol;
@end

@implementation EJSNetPolicy
+ (instancetype)disabledPolicy {
    return [[EJSNetPolicy alloc] initWithConfigured:NO
                                        dnsEnabled:NO
                                 tcpConnectEnabled:NO
                                  tcpListenEnabled:NO
                                        udpEnabled:NO
                              outboundDefaultAllow:NO
                               inboundDefaultAllow:NO
                               denyPrivateNetworks:NO
                                      denyLinkLocal:YES
                                 maxDatagramBytes:65507
                                  outboundAllowRules:@[]
                                   inboundAllowRules:@[]];
}

- (instancetype)initWithConfigured:(BOOL)configured
                        dnsEnabled:(BOOL)dnsEnabled
                 tcpConnectEnabled:(BOOL)tcpConnectEnabled
                  tcpListenEnabled:(BOOL)tcpListenEnabled
                        udpEnabled:(BOOL)udpEnabled
              outboundDefaultAllow:(BOOL)outboundDefaultAllow
               inboundDefaultAllow:(BOOL)inboundDefaultAllow
               denyPrivateNetworks:(BOOL)denyPrivateNetworks
                      denyLinkLocal:(BOOL)denyLinkLocal
                  maxDatagramBytes:(NSInteger)maxDatagramBytes
                  outboundAllowRules:(NSArray<EJSNetAllowRule *> *)outboundAllowRules
                   inboundAllowRules:(NSArray<EJSNetAllowRule *> *)inboundAllowRules {
    self = [super init];
    if (self != nil) {
        _configured = configured;
        _dnsEnabled = dnsEnabled;
        _tcpConnectEnabled = tcpConnectEnabled;
        _tcpListenEnabled = tcpListenEnabled;
        _udpEnabled = udpEnabled;
        _outboundDefaultAllow = outboundDefaultAllow;
        _inboundDefaultAllow = inboundDefaultAllow;
        _denyPrivateNetworks = denyPrivateNetworks;
        _denyLinkLocal = denyLinkLocal;
        _maxDatagramBytes = maxDatagramBytes;
        _outboundAllowRules = [outboundAllowRules copy] ?: @[];
        _inboundAllowRules = [inboundAllowRules copy] ?: @[];
    }
    return self;
}

- (BOOL)allowsLookupHost:(NSString *)host {
    if (!self.configured || !self.dnsEnabled) {
        return NO;
    }
    for (EJSNetAllowRule *rule in self.outboundAllowRules) {
        if ([rule matchesHost:host]) {
            return YES;
        }
    }
    return self.outboundDefaultAllow;
}

- (BOOL)allowsConnectHost:(NSString *)host port:(NSInteger)port {
    if (!self.configured || !self.tcpConnectEnabled) {
        return NO;
    }
    for (EJSNetAllowRule *rule in self.outboundAllowRules) {
        if ([rule matchesHost:host] && [rule allowsProtocol:@"tcp" port:port]) {
            return YES;
        }
    }
    return self.outboundDefaultAllow;
}

- (BOOL)allowsUDPSendHost:(NSString *)host port:(NSInteger)port {
    if (!self.configured || !self.udpEnabled) {
        return NO;
    }
    for (EJSNetAllowRule *rule in self.outboundAllowRules) {
        if ([rule.protocols containsObject:@"udp"] &&
            [rule hasPortConstraint] &&
            [rule matchesHost:host] &&
            [rule allowsProtocol:@"udp" port:port]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)allowsListenAddress:(NSString *)address family:(int)family port:(NSInteger)port protocol:(NSString *)protocol {
    if (!self.configured) {
        return NO;
    }
    if ([protocol isEqualToString:@"tcp"]) {
        if (!self.tcpListenEnabled) {
            return NO;
        }
    } else if ([protocol isEqualToString:@"udp"]) {
        if (!self.udpEnabled) {
            return NO;
        }
    } else {
        return NO;
    }
    for (EJSNetAllowRule *rule in self.inboundAllowRules) {
        if ([rule matchesExactAddress:address family:family] && [rule allowsProtocol:protocol port:port]) {
            return YES;
        }
    }
    return self.inboundDefaultAllow;
}

- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family {
    return [self allowsResolvedAddress:address family:family port:0 protocol:@"dns"];
}

- (BOOL)allowsResolvedAddress:(NSString *)address family:(int)family port:(NSInteger)port protocol:(NSString *)protocol {
    int parsedFamily = 0;
    NSData *bytes = EJSNetAddressBytesFromString(address, &parsedFamily);
    if (bytes == nil || parsedFamily != family) {
        return NO;
    }
    if (self.denyLinkLocal && EJSNetAddressIsLinkLocal(bytes, family)) {
        return NO;
    }
    if (self.denyPrivateNetworks && EJSNetAddressIsPrivate(bytes, family)) {
        return NO;
    }
    BOOL isUDP = [protocol isEqualToString:@"udp"];
    if (self.outboundDefaultAllow && !isUDP) {
        return YES;
    }
    for (EJSNetAllowRule *rule in self.outboundAllowRules) {
        if (isUDP && (![rule.protocols containsObject:@"udp"] || ![rule hasPortConstraint])) {
            continue;
        }
        if (([rule matchesAddress:address family:family] || [rule matchesExactAddress:address family:family]) &&
            [rule allowsProtocol:protocol port:port]) {
            return YES;
        }
    }
    return NO;
}
@end

static void EJSNetWakeCancellationFD(int writeFD);

@interface EJSNetCancellation : NSObject
@property (atomic, assign, getter=isCancelled) BOOL cancelled;
@property (nonatomic, assign, readonly) int cancelReadFD;
@property (nonatomic, assign, readonly) int cancelWriteFD;
- (instancetype)initWithCancelReadFD:(int)cancelReadFD cancelWriteFD:(int)cancelWriteFD;
- (void)cancel;
@end

@implementation EJSNetCancellation
- (instancetype)initWithCancelReadFD:(int)cancelReadFD cancelWriteFD:(int)cancelWriteFD {
    self = [super init];
    if (self != nil) {
        _cancelReadFD = cancelReadFD;
        _cancelWriteFD = cancelWriteFD;
    }
    return self;
}

- (void)cancel {
    self.cancelled = YES;
    EJSNetWakeCancellationFD(self.cancelWriteFD);
}

- (void)dealloc {
    if (_cancelReadFD >= 0) {
        close(_cancelReadFD);
    }
    if (_cancelWriteFD >= 0) {
        close(_cancelWriteFD);
    }
}
@end

static struct timeval EJSNetTimeout(NSInteger timeoutMs);

static BOOL EJSNetWaitForWritableFD(int fd,
                                    NSInteger timeoutMs,
                                    EJSNetCancellation *cancellation,
                                    NSString *operationName,
                                    NSError **error) {
    if (cancellation.isCancelled) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, [NSString stringWithFormat:@"%@ cancelled", operationName]);
        return NO;
    }

    fd_set writeSet;
    fd_set readSet;
    FD_ZERO(&writeSet);
    FD_ZERO(&readSet);
    FD_SET(fd, &writeSet);

    int maxFD = fd;
    int operationCancelReadFD = cancellation != nil ? cancellation.cancelReadFD : -1;
    if (operationCancelReadFD >= 0) {
        FD_SET(operationCancelReadFD, &readSet);
        if (operationCancelReadFD > maxFD) {
            maxFD = operationCancelReadFD;
        }
    }

    struct timeval timeout = EJSNetTimeout(timeoutMs);
    int selected = select(maxFD + 1, &readSet, &writeSet, NULL, &timeout);
    if (selected == 0) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, [NSString stringWithFormat:@"%@ timed out", operationName]);
        return NO;
    }
    if (selected < 0) {
        int selectErrno = errno;
        if ((selectErrno == EBADF || selectErrno == EINVAL) && cancellation.isCancelled) {
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, [NSString stringWithFormat:@"%@ cancelled", operationName]);
            return NO;
        }
        if (error != NULL) {
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"%@ select failed: %s", operationName, strerror(selectErrno)],
                                              selectErrno);
        }
        return NO;
    }
    if (operationCancelReadFD >= 0 && FD_ISSET(operationCancelReadFD, &readSet)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, [NSString stringWithFormat:@"%@ cancelled", operationName]);
        return NO;
    }
    if (!FD_ISSET(fd, &writeSet)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, [NSString stringWithFormat:@"%@ timed out", operationName]);
        return NO;
    }
    return YES;
}

@interface EJSNetSocketState : NSObject
@property (nonatomic, copy, readonly) NSString *socketID;
@property (nonatomic, assign, readonly) int fd;
@property (nonatomic, assign, readonly) int cancelReadFD;
@property (nonatomic, assign, readonly) int cancelWriteFD;
@property (nonatomic, copy, readonly) NSDictionary *localAddress;
@property (nonatomic, copy, readonly) NSDictionary *remoteAddress;
@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, assign, getter=isClosed) BOOL closed;
@property (atomic, assign, getter=isClosing) BOOL closing;
- (instancetype)initWithSocketID:(NSString *)socketID
                              fd:(int)fd
                     cancelReadFD:(int)cancelReadFD
                    cancelWriteFD:(int)cancelWriteFD
                    localAddress:(NSDictionary *)localAddress
                   remoteAddress:(NSDictionary *)remoteAddress;
@end

@implementation EJSNetSocketState
- (instancetype)initWithSocketID:(NSString *)socketID
                              fd:(int)fd
                     cancelReadFD:(int)cancelReadFD
                    cancelWriteFD:(int)cancelWriteFD
                    localAddress:(NSDictionary *)localAddress
                   remoteAddress:(NSDictionary *)remoteAddress {
    self = [super init];
    if (self != nil) {
        _socketID = [socketID copy];
        _fd = fd;
        _cancelReadFD = cancelReadFD;
        _cancelWriteFD = cancelWriteFD;
        _localAddress = [localAddress copy] ?: @{};
        _remoteAddress = [remoteAddress copy] ?: @{};
        _lock = [[NSLock alloc] init];
        _closed = NO;
        _closing = NO;
    }
    return self;
}
@end

@interface EJSNetListenerState : NSObject
@property (nonatomic, copy, readonly) NSString *listenerID;
@property (nonatomic, assign, readonly) int fd;
@property (nonatomic, assign, readonly) int cancelReadFD;
@property (nonatomic, assign, readonly) int cancelWriteFD;
@property (nonatomic, copy, readonly) NSDictionary *localAddress;
@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, assign, getter=isClosed) BOOL closed;
- (instancetype)initWithListenerID:(NSString *)listenerID
                                fd:(int)fd
                      cancelReadFD:(int)cancelReadFD
                     cancelWriteFD:(int)cancelWriteFD
                      localAddress:(NSDictionary *)localAddress;
@end

@implementation EJSNetListenerState
- (instancetype)initWithListenerID:(NSString *)listenerID
                                fd:(int)fd
                      cancelReadFD:(int)cancelReadFD
                     cancelWriteFD:(int)cancelWriteFD
                      localAddress:(NSDictionary *)localAddress {
    self = [super init];
    if (self != nil) {
        _listenerID = [listenerID copy];
        _fd = fd;
        _cancelReadFD = cancelReadFD;
        _cancelWriteFD = cancelWriteFD;
        _localAddress = [localAddress copy] ?: @{};
        _lock = [[NSLock alloc] init];
        _closed = NO;
    }
    return self;
}
@end

@interface EJSNetProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
- (instancetype)initWithPolicy:(EJSNetPolicy *)policy;
- (NSData *)lookupWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)tcpConnectWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error;
- (NSData *)tcpListenWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSString *)storeSocketWithFD:(int)fd
                    cancelReadFD:(int)cancelReadFD
                   cancelWriteFD:(int)cancelWriteFD
                    localAddress:(NSDictionary *)localAddress
                   remoteAddress:(NSDictionary *)remoteAddress;
- (NSData *)tcpAcceptWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error;
- (NSData *)tcpReadWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error;
- (NSData *)tcpWriteWithRequest:(NSDictionary *)request transferBuffer:(NSData *)transferBuffer cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error;
- (NSData *)tcpShutdownWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)tcpCloseWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)tcpListenerCloseWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)udpBindWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSData *)udpSendWithRequest:(NSDictionary *)request transferBuffer:(NSData *)transferBuffer error:(NSError **)error;
- (NSData *)udpRecvWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error;
- (NSData *)udpCloseWithRequest:(NSDictionary *)request error:(NSError **)error;
@end

static BOOL EJSNetAddressIsLinkLocal(NSData *bytes, int family) {
    const unsigned char *value = bytes.bytes;
    if (family == 4 && bytes.length == 4u) {
        return value[0] == 169 && value[1] == 254;
    }
    if (family == 6 && bytes.length == 16u) {
        return value[0] == 0xfe && (value[1] & 0xc0) == 0x80;
    }
    return NO;
}

static BOOL EJSNetAddressIsPrivate(NSData *bytes, int family) {
    const unsigned char *value = bytes.bytes;
    if (family == 4 && bytes.length == 4u) {
        return value[0] == 10 ||
            value[0] == 127 ||
            (value[0] == 172 && value[1] >= 16 && value[1] <= 31) ||
            (value[0] == 192 && value[1] == 168) ||
            EJSNetAddressIsLinkLocal(bytes, family);
    }
    if (family == 6 && bytes.length == 16u) {
        BOOL loopback = YES;
        for (NSUInteger i = 0u; i < 15u; ++i) {
            if (value[i] != 0) {
                loopback = NO;
                break;
            }
        }
        return loopback && value[15] == 1 ? YES : ((value[0] & 0xfe) == 0xfc || EJSNetAddressIsLinkLocal(bytes, family));
    }
    return NO;
}

static NSDictionary *EJSNetJSONObjectFromData(NSData *data, NSError **error) {
    if (data.length == 0u) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"net payload is required");
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"net payload must be a JSON object");
        }
        return nil;
    }
    return (NSDictionary *)value;
}

static NSData *EJSNetJSONData(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (data == nil && error != NULL && *error == nil) {
        *error = EJSNetProviderError(EJSProviderErrorCodeInternal, @"Failed to encode net JSON response");
    }
    return data;
}

static NSDictionary *EJSNetEndpointFromSockaddr(const struct sockaddr *addr, socklen_t length) {
    (void)length;
    char addressBuffer[INET6_ADDRSTRLEN] = { 0 };
    int port = 0;
    int family = 0;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *in4 = (const struct sockaddr_in *)addr;
        inet_ntop(AF_INET, &in4->sin_addr, addressBuffer, sizeof(addressBuffer));
        port = ntohs(in4->sin_port);
        family = 4;
    } else if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        inet_ntop(AF_INET6, &in6->sin6_addr, addressBuffer, sizeof(addressBuffer));
        port = ntohs(in6->sin6_port);
        family = 6;
    }
    return @{
        @"address": [NSString stringWithUTF8String:addressBuffer] ?: @"",
        @"port": @(port),
        @"family": @(family)
    };
}

static int EJSNetSetNonBlocking(int fd, BOOL enabled) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return -1;
    }
    if (enabled) {
        flags |= O_NONBLOCK;
    } else {
        flags &= ~O_NONBLOCK;
    }
    return fcntl(fd, F_SETFL, flags);
}

static struct timeval EJSNetTimeout(NSInteger timeoutMs) {
    struct timeval timeout;
    timeout.tv_sec = (time_t)(timeoutMs / 1000);
    timeout.tv_usec = (suseconds_t)((timeoutMs % 1000) * 1000);
    return timeout;
}

static BOOL EJSNetCreateCancellationPipe(int *readFDOut, int *writeFDOut, NSError **error) {
    int cancelFDs[2] = { -1, -1 };
    if (pipe(cancelFDs) != 0 ||
        EJSNetSetNonBlocking(cancelFDs[0], YES) != 0 ||
        EJSNetSetNonBlocking(cancelFDs[1], YES) != 0) {
        if (error != NULL) {
            int pipeErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"cancellation pipe failed: %s", strerror(pipeErrno)],
                                              pipeErrno);
        }
        if (cancelFDs[0] >= 0) close(cancelFDs[0]);
        if (cancelFDs[1] >= 0) close(cancelFDs[1]);
        return NO;
    }
    *readFDOut = cancelFDs[0];
    *writeFDOut = cancelFDs[1];
    return YES;
}

static void EJSNetWakeCancellationFD(int writeFD) {
    if (writeFD < 0) {
        return;
    }
    unsigned char cancelByte = 1;
    (void)write(writeFD, &cancelByte, sizeof(cancelByte));
}

static BOOL EJSNetErrnoIndicatesLocalClose(int value) {
    return value == EBADF ||
        value == EINVAL ||
        value == ENOTSOCK ||
        value == ENOTCONN ||
        value == EPIPE;
}

static BOOL EJSNetBindLocalAddress(int fd, NSString *localAddress, int family, NSError **error) {
    if (localAddress.length == 0u) {
        return YES;
    }
    if (family == 4) {
        struct sockaddr_in local;
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_port = 0;
        if (inet_pton(AF_INET, localAddress.UTF8String, &local.sin_addr) != 1) {
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpConnect localAddress is invalid for IPv4");
            return NO;
        }
        if (bind(fd, (const struct sockaddr *)&local, sizeof(local)) != 0) {
            if (error != NULL) {
                int bindErrno = errno;
                *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                  [NSString stringWithFormat:@"bind localAddress failed: %s", strerror(bindErrno)],
                                                  bindErrno);
            }
            return NO;
        }
        return YES;
    }
    if (family == 6) {
        struct sockaddr_in6 local;
        memset(&local, 0, sizeof(local));
        local.sin6_family = AF_INET6;
        local.sin6_port = 0;
        if (inet_pton(AF_INET6, localAddress.UTF8String, &local.sin6_addr) != 1) {
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpConnect localAddress is invalid for IPv6");
            return NO;
        }
        if (bind(fd, (const struct sockaddr *)&local, sizeof(local)) != 0) {
            if (error != NULL) {
                int bindErrno = errno;
                *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                  [NSString stringWithFormat:@"bind localAddress failed: %s", strerror(bindErrno)],
                                                  bindErrno);
            }
            return NO;
        }
        return YES;
    }
    if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpConnect localAddress requires IPv4 or IPv6");
    return NO;
}

static BOOL EJSNetBuildListenSockaddr(NSString *host,
                                      NSInteger family,
                                      NSInteger port,
                                      struct sockaddr_storage *storageOut,
                                      socklen_t *lengthOut,
                                      int *socketFamilyOut,
                                      NSError **error) {
    if (family == 0 || family == 4) {
        struct sockaddr_in addr4;
        memset(&addr4, 0, sizeof(addr4));
        addr4.sin_family = AF_INET;
        addr4.sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, host.UTF8String, &addr4.sin_addr) == 1) {
            memcpy(storageOut, &addr4, sizeof(addr4));
            *lengthOut = sizeof(addr4);
            *socketFamilyOut = AF_INET;
            return YES;
        }
    }
    if (family == 0 || family == 6) {
        struct sockaddr_in6 addr6;
        memset(&addr6, 0, sizeof(addr6));
        addr6.sin6_family = AF_INET6;
        addr6.sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, host.UTF8String, &addr6.sin6_addr) == 1) {
            memcpy(storageOut, &addr6, sizeof(addr6));
            *lengthOut = sizeof(addr6);
            *socketFamilyOut = AF_INET6;
            return YES;
        }
    }
    if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpListen host must match family");
    return NO;
}

static BOOL EJSNetBuildUDPSockaddr(NSString *host,
                                   NSInteger family,
                                   NSInteger port,
                                   struct sockaddr_storage *storageOut,
                                   socklen_t *lengthOut,
                                   int *socketFamilyOut,
                                   NSError **error) {
    if (family == 0 || family == 4) {
        struct sockaddr_in addr4;
        memset(&addr4, 0, sizeof(addr4));
        addr4.sin_family = AF_INET;
        addr4.sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, host.UTF8String, &addr4.sin_addr) == 1) {
            memcpy(storageOut, &addr4, sizeof(addr4));
            *lengthOut = sizeof(addr4);
            *socketFamilyOut = AF_INET;
            return YES;
        }
    }
    if (family == 0 || family == 6) {
        struct sockaddr_in6 addr6;
        memset(&addr6, 0, sizeof(addr6));
        addr6.sin6_family = AF_INET6;
        addr6.sin6_port = htons((uint16_t)port);
        if (inet_pton(AF_INET6, host.UTF8String, &addr6.sin6_addr) == 1) {
            memcpy(storageOut, &addr6, sizeof(addr6));
            *lengthOut = sizeof(addr6);
            *socketFamilyOut = AF_INET6;
            return YES;
        }
    }
    if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpBind host must match family");
    return NO;
}

static BOOL EJSNetNumberIsIntegerInRange(id value, NSInteger min, NSInteger max) {
    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }
    double doubleValue = [(NSNumber *)value doubleValue];
    NSInteger integerValue = [(NSNumber *)value integerValue];
    return floor(doubleValue) == doubleValue && integerValue >= min && integerValue <= max;
}

static EJSNetCIDR *EJSNetCIDRFromString(NSString *value, NSError **error) {
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"/"];
    if (parts.count != 2u || parts[0].length == 0u || parts[1].length == 0u) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr must be address/prefix");
        return nil;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([parts[1] rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr prefix must be an integer");
        return nil;
    }
    int family = 0;
    NSData *bytes = EJSNetAddressBytesFromString(parts[0], &family);
    NSInteger prefix = parts[1].integerValue;
    NSInteger maxPrefix = family == 4 ? 32 : family == 6 ? 128 : -1;
    if (bytes == nil || prefix < 0 || prefix > maxPrefix) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network cidr is invalid");
        return nil;
    }
    return [[EJSNetCIDR alloc] initWithFamily:family prefixLength:prefix bytes:bytes];
}

static BOOL EJSNetValidateStringArray(id value, NSString *field, NSError **error) {
    if (value == nil) {
        return YES;
    }
    if (![value isKindOfClass:[NSArray class]]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, [NSString stringWithFormat:@"%@ must be an array", field]);
        return NO;
    }
    for (id item in (NSArray *)value) {
        if (!EJSNetStringIsNonEmpty(item)) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, [NSString stringWithFormat:@"%@ entries must be strings", field]);
            return NO;
        }
    }
    return YES;
}

static BOOL EJSNetValidatePortFields(NSDictionary *rule, NSError **error) {
    id ports = rule[@"ports"];
    if (ports != nil) {
        if (![ports isKindOfClass:[NSArray class]]) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule ports must be an array");
            return NO;
        }
        for (id port in (NSArray *)ports) {
            if (!EJSNetNumberIsIntegerInRange(port, 1, 65535)) {
                if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule ports must be 1-65535");
                return NO;
            }
        }
    }
    id portRange = rule[@"portRange"];
    if (portRange != nil) {
        if (![portRange isKindOfClass:[NSArray class]] || [(NSArray *)portRange count] != 2u ||
            !EJSNetNumberIsIntegerInRange(((NSArray *)portRange)[0], 0, 65535) ||
            !EJSNetNumberIsIntegerInRange(((NSArray *)portRange)[1], 0, 65535) ||
            [((NSArray *)portRange)[0] integerValue] > [((NSArray *)portRange)[1] integerValue]) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule portRange must be [min,max]");
            return NO;
        }
    }
    return YES;
}

static EJSNetPolicy *EJSNetPolicyFromJSON(NSString *json, NSError **error) {
    if (json.length == 0u) {
        return [EJSNetPolicy disabledPolicy];
    }

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id value = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network configuration must be a JSON object");
        }
        return nil;
    }

    NSDictionary *object = (NSDictionary *)value;
    if (!EJSNetNumberIsIntegerInRange(object[@"version"], 1, 1)) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network requires version 1");
        return nil;
    }
    NSDictionary *capabilities = [object[@"capabilities"] isKindOfClass:[NSDictionary class]] ? object[@"capabilities"] : nil;
    NSDictionary *outbound = [object[@"outbound"] isKindOfClass:[NSDictionary class]] ? object[@"outbound"] : nil;
    if (capabilities == nil || outbound == nil) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network requires capabilities and outbound");
        return nil;
    }
    if (object[@"limits"] != nil && ![object[@"limits"] isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network limits must be an object");
        return nil;
    }
    NSDictionary *limits = [object[@"limits"] isKindOfClass:[NSDictionary class]] ? object[@"limits"] : nil;
    NSInteger maxDatagramBytes = 65507;
    if (limits[@"maxDatagramBytes"] != nil) {
        if (!EJSNetNumberIsIntegerInRange(limits[@"maxDatagramBytes"], 1, 65507)) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network limits.maxDatagramBytes must be 1..65507");
            return nil;
        }
        maxDatagramBytes = [limits[@"maxDatagramBytes"] integerValue];
    }

    if (!EJSNetValidateOptionalBoolean(capabilities, @"dns", @"ejs.network capabilities.dns", error) ||
        !EJSNetValidateOptionalBoolean(capabilities, @"tcpConnect", @"ejs.network capabilities.tcpConnect", error) ||
        !EJSNetValidateOptionalBoolean(capabilities, @"tcpListen", @"ejs.network capabilities.tcpListen", error) ||
        !EJSNetValidateOptionalBoolean(capabilities, @"udp", @"ejs.network capabilities.udp", error) ||
        !EJSNetValidateOptionalBoolean(outbound, @"denyPrivateNetworks", @"ejs.network outbound.denyPrivateNetworks", error) ||
        !EJSNetValidateOptionalBoolean(outbound, @"denyLinkLocal", @"ejs.network outbound.denyLinkLocal", error)) {
        return nil;
    }
    id dns = capabilities[@"dns"];
    id tcpConnect = capabilities[@"tcpConnect"];
    id tcpListen = capabilities[@"tcpListen"];
    id udp = capabilities[@"udp"];

    NSString *defaultRule = [outbound[@"default"] isKindOfClass:[NSString class]] ? outbound[@"default"] : @"deny";
    BOOL defaultAllow = [defaultRule isEqualToString:@"allow"];
    if (!defaultAllow && ![defaultRule isEqualToString:@"deny"]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network outbound.default must be allow or deny");
        return nil;
    }

    NSArray *allowObjects = [outbound[@"allow"] isKindOfClass:[NSArray class]] ? outbound[@"allow"] : @[];
    if (outbound[@"allow"] != nil && ![outbound[@"allow"] isKindOfClass:[NSArray class]]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network outbound.allow must be an array");
        return nil;
    }

    NSMutableArray<EJSNetAllowRule *> *outboundRules = [[NSMutableArray alloc] init];
    for (id item in allowObjects) {
        NSDictionary *rule = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        if (rule == nil) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network allow rules must be objects");
            return nil;
        }
        NSString *host = EJSNetStringIsNonEmpty(rule[@"host"]) ? rule[@"host"] : @"";
        NSString *hostSuffix = EJSNetStringIsNonEmpty(rule[@"hostSuffix"]) ? rule[@"hostSuffix"] : @"";
        EJSNetCIDR *cidr = nil;
        if (rule[@"cidr"] != nil) {
            if (!EJSNetStringIsNonEmpty(rule[@"cidr"])) {
                if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule cidr must be a string");
                return nil;
            }
            cidr = EJSNetCIDRFromString(rule[@"cidr"], error);
            if (cidr == nil) {
                return nil;
            }
        }
        if (host.length == 0u && hostSuffix.length == 0u && cidr == nil) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network allow rule requires host, hostSuffix, or cidr");
            return nil;
        }
        if (!EJSNetValidateStringArray(rule[@"protocols"], @"network rule protocols", error) ||
            !EJSNetValidatePortFields(rule, error)) {
            return nil;
        }
        NSMutableSet<NSString *> *protocols = [[NSMutableSet alloc] init];
        for (NSString *protocol in ([rule[@"protocols"] isKindOfClass:[NSArray class]] ? rule[@"protocols"] : @[])) {
            NSString *lower = protocol.lowercaseString;
            if (![lower isEqualToString:@"dns"] &&
                ![lower isEqualToString:@"tcp"] &&
                ![lower isEqualToString:@"udp"] &&
                ![lower isEqualToString:@"xhr"] &&
                ![lower isEqualToString:@"ws"]) {
                if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network rule protocol is unsupported");
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
        [outboundRules addObject:[[EJSNetAllowRule alloc] initWithHost:host
                                                            hostSuffix:hostSuffix
                                                                  cidr:cidr
                                                             protocols:protocols
                                                                 ports:ports
                                                        portRangeStart:portRangeStart
                                                          portRangeEnd:portRangeEnd]];
    }

    if (object[@"inbound"] != nil && ![object[@"inbound"] isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network inbound must be an object");
        return nil;
    }
    NSDictionary *inbound = [object[@"inbound"] isKindOfClass:[NSDictionary class]] ? object[@"inbound"] : nil;
    NSString *inboundDefaultRule = [inbound[@"default"] isKindOfClass:[NSString class]] ? inbound[@"default"] : @"deny";
    BOOL inboundDefaultAllow = [inboundDefaultRule isEqualToString:@"allow"];
    if (!inboundDefaultAllow && ![inboundDefaultRule isEqualToString:@"deny"]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network inbound.default must be allow or deny");
        return nil;
    }
    NSArray *inboundAllowObjects = [inbound[@"allow"] isKindOfClass:[NSArray class]] ? inbound[@"allow"] : @[];
    if (inbound != nil && inbound[@"allow"] != nil && ![inbound[@"allow"] isKindOfClass:[NSArray class]]) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"ejs.network inbound.allow must be an array");
        return nil;
    }

    NSMutableArray<EJSNetAllowRule *> *inboundRules = [[NSMutableArray alloc] init];
    for (id item in inboundAllowObjects) {
        NSDictionary *rule = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        if (rule == nil) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network inbound rules must be objects");
            return nil;
        }
        NSString *address = EJSNetStringIsNonEmpty(rule[@"address"]) ? rule[@"address"] : @"";
        EJSNetCIDR *cidr = nil;
        if (rule[@"cidr"] != nil) {
            if (!EJSNetStringIsNonEmpty(rule[@"cidr"])) {
                if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network inbound rule cidr must be a string");
                return nil;
            }
            cidr = EJSNetCIDRFromString(rule[@"cidr"], error);
            if (cidr == nil) {
                return nil;
            }
        }
        if (address.length == 0u && cidr == nil) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network inbound rule requires address or cidr");
            return nil;
        }
        if (!EJSNetValidateStringArray(rule[@"protocols"], @"network inbound rule protocols", error) ||
            !EJSNetValidatePortFields(rule, error)) {
            return nil;
        }
        NSMutableSet<NSString *> *protocols = [[NSMutableSet alloc] init];
        for (NSString *protocol in ([rule[@"protocols"] isKindOfClass:[NSArray class]] ? rule[@"protocols"] : @[])) {
            NSString *lower = protocol.lowercaseString;
            if (![lower isEqualToString:@"tcp"] &&
                ![lower isEqualToString:@"udp"]) {
                if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"network inbound protocol is unsupported");
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
        [inboundRules addObject:[[EJSNetAllowRule alloc] initWithHost:address
                                                           hostSuffix:@""
                                                                 cidr:cidr
                                                            protocols:protocols
                                                                ports:ports
                                                       portRangeStart:portRangeStart
                                                         portRangeEnd:portRangeEnd]];
    }

    return [[EJSNetPolicy alloc] initWithConfigured:YES
                                        dnsEnabled:[dns boolValue]
                                 tcpConnectEnabled:[tcpConnect boolValue]
                                  tcpListenEnabled:[tcpListen boolValue]
                                        udpEnabled:[udp boolValue]
                              outboundDefaultAllow:defaultAllow
                               inboundDefaultAllow:inboundDefaultAllow
                               denyPrivateNetworks:[outbound[@"denyPrivateNetworks"] boolValue]
                                      denyLinkLocal:outbound[@"denyLinkLocal"] == nil ? YES : [outbound[@"denyLinkLocal"] boolValue]
                                  maxDatagramBytes:maxDatagramBytes
                                  outboundAllowRules:outboundRules
                                   inboundAllowRules:inboundRules];
}

@implementation EJSNetProvider {
    EJSNetPolicy *_policy;
    dispatch_queue_t _queue;
    NSLock *_socketsLock;
    NSMutableDictionary<NSString *, EJSNetSocketState *> *_sockets;
    NSLock *_listenersLock;
    NSMutableDictionary<NSString *, EJSNetListenerState *> *_listeners;
    unsigned long long _nextSocketID;
    unsigned long long _nextListenerID;
}

- (instancetype)initWithPolicy:(EJSNetPolicy *)policy {
    self = [super init];
    if (self != nil) {
        _moduleID = @"ejs.net";
        _policy = policy;
        _queue = dispatch_queue_create("dev.ejs.net.provider", DISPATCH_QUEUE_CONCURRENT);
        _socketsLock = [[NSLock alloc] init];
        _sockets = [[NSMutableDictionary alloc] init];
        _listenersLock = [[NSLock alloc] init];
        _listeners = [[NSMutableDictionary alloc] init];
        _nextSocketID = 1u;
        _nextListenerID = 1u;
    }
    return self;
}

- (void)dealloc {
    [_socketsLock lock];
    NSArray<EJSNetSocketState *> *states = _sockets.allValues;
    [_sockets removeAllObjects];
    [_socketsLock unlock];
    for (EJSNetSocketState *state in states) {
        if (state.cancelWriteFD >= 0) {
            unsigned char cancelByte = 1;
            (void)write(state.cancelWriteFD, &cancelByte, sizeof(cancelByte));
        }
        shutdown(state.fd, SHUT_RDWR);
        [state.lock lock];
        if (!state.isClosed) {
            state.closed = YES;
            close(state.fd);
            if (state.cancelReadFD >= 0) {
                close(state.cancelReadFD);
            }
            if (state.cancelWriteFD >= 0) {
                close(state.cancelWriteFD);
            }
        }
        [state.lock unlock];
    }

    [_listenersLock lock];
    NSArray<EJSNetListenerState *> *listenerStates = _listeners.allValues;
    [_listeners removeAllObjects];
    [_listenersLock unlock];
    for (EJSNetListenerState *state in listenerStates) {
        if (state.cancelWriteFD >= 0) {
            unsigned char cancelByte = 1;
            (void)write(state.cancelWriteFD, &cancelByte, sizeof(cancelByte));
        }
        shutdown(state.fd, SHUT_RDWR);
        [state.lock lock];
        if (!state.isClosed) {
            state.closed = YES;
            close(state.fd);
            if (state.cancelReadFD >= 0) {
                close(state.cancelReadFD);
            }
            if (state.cancelWriteFD >= 0) {
                close(state.cancelWriteFD);
            }
        }
        [state.lock unlock];
    }
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                               context:(EJSContext *)context
                              responder:(EJSProviderResponder *)responder {
    (void)context;

    if (![methodID isEqualToString:@"lookup"] &&
        ![methodID isEqualToString:@"tcpConnect"] &&
        ![methodID isEqualToString:@"tcpListen"] &&
        ![methodID isEqualToString:@"tcpAccept"] &&
        ![methodID isEqualToString:@"tcpRead"] &&
        ![methodID isEqualToString:@"tcpWrite"] &&
        ![methodID isEqualToString:@"tcpShutdown"] &&
        ![methodID isEqualToString:@"tcpClose"] &&
        ![methodID isEqualToString:@"tcpListenerClose"] &&
        ![methodID isEqualToString:@"udpBind"] &&
        ![methodID isEqualToString:@"udpSend"] &&
        ![methodID isEqualToString:@"udpRecv"] &&
        ![methodID isEqualToString:@"udpClose"]) {
        [responder finishWithData:nil error:EJSNetProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.net method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSError *parseError = nil;
    NSDictionary *request = EJSNetJSONObjectFromData(payload, &parseError);
    if (request == nil) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }

    int operationCancelReadFD = -1;
    int operationCancelWriteFD = -1;
    if (!EJSNetCreateCancellationPipe(&operationCancelReadFD, &operationCancelWriteFD, &parseError)) {
        [responder finishWithData:nil error:parseError];
        return [[EJSImmediateOperation alloc] init];
    }
    EJSNetCancellation *cancellation = [[EJSNetCancellation alloc] initWithCancelReadFD:operationCancelReadFD
                                                                        cancelWriteFD:operationCancelWriteFD];
    NSData *requestTransfer = [transferBuffer copy];
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (cancellation.isCancelled) {
                return;
            }
            NSError *operationError = nil;
            NSData *result = [self resultForMethod:methodID request:request transferBuffer:requestTransfer cancellation:cancellation error:&operationError];
            if (cancellation.isCancelled) {
                return;
            }
            [responder finishWithData:result error:operationError];
        }
    });

    return [[EJSBlockOperation alloc] initWithCancelBlock:^{
        [cancellation cancel];
    }];
}

- (NSData *)resultForMethod:(NSString *)methodID
                    request:(NSDictionary *)request
             transferBuffer:(NSData *)transferBuffer
                cancellation:(EJSNetCancellation *)cancellation
                      error:(NSError **)error {
    if ([methodID isEqualToString:@"lookup"]) {
        return [self lookupWithRequest:request error:error];
    }
    if ([methodID isEqualToString:@"tcpConnect"]) {
        return [self tcpConnectWithRequest:request cancellation:cancellation error:error];
    }
    if ([methodID isEqualToString:@"tcpListen"]) {
        return [self tcpListenWithRequest:request error:error];
    }
    if ([methodID isEqualToString:@"tcpAccept"]) {
        return [self tcpAcceptWithRequest:request cancellation:cancellation error:error];
    }
    if ([methodID isEqualToString:@"tcpRead"]) {
        return [self tcpReadWithRequest:request cancellation:cancellation error:error];
    }
    if ([methodID isEqualToString:@"tcpWrite"]) {
        return [self tcpWriteWithRequest:request transferBuffer:transferBuffer cancellation:cancellation error:error];
    }
    if ([methodID isEqualToString:@"tcpShutdown"]) {
        return [self tcpShutdownWithRequest:request error:error];
    }
    if ([methodID isEqualToString:@"tcpClose"]) {
        return [self tcpCloseWithRequest:request error:error];
    }
    if ([methodID isEqualToString:@"tcpListenerClose"]) {
        return [self tcpListenerCloseWithRequest:request error:error];
    }
    if ([methodID isEqualToString:@"udpBind"]) {
        return [self udpBindWithRequest:request error:error];
    }
    if ([methodID isEqualToString:@"udpSend"]) {
        return [self udpSendWithRequest:request transferBuffer:transferBuffer error:error];
    }
    if ([methodID isEqualToString:@"udpRecv"]) {
        return [self udpRecvWithRequest:request cancellation:cancellation error:error];
    }
    if ([methodID isEqualToString:@"udpClose"]) {
        return [self udpCloseWithRequest:request error:error];
    }
    if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeUnsupported, @"Unsupported ejs.net method");
    return nil;
}

- (NSData *)lookupWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *host = EJSNetStringIsNonEmpty(request[@"host"]) ? request[@"host"] : nil;
    NSNumber *familyNumber = [request[@"family"] isKindOfClass:[NSNumber class]] ? request[@"family"] : @0;
    NSInteger family = familyNumber.integerValue;
    if (host.length == 0u || (family != 0 && family != 4 && family != 6)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"lookup requires host and family 0, 4, or 6");
        return nil;
    }
    if (![_policy allowsLookupHost:host]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, [NSString stringWithFormat:@"lookup %@ denied by ejs.network policy", host]);
        return nil;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = family == 4 ? AF_INET : family == 6 ? AF_INET6 : AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_CANONNAME;

    struct addrinfo *result = NULL;
    int rc = getaddrinfo(host.UTF8String, NULL, &hints, &result);
    if (rc != 0) {
        if (error != NULL) {
            *error = EJSNetProviderGetAddrInfoError(EJSProviderErrorCodeNetwork,
                                                    [NSString stringWithFormat:@"lookup %@ failed: %s", host, gai_strerror(rc)],
                                                    rc);
        }
        return nil;
    }

    NSMutableArray *addresses = [[NSMutableArray alloc] init];
    NSMutableSet<NSString *> *seen = [[NSMutableSet alloc] init];
    for (struct addrinfo *cursor = result; cursor != NULL; cursor = cursor->ai_next) {
        int cursorFamily = cursor->ai_family == AF_INET ? 4 : cursor->ai_family == AF_INET6 ? 6 : 0;
        if (cursorFamily == 0) {
            continue;
        }

        char addressBuffer[INET6_ADDRSTRLEN] = { 0 };
        void *source = cursor->ai_family == AF_INET
            ? (void *)&((struct sockaddr_in *)cursor->ai_addr)->sin_addr
            : (void *)&((struct sockaddr_in6 *)cursor->ai_addr)->sin6_addr;
        if (inet_ntop(cursor->ai_family, source, addressBuffer, sizeof(addressBuffer)) == NULL) {
            continue;
        }

        NSString *address = [NSString stringWithUTF8String:addressBuffer] ?: @"";
        NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)cursorFamily, address];
        if (address.length == 0u || [seen containsObject:key] || ![_policy allowsResolvedAddress:address family:cursorFamily]) {
            continue;
        }
        [seen addObject:key];
        NSString *canonicalName = cursor->ai_canonname != NULL ? [NSString stringWithUTF8String:cursor->ai_canonname] ?: @"" : @"";
        [addresses addObject:@{
            @"address": address,
            @"family": @(cursorFamily),
            @"canonicalName": canonicalName
        }];
    }
    freeaddrinfo(result);

    if (addresses.count == 0u) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, [NSString stringWithFormat:@"lookup %@ resolved no policy-allowed addresses", host]);
        return nil;
    }
    return EJSNetJSONData(@{ @"addresses": addresses }, error);
}

- (NSString *)storeSocketWithFD:(int)fd
                    cancelReadFD:(int)cancelReadFD
                   cancelWriteFD:(int)cancelWriteFD
                     localAddress:(NSDictionary *)localAddress
                    remoteAddress:(NSDictionary *)remoteAddress {
    [_socketsLock lock];
    NSString *socketID = [NSString stringWithFormat:@"%llu", _nextSocketID++];
    _sockets[socketID] = [[EJSNetSocketState alloc] initWithSocketID:socketID
                                                                  fd:fd
                                                         cancelReadFD:cancelReadFD
                                                        cancelWriteFD:cancelWriteFD
                                                        localAddress:localAddress
                                                       remoteAddress:remoteAddress];
    [_socketsLock unlock];
    return socketID;
}

- (EJSNetSocketState *)socketForID:(NSString *)socketID error:(NSError **)error {
    if (!EJSNetStringIsNonEmpty(socketID)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcp socketID is required");
        return nil;
    }
    [_socketsLock lock];
    EJSNetSocketState *state = _sockets[socketID];
    [_socketsLock unlock];
    if (state == nil && error != NULL) {
        *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed");
    }
    return state;
}

- (EJSNetSocketState *)removeSocketForID:(NSString *)socketID {
    [_socketsLock lock];
    EJSNetSocketState *state = _sockets[socketID];
    if (state != nil) {
        [_sockets removeObjectForKey:socketID];
    }
    [_socketsLock unlock];
    return state;
}

- (void)closeSocketState:(EJSNetSocketState *)state {
    if (state == nil) {
        return;
    }
    state.closing = YES;
    unsigned char cancelByte = 1;
    if (state.cancelWriteFD >= 0) {
        (void)write(state.cancelWriteFD, &cancelByte, sizeof(cancelByte));
    }
    shutdown(state.fd, SHUT_RDWR);
    [state.lock lock];
    if (!state.isClosed) {
        state.closed = YES;
        close(state.fd);
        if (state.cancelReadFD >= 0) {
            close(state.cancelReadFD);
        }
        if (state.cancelWriteFD >= 0) {
            close(state.cancelWriteFD);
        }
    }
    [state.lock unlock];
}

- (NSString *)storeListenerWithFD:(int)fd
                      cancelReadFD:(int)cancelReadFD
                     cancelWriteFD:(int)cancelWriteFD
                      localAddress:(NSDictionary *)localAddress {
    [_listenersLock lock];
    NSString *listenerID = [NSString stringWithFormat:@"%llu", _nextListenerID++];
    _listeners[listenerID] = [[EJSNetListenerState alloc] initWithListenerID:listenerID
                                                                          fd:fd
                                                                cancelReadFD:cancelReadFD
                                                               cancelWriteFD:cancelWriteFD
                                                                localAddress:localAddress];
    [_listenersLock unlock];
    return listenerID;
}

- (EJSNetListenerState *)listenerForID:(NSString *)listenerID error:(NSError **)error {
    if (!EJSNetStringIsNonEmpty(listenerID)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcp listenerID is required");
        return nil;
    }
    [_listenersLock lock];
    EJSNetListenerState *state = _listeners[listenerID];
    [_listenersLock unlock];
    if (state == nil && error != NULL) {
        *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp listener is closed");
    }
    return state;
}

- (EJSNetListenerState *)removeListenerForID:(NSString *)listenerID {
    [_listenersLock lock];
    EJSNetListenerState *state = _listeners[listenerID];
    if (state != nil) {
        [_listeners removeObjectForKey:listenerID];
    }
    [_listenersLock unlock];
    return state;
}

- (void)closeListenerState:(EJSNetListenerState *)state {
    if (state == nil) {
        return;
    }
    unsigned char cancelByte = 1;
    if (state.cancelWriteFD >= 0) {
        (void)write(state.cancelWriteFD, &cancelByte, sizeof(cancelByte));
    }
    [state.lock lock];
    if (!state.isClosed) {
        state.closed = YES;
        shutdown(state.fd, SHUT_RDWR);
        close(state.fd);
        close(state.cancelReadFD);
        close(state.cancelWriteFD);
    }
    [state.lock unlock];
}

- (NSData *)tcpConnectWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error {
    NSString *host = EJSNetStringIsNonEmpty(request[@"host"]) ? request[@"host"] : nil;
    NSString *localAddressString = EJSNetStringIsNonEmpty(request[@"localAddress"]) ? request[@"localAddress"] : nil;
    NSInteger port = [request[@"port"] isKindOfClass:[NSNumber class]] ? [request[@"port"] integerValue] : 0;
    NSInteger family = [request[@"family"] isKindOfClass:[NSNumber class]] ? [request[@"family"] integerValue] : 0;
    NSInteger timeoutMs = [request[@"timeoutMs"] isKindOfClass:[NSNumber class]] && [request[@"timeoutMs"] integerValue] > 0
        ? [request[@"timeoutMs"] integerValue]
        : 15000;
    if (host.length == 0u || port < 1 || port > 65535 || (family != 0 && family != 4 && family != 6)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpConnect requires host, port, and family 0, 4, or 6");
        return nil;
    }
    if (cancellation.isCancelled) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpConnect cancelled");
        return nil;
    }
    if (![_policy allowsConnectHost:host port:port]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, [NSString stringWithFormat:@"connect %@:%ld denied by ejs.network policy", host, (long)port]);
        return nil;
    }

    int localFamily = 0;
    if (localAddressString.length > 0u) {
        NSData *localBytes = EJSNetAddressBytesFromString(localAddressString, &localFamily);
        if (localBytes == nil || (family != 0 && localFamily != family)) {
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpConnect localAddress must match family");
            return nil;
        }
    }

    NSString *service = [NSString stringWithFormat:@"%ld", (long)port];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    NSInteger effectiveFamily = family != 0 ? family : localFamily;
    hints.ai_family = effectiveFamily == 4 ? AF_INET : effectiveFamily == 6 ? AF_INET6 : AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *addresses = NULL;
    int rc = getaddrinfo(host.UTF8String, service.UTF8String, &hints, &addresses);
    if (rc != 0) {
        if (error != NULL) {
            *error = EJSNetProviderGetAddrInfoError(EJSProviderErrorCodeNetwork,
                                                    [NSString stringWithFormat:@"connect lookup %@ failed: %s", host, gai_strerror(rc)],
                                                    rc);
        }
        return nil;
    }

    NSError *lastError = nil;
    for (struct addrinfo *cursor = addresses; cursor != NULL; cursor = cursor->ai_next) {
        int cursorFamily = cursor->ai_family == AF_INET ? 4 : cursor->ai_family == AF_INET6 ? 6 : 0;
        if (cursorFamily == 0) {
            continue;
        }
        NSDictionary *remoteAddress = EJSNetEndpointFromSockaddr(cursor->ai_addr, (socklen_t)cursor->ai_addrlen);
        if (![_policy allowsResolvedAddress:remoteAddress[@"address"] family:cursorFamily port:port protocol:@"tcp"]) {
            lastError = EJSNetProviderError(EJSProviderErrorCodeSecurity, @"connect resolved address denied by ejs.network policy");
            continue;
        }

        int fd = socket(cursor->ai_family, cursor->ai_socktype, cursor->ai_protocol);
        if (fd < 0) {
            int socketErrno = errno;
            lastError = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                 [NSString stringWithFormat:@"socket failed: %s", strerror(socketErrno)],
                                                 socketErrno);
            continue;
        }
        if (!EJSNetBindLocalAddress(fd, localAddressString, cursorFamily, &lastError)) {
            close(fd);
            continue;
        }
        if (EJSNetSetNonBlocking(fd, YES) != 0) {
            int fcntlErrno = errno;
            lastError = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                 [NSString stringWithFormat:@"fcntl failed: %s", strerror(fcntlErrno)],
                                                 fcntlErrno);
            close(fd);
            continue;
        }
        #ifdef SO_NOSIGPIPE
        int noSigPipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        #endif
        if ([request[@"noDelay"] boolValue]) {
            int yes = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        }
        NSDictionary *keepAlive = [request[@"keepAlive"] isKindOfClass:[NSDictionary class]] ? request[@"keepAlive"] : nil;
        if ([keepAlive[@"enabled"] boolValue]) {
            int yes = 1;
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
            #ifdef TCP_KEEPALIVE
            NSInteger initialDelayMs = [keepAlive[@"initialDelayMs"] isKindOfClass:[NSNumber class]] ? [keepAlive[@"initialDelayMs"] integerValue] : 0;
            if (initialDelayMs > 0) {
                int initialDelaySeconds = (int)MAX(1, initialDelayMs / 1000);
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &initialDelaySeconds, sizeof(initialDelaySeconds));
            }
            #endif
        }

        int connectResult = connect(fd, cursor->ai_addr, (socklen_t)cursor->ai_addrlen);
        if (connectResult != 0 && errno != EINPROGRESS) {
            int connectErrno = errno;
            lastError = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                 [NSString stringWithFormat:@"connect failed: %s", strerror(connectErrno)],
                                                 connectErrno);
            close(fd);
            continue;
        }
        if (connectResult != 0) {
            NSError *waitError = nil;
            if (!EJSNetWaitForWritableFD(fd, timeoutMs, cancellation, @"tcpConnect", &waitError)) {
                lastError = waitError ?: EJSNetProviderError(EJSProviderErrorCodeNetwork, @"connect wait failed");
                close(fd);
                if (lastError.code == EJSProviderErrorCodeAborted) {
                    break;
                }
                continue;
            }
            int socketError = 0;
            socklen_t socketErrorLength = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0 || socketError != 0) {
                int connectErrno = socketError != 0 ? socketError : errno;
                lastError = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                     [NSString stringWithFormat:@"connect failed: %s", strerror(connectErrno)],
                                                     connectErrno);
                close(fd);
                continue;
            }
        }

        struct sockaddr_storage localStorage;
        socklen_t localLength = sizeof(localStorage);
        NSDictionary *localAddress = @{};
        if (getsockname(fd, (struct sockaddr *)&localStorage, &localLength) == 0) {
            localAddress = EJSNetEndpointFromSockaddr((struct sockaddr *)&localStorage, localLength);
        }
        int cancelReadFD = -1;
        int cancelWriteFD = -1;
        if (!EJSNetCreateCancellationPipe(&cancelReadFD, &cancelWriteFD, error)) {
            close(fd);
            freeaddrinfo(addresses);
            return nil;
        }

        NSString *socketID = [self storeSocketWithFD:fd
                                        cancelReadFD:cancelReadFD
                                       cancelWriteFD:cancelWriteFD
                                         localAddress:localAddress
                                        remoteAddress:remoteAddress];
        freeaddrinfo(addresses);
        return EJSNetJSONData(@{
            @"socketID": socketID,
            @"localAddress": localAddress,
            @"remoteAddress": remoteAddress
        }, error);
    }

    freeaddrinfo(addresses);
    if (error != NULL) {
        *error = lastError ?: EJSNetProviderError(EJSProviderErrorCodeNetwork, @"connect failed");
    }
    return nil;
}

- (NSData *)tcpListenWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *host = EJSNetStringIsNonEmpty(request[@"host"]) ? request[@"host"] : nil;
    NSInteger port = [request[@"port"] isKindOfClass:[NSNumber class]] ? [request[@"port"] integerValue] : -1;
    NSInteger family = [request[@"family"] isKindOfClass:[NSNumber class]] ? [request[@"family"] integerValue] : 0;
    NSInteger backlog = [request[@"backlog"] isKindOfClass:[NSNumber class]] ? [request[@"backlog"] integerValue] : 128;
    BOOL reuseAddress = [request[@"reuseAddress"] boolValue];
    if (host.length == 0u || port < 0 || port > 65535 || (family != 0 && family != 4 && family != 6) || backlog < 1 || backlog > 4096) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpListen requires host, port 0..65535, family 0/4/6, and backlog 1..4096");
        return nil;
    }

    struct sockaddr_storage bindStorage;
    memset(&bindStorage, 0, sizeof(bindStorage));
    socklen_t bindLength = 0;
    int socketFamily = 0;
    if (!EJSNetBuildListenSockaddr(host, family, port, &bindStorage, &bindLength, &socketFamily, error)) {
        return nil;
    }
    int resolvedFamily = socketFamily == AF_INET ? 4 : 6;
    NSInteger requestedPolicyPort = port == 0 ? -1 : port;
    if (![_policy allowsListenAddress:host family:resolvedFamily port:requestedPolicyPort protocol:@"tcp"]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, [NSString stringWithFormat:@"listen %@:%ld denied by ejs.network policy", host, (long)port]);
        return nil;
    }

    int fd = socket(socketFamily, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        if (error != NULL) {
            int socketErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"listen socket failed: %s", strerror(socketErrno)],
                                              socketErrno);
        }
        return nil;
    }
    if (reuseAddress) {
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    }
    if (EJSNetSetNonBlocking(fd, YES) != 0) {
        if (error != NULL) {
            int fcntlErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"listen fcntl failed: %s", strerror(fcntlErrno)],
                                              fcntlErrno);
        }
        close(fd);
        return nil;
    }
    if (bind(fd, (const struct sockaddr *)&bindStorage, bindLength) != 0) {
        if (error != NULL) {
            int bindErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"listen bind failed: %s", strerror(bindErrno)],
                                              bindErrno);
        }
        close(fd);
        return nil;
    }
    if (listen(fd, (int)backlog) != 0) {
        if (error != NULL) {
            int listenErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"listen failed: %s", strerror(listenErrno)],
                                              listenErrno);
        }
        close(fd);
        return nil;
    }

    struct sockaddr_storage localStorage;
    socklen_t localLength = sizeof(localStorage);
    if (getsockname(fd, (struct sockaddr *)&localStorage, &localLength) != 0) {
        if (error != NULL) {
            int getsocknameErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"listen getsockname failed: %s", strerror(getsocknameErrno)],
                                              getsocknameErrno);
        }
        close(fd);
        return nil;
    }
    NSDictionary *localAddress = EJSNetEndpointFromSockaddr((const struct sockaddr *)&localStorage, localLength);
    NSInteger localPort = [localAddress[@"port"] isKindOfClass:[NSNumber class]] ? [localAddress[@"port"] integerValue] : 0;
    NSInteger localFamily = [localAddress[@"family"] isKindOfClass:[NSNumber class]] ? [localAddress[@"family"] integerValue] : resolvedFamily;
    NSString *assignedAddress = [localAddress[@"address"] isKindOfClass:[NSString class]] ? localAddress[@"address"] : host;
    if (![_policy allowsListenAddress:assignedAddress family:(int)localFamily port:localPort protocol:@"tcp"]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, @"listen assigned port denied by ejs.network policy");
        close(fd);
        return nil;
    }

    int cancelReadFD = -1;
    int cancelWriteFD = -1;
    if (!EJSNetCreateCancellationPipe(&cancelReadFD, &cancelWriteFD, error)) {
        close(fd);
        return nil;
    }

    NSString *listenerID = [self storeListenerWithFD:fd
                                       cancelReadFD:cancelReadFD
                                      cancelWriteFD:cancelWriteFD
                                       localAddress:localAddress];
    return EJSNetJSONData(@{
        @"listenerID": listenerID,
        @"localAddress": localAddress
    }, error);
}

- (NSData *)tcpAcceptWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error {
    EJSNetListenerState *state = [self listenerForID:request[@"listenerID"] error:error];
    if (state == nil) {
        return nil;
    }
    if (cancellation.isCancelled) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpAccept cancelled");
        return nil;
    }
    NSInteger timeoutMs = [request[@"timeoutMs"] isKindOfClass:[NSNumber class]] ? [request[@"timeoutMs"] integerValue] : 30000;
    if (timeoutMs < 0) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpAccept timeoutMs must be >= 0");
        return nil;
    }

    [state.lock lock];
    if (state.isClosed) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp listener is closed");
        return nil;
    }
    int listenerFD = state.fd;
    int cancelReadFD = state.cancelReadFD;
    int operationCancelReadFD = cancellation.cancelReadFD;
    [state.lock unlock];

    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(listenerFD, &readSet);
    FD_SET(cancelReadFD, &readSet);
    if (operationCancelReadFD >= 0) {
        FD_SET(operationCancelReadFD, &readSet);
    }
    struct timeval timeout = EJSNetTimeout(timeoutMs);
    int maxFD = listenerFD > cancelReadFD ? listenerFD : cancelReadFD;
    if (operationCancelReadFD > maxFD) {
        maxFD = operationCancelReadFD;
    }
    int selected = select(maxFD + 1, &readSet, NULL, NULL, &timeout);
    if (selected == 0) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"tcpAccept timed out");
        return nil;
    }
    if (selected < 0) {
        if (errno == EBADF || errno == EINVAL) {
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp listener is closed");
            return nil;
        }
        if (error != NULL) {
            int selectErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"tcpAccept select failed: %s", strerror(selectErrno)],
                                              selectErrno);
        }
        return nil;
    }
    if (operationCancelReadFD >= 0 && FD_ISSET(operationCancelReadFD, &readSet)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpAccept cancelled");
        return nil;
    }
    if (FD_ISSET(cancelReadFD, &readSet)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp listener is closed");
        return nil;
    }
    if (!FD_ISSET(listenerFD, &readSet)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"tcpAccept timed out");
        return nil;
    }

    struct sockaddr_storage remoteStorage;
    socklen_t remoteLength = sizeof(remoteStorage);
    [state.lock lock];
    if (state.isClosed) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp listener is closed");
        return nil;
    }
    int acceptedFD = accept(state.fd, (struct sockaddr *)&remoteStorage, &remoteLength);
    if (acceptedFD < 0) {
        [state.lock unlock];
        if (errno == EBADF || errno == EINVAL || errno == ENOTSOCK) {
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp listener is closed");
            return nil;
        }
        if (error != NULL) {
            int acceptErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"tcpAccept failed: %s", strerror(acceptErrno)],
                                              acceptErrno);
        }
        return nil;
    }
    [state.lock unlock];
    if (EJSNetSetNonBlocking(acceptedFD, YES) != 0) {
        if (error != NULL) {
            int fcntlErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"tcpAccept fcntl failed: %s", strerror(fcntlErrno)],
                                              fcntlErrno);
        }
        close(acceptedFD);
        return nil;
    }
    #ifdef SO_NOSIGPIPE
    int noSigPipe = 1;
    setsockopt(acceptedFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    #endif

    NSDictionary *remoteAddress = EJSNetEndpointFromSockaddr((const struct sockaddr *)&remoteStorage, remoteLength);
    struct sockaddr_storage localStorage;
    socklen_t localLength = sizeof(localStorage);
    NSDictionary *localAddress = @{};
    if (getsockname(acceptedFD, (struct sockaddr *)&localStorage, &localLength) == 0) {
        localAddress = EJSNetEndpointFromSockaddr((const struct sockaddr *)&localStorage, localLength);
    }
    int acceptedCancelReadFD = -1;
    int acceptedCancelWriteFD = -1;
    if (!EJSNetCreateCancellationPipe(&acceptedCancelReadFD, &acceptedCancelWriteFD, error)) {
        close(acceptedFD);
        return nil;
    }

    NSString *socketID = [self storeSocketWithFD:acceptedFD
                                    cancelReadFD:acceptedCancelReadFD
                                   cancelWriteFD:acceptedCancelWriteFD
                                     localAddress:localAddress
                                    remoteAddress:remoteAddress];
    return EJSNetJSONData(@{
        @"socketID": socketID,
        @"localAddress": localAddress,
        @"remoteAddress": remoteAddress
    }, error);
}

- (NSData *)tcpReadWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error {
    EJSNetSocketState *state = [self socketForID:request[@"socketID"] error:error];
    if (state == nil) {
        return nil;
    }
    if (cancellation.isCancelled) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpRead cancelled");
        return nil;
    }
    NSInteger maxBytes = [request[@"maxBytes"] isKindOfClass:[NSNumber class]] ? [request[@"maxBytes"] integerValue] : 65536;
    if (maxBytes <= 0 || maxBytes > 1024 * 1024) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpRead maxBytes must be 1..1048576");
        return nil;
    }
    [state.lock lock];
    if (state.isClosed || state.isClosing) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed");
        return nil;
    }
    int socketFD = state.fd;
    int cancelReadFD = state.cancelReadFD;
    int operationCancelReadFD = cancellation.cancelReadFD;
    [state.lock unlock];

    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(socketFD, &readSet);
    int maxFD = socketFD;
    if (cancelReadFD >= 0) {
        FD_SET(cancelReadFD, &readSet);
        if (cancelReadFD > maxFD) {
            maxFD = cancelReadFD;
        }
    }
    if (operationCancelReadFD >= 0) {
        FD_SET(operationCancelReadFD, &readSet);
        if (operationCancelReadFD > maxFD) {
            maxFD = operationCancelReadFD;
        }
    }
    struct timeval timeout = EJSNetTimeout(30000);
    int selected = select(maxFD + 1, &readSet, NULL, NULL, &timeout);
    [state.lock lock];
    if (selected == 0) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"tcpRead timed out");
        return nil;
    }
    if (selected < 0) {
        int selectErrno = errno;
        BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(selectErrno);
        [state.lock unlock];
        if (error != NULL) {
            *error = closing
                ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed")
                : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                           [NSString stringWithFormat:@"tcpRead select failed: %s", strerror(selectErrno)],
                                           selectErrno);
        }
        return nil;
    }
    if (cancellation.isCancelled ||
        (operationCancelReadFD >= 0 && FD_ISSET(operationCancelReadFD, &readSet))) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpRead cancelled");
        return nil;
    }
    if (state.isClosed || state.isClosing ||
        (cancelReadFD >= 0 && FD_ISSET(cancelReadFD, &readSet))) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed");
        return nil;
    }
    if (!FD_ISSET(socketFD, &readSet)) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"tcpRead timed out");
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)maxBytes];
    ssize_t count = recv(socketFD, data.mutableBytes, (size_t)maxBytes, 0);
    if (count < 0) {
        int recvErrno = errno;
        BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(recvErrno);
        [state.lock unlock];
        if (error != NULL) {
            *error = closing
                ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed")
                : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                           [NSString stringWithFormat:@"tcpRead failed: %s", strerror(recvErrno)],
                                           recvErrno);
        }
        return nil;
    }
    [state.lock unlock];
    data.length = (NSUInteger)count;
    return data;
}

- (NSData *)tcpWriteWithRequest:(NSDictionary *)request transferBuffer:(NSData *)transferBuffer cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error {
    EJSNetSocketState *state = [self socketForID:request[@"socketID"] error:error];
    if (state == nil) {
        return nil;
    }
    if (cancellation.isCancelled) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpWrite cancelled");
        return nil;
    }
    if (transferBuffer.length == 0u) {
        return EJSNetJSONData(@{ @"bytesWritten": @0 }, error);
    }
    const unsigned char *bytes = transferBuffer.bytes;
    NSUInteger remaining = transferBuffer.length;
    NSUInteger offset = 0u;
    while (remaining > 0u) {
        [state.lock lock];
        if (state.isClosed || state.isClosing) {
            [state.lock unlock];
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed");
            return nil;
        }
        int socketFD = state.fd;
        int cancelReadFD = state.cancelReadFD;
        int operationCancelReadFD = cancellation.cancelReadFD;
        [state.lock unlock];

        fd_set readSet;
        fd_set writeSet;
        FD_ZERO(&readSet);
        FD_ZERO(&writeSet);
        FD_SET(socketFD, &writeSet);
        int maxFD = socketFD;
        if (cancelReadFD >= 0) {
            FD_SET(cancelReadFD, &readSet);
            if (cancelReadFD > maxFD) {
                maxFD = cancelReadFD;
            }
        }
        if (operationCancelReadFD >= 0) {
            FD_SET(operationCancelReadFD, &readSet);
            if (operationCancelReadFD > maxFD) {
                maxFD = operationCancelReadFD;
            }
        }
        struct timeval timeout = EJSNetTimeout(30000);
        int selected = select(maxFD + 1, &readSet, &writeSet, NULL, &timeout);
        [state.lock lock];
        if (selected == 0) {
            [state.lock unlock];
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"tcpWrite timed out");
            return nil;
        }
        if (selected < 0) {
            int selectErrno = errno;
            BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(selectErrno);
            [state.lock unlock];
            if (error != NULL) {
                *error = closing
                    ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed")
                    : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                               [NSString stringWithFormat:@"tcpWrite select failed: %s", strerror(selectErrno)],
                                               selectErrno);
            }
            return nil;
        }
        if (cancellation.isCancelled ||
            (operationCancelReadFD >= 0 && FD_ISSET(operationCancelReadFD, &readSet))) {
            [state.lock unlock];
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcpWrite cancelled");
            return nil;
        }
        if (state.isClosed || state.isClosing ||
            (cancelReadFD >= 0 && FD_ISSET(cancelReadFD, &readSet))) {
            [state.lock unlock];
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed");
            return nil;
        }
        if (!FD_ISSET(socketFD, &writeSet)) {
            [state.lock unlock];
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"tcpWrite timed out");
            return nil;
        }
        ssize_t sent = send(socketFD, bytes + offset, remaining, 0);
        if (sent < 0) {
            int sendErrno = errno;
            if (sendErrno == EAGAIN || sendErrno == EWOULDBLOCK) {
                [state.lock unlock];
                continue;
            }
            BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(sendErrno);
            [state.lock unlock];
            if (error != NULL) {
                *error = closing
                    ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed")
                    : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                               [NSString stringWithFormat:@"tcpWrite failed: %s", strerror(sendErrno)],
                                               sendErrno);
            }
            return nil;
        }
        if (sent == 0) {
            [state.lock unlock];
            if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeNetwork, @"tcpWrite wrote zero bytes");
            return nil;
        }
        offset += (NSUInteger)sent;
        remaining -= (NSUInteger)sent;
        [state.lock unlock];
    }
    return EJSNetJSONData(@{ @"bytesWritten": @(offset) }, error);
}

- (NSData *)tcpShutdownWithRequest:(NSDictionary *)request error:(NSError **)error {
    EJSNetSocketState *state = [self socketForID:request[@"socketID"] error:error];
    if (state == nil) {
        return nil;
    }
    [state.lock lock];
    if (state.isClosed) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"tcp socket is closed");
        return nil;
    }
    if (shutdown(state.fd, SHUT_WR) != 0 && errno != ENOTCONN) {
        [state.lock unlock];
        if (error != NULL) {
            int shutdownErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"tcpShutdown failed: %s", strerror(shutdownErrno)],
                                              shutdownErrno);
        }
        return nil;
    }
    [state.lock unlock];
    return EJSNetJSONData(@{ @"ok": @YES }, error);
}

- (NSData *)tcpCloseWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *socketID = EJSNetStringIsNonEmpty(request[@"socketID"]) ? request[@"socketID"] : nil;
    if (socketID.length == 0u) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpClose socketID is required");
        return nil;
    }
    EJSNetSocketState *state = [self removeSocketForID:socketID];
    [self closeSocketState:state];
    return EJSNetJSONData(@{ @"ok": @YES }, error);
}

- (NSData *)tcpListenerCloseWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *listenerID = EJSNetStringIsNonEmpty(request[@"listenerID"]) ? request[@"listenerID"] : nil;
    if (listenerID.length == 0u) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"tcpListenerClose listenerID is required");
        return nil;
    }
    EJSNetListenerState *state = [self removeListenerForID:listenerID];
    [self closeListenerState:state];
    return EJSNetJSONData(@{ @"ok": @YES }, error);
}

- (NSData *)udpBindWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *host = EJSNetStringIsNonEmpty(request[@"host"]) ? request[@"host"] : nil;
    NSInteger port = [request[@"port"] isKindOfClass:[NSNumber class]] ? [request[@"port"] integerValue] : -1;
    NSInteger family = [request[@"family"] isKindOfClass:[NSNumber class]] ? [request[@"family"] integerValue] : 0;
    BOOL reuseAddress = [request[@"reuseAddress"] boolValue];
    BOOL ipv6Only = [request[@"ipv6Only"] boolValue];
    if (host.length == 0u || port < 0 || port > 65535 || (family != 0 && family != 4 && family != 6)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpBind requires host, port 0..65535, and family 0/4/6");
        return nil;
    }

    struct sockaddr_storage bindStorage;
    memset(&bindStorage, 0, sizeof(bindStorage));
    socklen_t bindLength = 0;
    int socketFamily = 0;
    if (!EJSNetBuildUDPSockaddr(host, family, port, &bindStorage, &bindLength, &socketFamily, error)) {
        return nil;
    }
    int resolvedFamily = socketFamily == AF_INET ? 4 : 6;
    NSInteger requestedPolicyPort = port == 0 ? -1 : port;
    if (![_policy allowsListenAddress:host family:resolvedFamily port:requestedPolicyPort protocol:@"udp"]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, [NSString stringWithFormat:@"udp bind %@:%ld denied by ejs.network policy", host, (long)port]);
        return nil;
    }

    int fd = socket(socketFamily, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        if (error != NULL) {
            int socketErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"udp bind socket failed: %s", strerror(socketErrno)],
                                              socketErrno);
        }
        return nil;
    }
    if (reuseAddress) {
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    }
    #ifdef IPV6_V6ONLY
    if (socketFamily == AF_INET6) {
        int only = ipv6Only ? 1 : 0;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof(only));
    }
    #else
    (void)ipv6Only;
    #endif
    if (EJSNetSetNonBlocking(fd, YES) != 0) {
        if (error != NULL) {
            int fcntlErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"udp bind fcntl failed: %s", strerror(fcntlErrno)],
                                              fcntlErrno);
        }
        close(fd);
        return nil;
    }
    if (bind(fd, (const struct sockaddr *)&bindStorage, bindLength) != 0) {
        if (error != NULL) {
            int bindErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"udp bind failed: %s", strerror(bindErrno)],
                                              bindErrno);
        }
        close(fd);
        return nil;
    }

    struct sockaddr_storage localStorage;
    socklen_t localLength = sizeof(localStorage);
    if (getsockname(fd, (struct sockaddr *)&localStorage, &localLength) != 0) {
        if (error != NULL) {
            int getsocknameErrno = errno;
            *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                              [NSString stringWithFormat:@"udp getsockname failed: %s", strerror(getsocknameErrno)],
                                              getsocknameErrno);
        }
        close(fd);
        return nil;
    }
    NSDictionary *localAddress = EJSNetEndpointFromSockaddr((const struct sockaddr *)&localStorage, localLength);
    NSInteger localPort = [localAddress[@"port"] isKindOfClass:[NSNumber class]] ? [localAddress[@"port"] integerValue] : 0;
    NSInteger localFamily = [localAddress[@"family"] isKindOfClass:[NSNumber class]] ? [localAddress[@"family"] integerValue] : resolvedFamily;
    NSString *assignedAddress = [localAddress[@"address"] isKindOfClass:[NSString class]] ? localAddress[@"address"] : host;
    if (![_policy allowsListenAddress:assignedAddress family:(int)localFamily port:localPort protocol:@"udp"]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, @"udp bind assigned port denied by ejs.network policy");
        close(fd);
        return nil;
    }

    int cancelReadFD = -1;
    int cancelWriteFD = -1;
    if (!EJSNetCreateCancellationPipe(&cancelReadFD, &cancelWriteFD, error)) {
        close(fd);
        return nil;
    }

    NSString *socketID = [self storeSocketWithFD:fd
                                    cancelReadFD:cancelReadFD
                                   cancelWriteFD:cancelWriteFD
                                     localAddress:localAddress
                                    remoteAddress:@{}];
    return EJSNetJSONData(@{
        @"socketID": socketID,
        @"localAddress": localAddress
    }, error);
}

- (NSData *)udpSendWithRequest:(NSDictionary *)request transferBuffer:(NSData *)transferBuffer error:(NSError **)error {
    EJSNetSocketState *state = [self socketForID:request[@"socketID"] error:error];
    if (state == nil) {
        return nil;
    }
    NSString *host = EJSNetStringIsNonEmpty(request[@"host"]) ? request[@"host"] : nil;
    NSInteger port = [request[@"port"] isKindOfClass:[NSNumber class]] ? [request[@"port"] integerValue] : 0;
    NSInteger family = [request[@"family"] isKindOfClass:[NSNumber class]] ? [request[@"family"] integerValue] : 0;
    if (host.length == 0u || port < 1 || port > 65535 || (family != 0 && family != 4 && family != 6)) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpSend requires socketID, host, port 1..65535, and family 0/4/6");
        return nil;
    }
    if (transferBuffer.length > (NSUInteger)_policy.maxDatagramBytes) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpSend transferBuffer exceeds UDP datagram limit");
        return nil;
    }
    if (![_policy allowsUDPSendHost:host port:port]) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeSecurity, [NSString stringWithFormat:@"udp send %@:%ld denied by ejs.network policy", host, (long)port]);
        return nil;
    }

    NSString *service = [NSString stringWithFormat:@"%ld", (long)port];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = family == 4 ? AF_INET : family == 6 ? AF_INET6 : AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;

    struct addrinfo *addresses = NULL;
    int rc = getaddrinfo(host.UTF8String, service.UTF8String, &hints, &addresses);
    if (rc != 0) {
        if (error != NULL) {
            *error = EJSNetProviderGetAddrInfoError(EJSProviderErrorCodeNetwork,
                                                    [NSString stringWithFormat:@"udp send lookup %@ failed: %s", host, gai_strerror(rc)],
                                                    rc);
        }
        return nil;
    }

    NSError *lastError = nil;
    for (struct addrinfo *cursor = addresses; cursor != NULL; cursor = cursor->ai_next) {
        int cursorFamily = cursor->ai_family == AF_INET ? 4 : cursor->ai_family == AF_INET6 ? 6 : 0;
        if (cursorFamily == 0) {
            continue;
        }
        NSDictionary *remoteAddress = EJSNetEndpointFromSockaddr(cursor->ai_addr, (socklen_t)cursor->ai_addrlen);
        if (![_policy allowsResolvedAddress:remoteAddress[@"address"] family:cursorFamily port:port protocol:@"udp"]) {
            lastError = EJSNetProviderError(EJSProviderErrorCodeSecurity, @"udp send resolved address denied by ejs.network policy");
            continue;
        }

        while (YES) {
            [state.lock lock];
            if (state.isClosed) {
                [state.lock unlock];
                lastError = EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed");
                break;
            }
            int socketFD = state.fd;
            ssize_t sent = sendto(socketFD,
                                  transferBuffer.bytes,
                                  transferBuffer.length,
                                  0,
                                  cursor->ai_addr,
                                  (socklen_t)cursor->ai_addrlen);
            if (sent >= 0) {
                [state.lock unlock];
                freeaddrinfo(addresses);
                return EJSNetJSONData(@{ @"bytesSent": @(sent) }, error);
            }
            int sendErrno = errno;
            BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(sendErrno);
            [state.lock unlock];
            if (closing) {
                lastError = EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed");
                break;
            }
            if (sendErrno == EAGAIN || sendErrno == EWOULDBLOCK) {
                fd_set writeSet;
                FD_ZERO(&writeSet);
                FD_SET(socketFD, &writeSet);
                struct timeval timeout = EJSNetTimeout(30000);
                int selected = select(socketFD + 1, NULL, &writeSet, NULL, &timeout);
                if (selected <= 0) {
                    int selectErrno = errno;
                    BOOL closingAfterSelect = state.isClosing && EJSNetErrnoIndicatesLocalClose(selectErrno);
                    lastError = selected == 0
                        ? EJSNetProviderError(EJSProviderErrorCodeTimeout, @"udpSend timed out")
                        : closingAfterSelect
                            ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed")
                            : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                       [NSString stringWithFormat:@"udpSend select failed: %s", strerror(selectErrno)],
                                                       selectErrno);
                    break;
                }
                continue;
            }
            lastError = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                                 [NSString stringWithFormat:@"udpSend failed: %s", strerror(sendErrno)],
                                                 sendErrno);
            break;
        }
        if (lastError != nil && lastError.code == EJSProviderErrorCodeAborted) {
            break;
        }
    }

    freeaddrinfo(addresses);
    if (error != NULL) {
        *error = lastError ?: EJSNetProviderError(EJSProviderErrorCodeNetwork, @"udpSend failed");
    }
    return nil;
}

- (NSData *)udpRecvWithRequest:(NSDictionary *)request cancellation:(EJSNetCancellation *)cancellation error:(NSError **)error {
    EJSNetSocketState *state = [self socketForID:request[@"socketID"] error:error];
    if (state == nil) {
        return nil;
    }
    if (cancellation.isCancelled) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"udpRecv cancelled");
        return nil;
    }
    NSInteger maxBytes = [request[@"maxBytes"] isKindOfClass:[NSNumber class]] ? [request[@"maxBytes"] integerValue] : 65507;
    NSInteger timeoutMs = [request[@"timeoutMs"] isKindOfClass:[NSNumber class]] ? [request[@"timeoutMs"] integerValue] : 30000;
    if (maxBytes < 1 || maxBytes > _policy.maxDatagramBytes) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpRecv maxBytes exceeds UDP datagram limit");
        return nil;
    }
    if (timeoutMs < 0) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpRecv timeoutMs must be >= 0");
        return nil;
    }

    [state.lock lock];
    if (state.isClosed) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed");
        return nil;
    }
    int socketFD = state.fd;
    int cancelReadFD = state.cancelReadFD;
    int operationCancelReadFD = cancellation.cancelReadFD;
    [state.lock unlock];
    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(socketFD, &readSet);
    int maxFD = socketFD;
    if (cancelReadFD >= 0) {
        FD_SET(cancelReadFD, &readSet);
        if (cancelReadFD > maxFD) {
            maxFD = cancelReadFD;
        }
    }
    if (operationCancelReadFD >= 0) {
        FD_SET(operationCancelReadFD, &readSet);
        if (operationCancelReadFD > maxFD) {
            maxFD = operationCancelReadFD;
        }
    }
    struct timeval timeout = EJSNetTimeout(timeoutMs);
    int selected = select(maxFD + 1, &readSet, NULL, NULL, &timeout);
    [state.lock lock];
    if (selected == 0) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"udpRecv timed out");
        return nil;
    }
    if (selected < 0) {
        int selectErrno = errno;
        BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(selectErrno);
        [state.lock unlock];
        if (error != NULL) {
            *error = closing
                ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed")
                : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                           [NSString stringWithFormat:@"udpRecv select failed: %s", strerror(selectErrno)],
                                           selectErrno);
        }
        return nil;
    }
    if (cancellation.isCancelled ||
        (operationCancelReadFD >= 0 && FD_ISSET(operationCancelReadFD, &readSet))) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"udpRecv cancelled");
        return nil;
    }
    if (state.isClosed || state.isClosing ||
        (cancelReadFD >= 0 && FD_ISSET(cancelReadFD, &readSet))) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed");
        return nil;
    }
    if (!FD_ISSET(socketFD, &readSet)) {
        [state.lock unlock];
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, @"udpRecv timed out");
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)maxBytes];
    struct sockaddr_storage remoteStorage;
    socklen_t remoteLength = sizeof(remoteStorage);
    ssize_t count = recvfrom(socketFD, data.mutableBytes, (size_t)maxBytes, 0, (struct sockaddr *)&remoteStorage, &remoteLength);
    if (count < 0) {
        int recvErrno = errno;
        BOOL closing = state.isClosing && EJSNetErrnoIndicatesLocalClose(recvErrno);
        [state.lock unlock];
        if (error != NULL) {
            *error = closing
                ? EJSNetProviderError(EJSProviderErrorCodeAborted, @"udp socket is closed")
                : EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork,
                                           [NSString stringWithFormat:@"udpRecv failed: %s", strerror(recvErrno)],
                                           recvErrno);
        }
        return nil;
    }
    [state.lock unlock];
    data.length = (NSUInteger)count;

    NSDictionary *remoteAddress = EJSNetEndpointFromSockaddr((const struct sockaddr *)&remoteStorage, remoteLength);
    NSInteger remoteFamily = [remoteAddress[@"family"] isKindOfClass:[NSNumber class]] ? [remoteAddress[@"family"] integerValue] : 0;
    NSInteger remotePort = [remoteAddress[@"port"] isKindOfClass:[NSNumber class]] ? [remoteAddress[@"port"] integerValue] : 0;
    NSString *remoteHost = [remoteAddress[@"address"] isKindOfClass:[NSString class]] ? remoteAddress[@"address"] : @"";
    if (remoteFamily != 4 && remoteFamily != 6) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeNetwork, @"udpRecv returned unsupported address family");
        return nil;
    }
    if (remotePort < 1 || remotePort > 65535 || remoteHost.length == 0u) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeNetwork, @"udpRecv returned invalid remote endpoint");
        return nil;
    }

    NSString *base64Data = [data base64EncodedStringWithOptions:0];
    if (base64Data == nil && error != NULL) {
        *error = EJSNetProviderError(EJSProviderErrorCodeInternal, @"udpRecv failed to encode payload");
        return nil;
    }
    return EJSNetJSONData(@{
        @"remoteAddress": remoteAddress,
        @"data": base64Data
    }, error);
}

- (NSData *)udpCloseWithRequest:(NSDictionary *)request error:(NSError **)error {
    NSString *socketID = EJSNetStringIsNonEmpty(request[@"socketID"]) ? request[@"socketID"] : nil;
    if (socketID.length == 0u) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInvalidArgument, @"udpClose socketID is required");
        return nil;
    }
    EJSNetSocketState *state = [self removeSocketForID:socketID];
    [self closeSocketState:state];
    return EJSNetJSONData(@{ @"ok": @YES }, error);
}
@end

#ifdef EJS_TEST
static EJSNetPolicy *EJSNetTestPermissivePolicy(void) {
    return [[EJSNetPolicy alloc] initWithConfigured:YES
                                        dnsEnabled:YES
                                 tcpConnectEnabled:YES
                                  tcpListenEnabled:YES
                                        udpEnabled:YES
                              outboundDefaultAllow:YES
                               inboundDefaultAllow:YES
                               denyPrivateNetworks:NO
                                      denyLinkLocal:NO
                                  maxDatagramBytes:65507
                                outboundAllowRules:@[]
                                 inboundAllowRules:@[]];
}

static EJSNetCancellation *EJSNetTestCancellation(NSError **error) {
    int cancelReadFD = -1;
    int cancelWriteFD = -1;
    if (!EJSNetCreateCancellationPipe(&cancelReadFD, &cancelWriteFD, error)) {
        return nil;
    }
    return [[EJSNetCancellation alloc] initWithCancelReadFD:cancelReadFD cancelWriteFD:cancelWriteFD];
}

static NSDictionary *EJSNetTestJSONObject(NSData *data, NSError **error) {
    id object = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error != NULL && *error == nil) {
            *error = EJSNetProviderError(EJSProviderErrorCodeInternal, @"net test expected JSON object");
        }
        return nil;
    }
    return (NSDictionary *)object;
}

static BOOL EJSNetTestWaitForCancelledOperation(dispatch_semaphore_t semaphore,
                                                NSData *__strong *result,
                                                NSError *__strong *operationError,
                                                NSString *label,
                                                NSError **error) {
    long waitResult = dispatch_semaphore_wait(semaphore,
                                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    if (waitResult != 0) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeTimeout, [NSString stringWithFormat:@"%@ cancel did not wake select", label]);
        return NO;
    }
    if ((result != NULL && *result != nil) ||
        operationError == NULL ||
        (*operationError).code != EJSProviderErrorCodeAborted) {
        if (error != NULL) *error = EJSNetProviderError(EJSProviderErrorCodeInternal, [NSString stringWithFormat:@"%@ cancel returned unexpected result", label]);
        return NO;
    }
    return YES;
}

static BOOL EJSNetTestFillSendBuffer(int fd, NSError **error) {
    unsigned char buffer[8192];
    memset(buffer, 0x5a, sizeof(buffer));
    for (;;) {
        ssize_t written = send(fd, buffer, sizeof(buffer), 0);
        if (written > 0) {
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return YES;
        }
        if (error != NULL) *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork, @"net test failed to fill send buffer", errno);
        return NO;
    }
}

BOOL EJSNetRunOperationCancellationSelfTest(NSError **error) {
    EJSNetProvider *provider = [[EJSNetProvider alloc] initWithPolicy:EJSNetTestPermissivePolicy()];
    NSError *localError = nil;
    NSData *listenerData = [provider tcpListenWithRequest:@{
        @"host": @"127.0.0.1",
        @"port": @0,
        @"family": @4,
        @"backlog": @1,
        @"reuseAddress": @YES
    } error:&localError];
    NSDictionary *listener = EJSNetTestJSONObject(listenerData, &localError);
    NSString *listenerID = [listener[@"listenerID"] isKindOfClass:[NSString class]] ? listener[@"listenerID"] : nil;
    if (listenerID.length == 0u) {
        if (error != NULL) *error = localError ?: EJSNetProviderError(EJSProviderErrorCodeInternal, @"net test failed to create listener");
        return NO;
    }

    EJSNetCancellation *acceptCancellation = EJSNetTestCancellation(error);
    if (acceptCancellation == nil) {
        return NO;
    }
    dispatch_semaphore_t acceptSemaphore = dispatch_semaphore_create(0);
    __block NSData *acceptResult = nil;
    __block NSError *acceptError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        acceptResult = [provider tcpAcceptWithRequest:@{ @"listenerID": listenerID, @"timeoutMs": @30000 }
                                         cancellation:acceptCancellation
                                                error:&acceptError];
        dispatch_semaphore_signal(acceptSemaphore);
    });
    usleep(50000);
    [acceptCancellation cancel];
    BOOL acceptOK = EJSNetTestWaitForCancelledOperation(acceptSemaphore, &acceptResult, &acceptError, @"tcpAccept", error);
    (void)[provider tcpListenerCloseWithRequest:@{ @"listenerID": listenerID } error:nil];
    if (!acceptOK) {
        return NO;
    }

    int connectPairFDs[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, connectPairFDs) != 0) {
        if (error != NULL) *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork, @"socketpair failed", errno);
        return NO;
    }
    if (EJSNetSetNonBlocking(connectPairFDs[0], YES) != 0 ||
        !EJSNetTestFillSendBuffer(connectPairFDs[0], error)) {
        close(connectPairFDs[0]);
        close(connectPairFDs[1]);
        return NO;
    }
    EJSNetCancellation *connectCancellation = EJSNetTestCancellation(error);
    if (connectCancellation == nil) {
        close(connectPairFDs[0]);
        close(connectPairFDs[1]);
        return NO;
    }
    dispatch_semaphore_t connectSemaphore = dispatch_semaphore_create(0);
    int connectWriteFD = connectPairFDs[0];
    __block NSData *connectResult = nil;
    __block NSError *connectError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (EJSNetWaitForWritableFD(connectWriteFD, 30000, connectCancellation, @"tcpConnect", &connectError)) {
            connectResult = [NSData data];
        }
        dispatch_semaphore_signal(connectSemaphore);
    });
    usleep(50000);
    [connectCancellation cancel];
    BOOL connectOK = EJSNetTestWaitForCancelledOperation(connectSemaphore, &connectResult, &connectError, @"tcpConnect", error);
    close(connectPairFDs[0]);
    close(connectPairFDs[1]);
    if (!connectOK) {
        return NO;
    }

    int pairFDs[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pairFDs) != 0) {
        if (error != NULL) *error = EJSNetProviderPOSIXError(EJSProviderErrorCodeNetwork, @"socketpair failed", errno);
        return NO;
    }
    int socketCancelReadFD = -1;
    int socketCancelWriteFD = -1;
    if (!EJSNetCreateCancellationPipe(&socketCancelReadFD, &socketCancelWriteFD, error)) {
        close(pairFDs[0]);
        close(pairFDs[1]);
        return NO;
    }
    NSString *socketID = [provider storeSocketWithFD:pairFDs[0]
                                        cancelReadFD:socketCancelReadFD
                                       cancelWriteFD:socketCancelWriteFD
                                        localAddress:@{}
                                       remoteAddress:@{}];
    EJSNetCancellation *readCancellation = EJSNetTestCancellation(error);
    if (readCancellation == nil) {
        (void)[provider tcpCloseWithRequest:@{ @"socketID": socketID } error:nil];
        close(pairFDs[1]);
        return NO;
    }
    dispatch_semaphore_t readSemaphore = dispatch_semaphore_create(0);
    __block NSData *readResult = nil;
    __block NSError *readError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        readResult = [provider tcpReadWithRequest:@{ @"socketID": socketID, @"maxBytes": @1 }
                                     cancellation:readCancellation
                                            error:&readError];
        dispatch_semaphore_signal(readSemaphore);
    });
    usleep(50000);
    [readCancellation cancel];
    BOOL readOK = EJSNetTestWaitForCancelledOperation(readSemaphore, &readResult, &readError, @"tcpRead", error);
    (void)[provider tcpCloseWithRequest:@{ @"socketID": socketID } error:nil];
    close(pairFDs[1]);
    if (!readOK) {
        return NO;
    }

    NSData *udpData = [provider udpBindWithRequest:@{
        @"host": @"127.0.0.1",
        @"port": @0,
        @"family": @4,
        @"reuseAddress": @YES
    } error:&localError];
    NSDictionary *udpSocket = EJSNetTestJSONObject(udpData, &localError);
    NSString *udpSocketID = [udpSocket[@"socketID"] isKindOfClass:[NSString class]] ? udpSocket[@"socketID"] : nil;
    if (udpSocketID.length == 0u) {
        if (error != NULL) *error = localError ?: EJSNetProviderError(EJSProviderErrorCodeInternal, @"net test failed to bind UDP socket");
        return NO;
    }
    EJSNetCancellation *udpCancellation = EJSNetTestCancellation(error);
    if (udpCancellation == nil) {
        (void)[provider udpCloseWithRequest:@{ @"socketID": udpSocketID } error:nil];
        return NO;
    }
    dispatch_semaphore_t udpSemaphore = dispatch_semaphore_create(0);
    __block NSData *udpResult = nil;
    __block NSError *udpError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        udpResult = [provider udpRecvWithRequest:@{ @"socketID": udpSocketID, @"maxBytes": @1, @"timeoutMs": @30000 }
                                    cancellation:udpCancellation
                                           error:&udpError];
        dispatch_semaphore_signal(udpSemaphore);
    });
    usleep(50000);
    [udpCancellation cancel];
    BOOL udpOK = EJSNetTestWaitForCancelledOperation(udpSemaphore, &udpResult, &udpError, @"udpRecv", error);
    (void)[provider udpCloseWithRequest:@{ @"socketID": udpSocketID } error:nil];
    return udpOK;
}
#endif

static BOOL EJSNetInstallBundledScriptsIntoContext(EJSContext *context,
                                                   const EJSNetBundledScript *scripts,
                                                   size_t scriptCount,
                                                   NSError **error) {
    if (context == nil) {
        if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"Context is required");
        return NO;
    }

    EJSNetPolicy *policy = EJSNetPolicyFromJSON([context configurationValueForKey:EJSNetworkConfigurationKey], error);
    if (policy == nil) {
        return NO;
    }

    EJSAppleInstallTransaction transaction;
    if (!EJSAppleInstallTransactionBegin(&transaction, context, @[ @"EJSNet", @"EJSNetworkError" ], error)) {
        return NO;
    }
    if (!EJSAppleInstallTransactionRegisterProvider(&transaction, [[EJSNetProvider alloc] initWithPolicy:policy], error)) {
        EJSAppleInstallTransactionRollbackPreservingError(&transaction, error);
        return NO;
    }

    for (size_t i = 0u; i < scriptCount; ++i) {
        const EJSNetBundledScript *script = &scripts[i];
        NSString *source = [[NSString alloc] initWithBytes:script->code length:script->len encoding:NSUTF8StringEncoding];
        NSString *filename = [NSString stringWithUTF8String:script->name];
        if (source == nil || filename == nil) {
            if (error != NULL) *error = EJSNetRuntimeError(EJSRuntimeErrorCodeInvalidArgument, @"EJSNet bundled script must be valid UTF-8");
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

BOOL EJSNetInstallIntoContext(EJSContext *context, NSError **error) {
    return EJSNetInstallBundledScriptsIntoContext(context, ejs_net_scripts, ejs_net_scripts_count, error);
}

#ifdef EJS_TEST
BOOL EJSNetInstallBundledScriptForTesting(EJSContext *context,
                                          const char *name,
                                          const unsigned char *code,
                                          size_t length,
                                          NSError **error) {
    EJSNetBundledScript script = {
        .name = name,
        .code = code,
        .len = length
    };
    return EJSNetInstallBundledScriptsIntoContext(context, &script, 1u, error);
}
#endif
