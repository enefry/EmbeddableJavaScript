export {};

/**
 * API declarations for module `stdlib/ipaddr`.
 *
 * Installing the module exposes the pure JavaScript helper as
 * `globalThis.EJSIPAddr`. Apple installer functions are platform-private and
 * intentionally not declared here.
 */

declare global {
  /**
   * Parsed IPv4 or IPv6 address.
   *
   * `address` and `normalized` contain the canonical runtime spelling. IPv6
   * inputs are compressed where possible, embedded IPv4 tails are converted to
   * hexadecimal hextets, and scoped IPv6 inputs keep the `%scope` suffix.
   * `bytes` contains 4 bytes for IPv4 and 16 bytes for IPv6.
   */
  interface EJSIPAddress {
    /** Canonical normalized address string. */
    readonly address: string;
    /** Address family: `4` for IPv4, `6` for IPv6. */
    readonly family: 4 | 6;
    /** Same canonical string returned by `normalize(value)`. */
    readonly normalized: string;
    /** Address bytes in network byte order. */
    readonly bytes: readonly number[];
    /** IPv6 zone identifier from inputs such as `fe80::1%lo0`. */
    readonly scopeId?: string;
  }

  /**
   * Minimal object shape accepted by `EJSIPAddr.contains`.
   *
   * Runtime validation requires `bytes` to be an Array with 4 entries for IPv4
   * or 16 entries for IPv6. Each byte must be an integer from 0 through 255.
   * `prefixLength` must be in the family range: 0-32 for IPv4, 0-128 for IPv6.
   */
  interface EJSIPCIDRLike {
    /** CIDR address family. */
    readonly family: 4 | 6;
    /** CIDR prefix length in bits. */
    readonly prefixLength: number;
    /** CIDR network bytes in network byte order. */
    readonly bytes: readonly number[];
  }

  /**
   * Parsed CIDR range returned by `parseCIDR`.
   *
   * The returned object includes the parsed network bytes and prefix length.
   * For scoped IPv6 CIDR strings, `address` and `normalized` include the
   * `%scope` suffix, but no separate `scopeId` field is produced.
   */
  interface EJSIPCIDR extends EJSIPCIDRLike {
    /** Canonical normalized address portion. */
    readonly address: string;
    /** Canonical normalized CIDR string, including `/prefixLength`. */
    readonly normalized: string;
  }

  /**
   * IP address parsing, normalization, validation, and CIDR matching helpers.
   */
  interface EJSIPAddrAPI {
    /** Returns true for valid IPv4 or IPv6 address strings. */
    isValid(value: unknown): value is string;
    /** Returns true for strict dotted-decimal IPv4 strings. */
    isValidIPv4(value: unknown): value is string;
    /** Returns true for IPv6 strings, including embedded IPv4 tails and `%scope` suffixes. */
    isValidIPv6(value: unknown): value is string;
    /** Returns true for valid CIDR strings with an in-range prefix length. */
    isValidCIDR(value: unknown): value is string;
    /** Parses an address string or throws `TypeError` when invalid. */
    parse(value: string): EJSIPAddress;
    /** Parses a CIDR string or throws `TypeError` when invalid. */
    parseCIDR(value: string): EJSIPCIDR;
    /**
     * Tests whether `address` is inside `cidr`.
     *
     * `cidr` may be a CIDR string, a result from `parseCIDR`, or an object with
     * the minimal parsed CIDR shape described by `EJSIPCIDRLike`.
     */
    contains(cidr: string | EJSIPCIDRLike, address: string): boolean;
    /** Returns the canonical normalized address string. */
    normalize(value: string): string;
  }

  /**
   * Global IP address helper installed by `modules/stdlib/ipaddr`.
   */
  var EJSIPAddr: EJSIPAddrAPI;
}
