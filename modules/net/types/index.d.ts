export {};

/**
 * API declarations for module `net`.
 * DNS plus raw TCP/UDP socket APIs exposed as `globalThis.EJSNet`.
 *
 * The declarations describe the JavaScript/Web surface only. Native provider
 * installation hooks and policy internals are intentionally not part of this
 * file.
 */

declare global {

  /**
   * Address-family selector accepted by network operations.
   *
   * `0` means "any family" for inputs. Successful address results use `4` or
   * `6`.
   */
  type EJSNetFamily = 0 | 4 | 6;

  /**
   * Concrete IP address family returned by DNS and socket address results.
   */
  type EJSNetAddressFamily = 4 | 6;

  /**
   * Bytes accepted by TCP `write` and UDP `send`.
   */
  type EJSNetBytes = ArrayBuffer | ArrayBufferView;

  /**
   * Options for name lookup. `family` defaults to `0`; `all` defaults to
   * `false`.
   */
  interface EJSNetLookupOptions {
    readonly family?: EJSNetFamily;
    readonly all?: boolean;
  }

  /**
   * Lookup options that request every allowed address.
   */
  interface EJSNetLookupAllOptions extends EJSNetLookupOptions {
    readonly all: true;
  }

  /**
   * Lookup options that request the first allowed address.
   */
  interface EJSNetLookupOneOptions extends EJSNetLookupOptions {
    readonly all?: false;
  }

  /**
   * One normalized address returned by `EJSNet.lookup`.
   *
   * `canonicalName` is always present on the JS object. Providers that do not
   * supply a canonical name are normalized to an empty string.
   */
  interface EJSNetLookupResult {
    readonly address: string;
    readonly family: EJSNetAddressFamily;
    readonly canonicalName: string;
  }

  /**
   * Socket address representation used by TCP and UDP results.
   */
  interface EJSNetSocketAddress {
    readonly address: string;
    readonly port: number;
    readonly family: EJSNetAddressFamily;
  }

  /**
   * Optional keep-alive configuration for TCP clients.
   *
   * When provided, `enabled` is coerced to a boolean. `initialDelayMs` defaults
   * to `0` and must be a non-negative integer.
   */
  interface EJSNetTCPKeepAliveOptions {
    readonly enabled?: boolean;
    readonly initialDelayMs?: number;
  }

  /**
   * Parameters for establishing TCP client connections.
   *
   * `host` must be a non-empty string and `port` must be `1..65535`. `family`
   * defaults to `0`. `localAddress`, when present, must be a non-empty literal
   * address accepted by the native provider and must match `family` when a
   * family is specified. `timeoutMs` must be non-negative; omitted or `0`
   * selects the provider connect timeout.
   */
  interface EJSNetTCPConnectOptions {
    readonly host: string;
    readonly port: number;
    readonly family?: EJSNetFamily;
    readonly localAddress?: string;
    readonly noDelay?: boolean;
    readonly keepAlive?: EJSNetTCPKeepAliveOptions;
    readonly timeoutMs?: number;
  }

  /**
   * Read options for TCP receive calls. `maxBytes` defaults to `65536` and must
   * be `1..1048576`.
   */
  interface EJSNetTCPReadOptions {
    readonly maxBytes?: number;
  }

  /**
   * Parameters for binding/listening TCP sockets.
   *
   * `host` must be a non-empty bind address string. `port` may be `0` to request
   * an assigned local port, otherwise it must be `1..65535`. `family` defaults
   * to `0`; `backlog` defaults to `128` and must be `1..4096`.
   */
  interface EJSNetTCPListenOptions {
    readonly host: string;
    readonly port: number;
    readonly family?: EJSNetFamily;
    readonly backlog?: number;
    readonly reuseAddress?: boolean;
  }

  /**
   * Options for accepting inbound TCP connections.
   *
   * `timeoutMs` defaults to `30000` and must be a non-negative integer. `0`
   * performs an immediate poll.
   */
  interface EJSNetTCPAcceptOptions {
    readonly timeoutMs?: number;
  }

  /**
   * Parameters for binding UDP sockets.
   *
   * `host` must be a non-empty bind address string. `port` may be `0` to request
   * an assigned local port, otherwise it must be `1..65535`. `family` defaults
   * to `0`. `reuseAddress` and `ipv6Only` are coerced to booleans.
   */
  interface EJSNetUDPBindOptions {
    readonly host: string;
    readonly port: number;
    readonly family?: EJSNetFamily;
    readonly reuseAddress?: boolean;
    readonly ipv6Only?: boolean;
  }

  /**
   * UDP destination target.
   *
   * `host` must be non-empty and `port` must be `1..65535`. `family` defaults
   * to `0`.
   */
  interface EJSNetUDPSendTarget {
    readonly host: string;
    readonly port: number;
    readonly family?: EJSNetFamily;
  }

  /**
   * Receive constraints for UDP sockets.
   *
   * `maxBytes` defaults to `65507` and must be at least `1`. The native policy
   * may lower the maximum datagram size. `timeoutMs` defaults to `30000` and
   * must be a non-negative integer; `0` performs an immediate poll.
   */
  interface EJSNetUDPRecvOptions {
    readonly maxBytes?: number;
    readonly timeoutMs?: number;
  }

  /**
   * One UDP datagram with sender address.
   */
  interface EJSNetUDPDatagram {
    readonly data: Uint8Array;
    readonly remoteAddress: EJSNetSocketAddress;
  }

  /**
   * Active TCP stream socket.
   *
   * Returned by `EJSNet.tcp.connect()` and `EJSTCPListener.accept()`. `close()`
   * is idempotent. Calling `read`, `write`, or `shutdown` after `close()`
   * rejects with an `EJSNetworkError` whose `code` is `"ECANCELLED"`.
   */
  interface EJSNetTCPSocket {
    readonly localAddress: EJSNetSocketAddress;
    readonly remoteAddress: EJSNetSocketAddress;
    read(options?: EJSNetTCPReadOptions): Promise<Uint8Array>;
    write(data: EJSNetBytes): Promise<void>;
    shutdown(): Promise<void>;
    close(): Promise<void>;
  }

  /**
   * Active TCP listener returned by `EJSNet.tcp.listen()`.
   *
   * `close()` is idempotent. Calling `accept()` after `close()` rejects with an
   * `EJSNetworkError` whose `code` is `"ECANCELLED"`.
   */
  interface EJSNetTCPListener {
    readonly localAddress: EJSNetSocketAddress;
    accept(options?: EJSNetTCPAcceptOptions): Promise<EJSNetTCPSocket>;
    close(): Promise<void>;
  }

  /**
   * TCP operations namespace.
   */
  interface EJSNetTCPAPI {
    connect(options: EJSNetTCPConnectOptions): Promise<EJSNetTCPSocket>;
    listen(options: EJSNetTCPListenOptions): Promise<EJSNetTCPListener>;
  }

  /**
   * Active UDP socket.
   *
   * Returned by `EJSNet.udp.bind()`. `close()` is idempotent. Calling `send()`
   * or `recv()` after `close()` rejects with an `EJSNetworkError` whose `code`
   * is `"ECANCELLED"`.
   */
  interface EJSNetUDPSocket {
    readonly localAddress: EJSNetSocketAddress;
    send(data: EJSNetBytes, target: EJSNetUDPSendTarget): Promise<void>;
    recv(options?: EJSNetUDPRecvOptions): Promise<EJSNetUDPDatagram>;
    close(): Promise<void>;
  }

  /**
   * UDP operations namespace.
   */
  interface EJSNetUDPAPI {
    bind(options: EJSNetUDPBindOptions): Promise<EJSNetUDPSocket>;
  }

  /**
   * Stable error code used by `EJSNetworkError`.
   */
  type EJSNetworkErrorCode =
    | "EINVAL"
    | "ECANCELLED"
    | "ENETWORK"
    | "ETLS"
    | "ETIMEOUT"
    | "ENOTSUP"
    | "EPERM"
    | "EINTERNAL"
    | "EDNS"
    | "ECONNREFUSED"
    | "ECONNRESET"
    | "EHOSTUNREACH"
    | "ENETUNREACH";

  /**
   * JS operation labels attached to `EJSNetworkError.operation`.
   */
  type EJSNetworkOperation =
    | "lookup"
    | "connect"
    | "listen"
    | "accept"
    | "read"
    | "write"
    | "shutdown"
    | "close"
    | "bind"
    | "send"
    | "recv";

  /**
   * System-call or native-operation labels attached to
   * `EJSNetworkError.syscall`.
   */
  type EJSNetworkSyscall =
    | "getaddrinfo"
    | "connect"
    | "listen"
    | "accept"
    | "recv"
    | "send"
    | "shutdown"
    | "close"
    | "bind"
    | "sendto"
    | "recvfrom"
    | "read"
    | "write";

  /**
   * Error object shape used by net provider failures and by JS wrapper
   * validation of malformed provider responses.
   *
   * Provider failures are wrapped with `name: "EJSNetworkError"` and
   * `module: "net"`. DNS resolver failures use `code: "EDNS"`. Network
   * failures with POSIX detail may be refined to `ECONNREFUSED`, `ECONNRESET`,
   * `EHOSTUNREACH`, `ENETUNREACH`, or `ETIMEOUT`; otherwise provider network
   * failures use `ENETWORK`. `nativeDomain` and `nativeCode` preserve provider
   * diagnostics when present.
   */
  interface EJSNetworkError extends Error {
    readonly name: "EJSNetworkError";
    readonly code?: EJSNetworkErrorCode;
    readonly module?: "net";
    readonly operation?: EJSNetworkOperation;
    readonly syscall?: EJSNetworkSyscall;
    readonly host?: string;
    readonly address?: string;
    readonly port?: number;
    readonly family?: EJSNetFamily;
    readonly nativeDomain?: string;
    readonly nativeCode?: number;
  }

  /**
   * API namespace for DNS and socket helpers.
   */
  interface EJSNetAPI {
    lookup(host: string, options: EJSNetLookupAllOptions): Promise<ReadonlyArray<EJSNetLookupResult>>;
    lookup(host: string, options?: EJSNetLookupOneOptions): Promise<EJSNetLookupResult>;
    lookup(host: string, options?: EJSNetLookupOptions): Promise<EJSNetLookupResult | ReadonlyArray<EJSNetLookupResult>>;
    readonly tcp: EJSNetTCPAPI;
    readonly udp: EJSNetUDPAPI;
  }

  /**
   * Runtime binding for raw DNS and socket APIs.
   */
  var EJSNet: EJSNetAPI;

  /**
   * Constructor/function for creating a named network error object.
   *
   * Errors thrown by `EJSNet` methods include the additional diagnostic fields
   * above; a manually created `EJSNetworkError` only sets `name` and `message`.
   */
  var EJSNetworkError: {
    new(message?: string): EJSNetworkError;
    (message?: string): EJSNetworkError;
    readonly prototype: EJSNetworkError;
  };
}
