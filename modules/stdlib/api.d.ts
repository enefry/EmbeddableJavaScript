export {};

/**
 * API declarations for module `stdlib`.
 * Utility APIs exposed as `globalThis.EJSHashing`, `globalThis.EJSIPAddr`, and `globalThis.EJSUUID`.
 */

declare global {
  /**
   * Output encoding for digest helpers.
   */
  type EJSHashingEncoding = "hex" | "base64";

  interface EJSHashingOptions {
    /**
     * Omitted or `null` encoding defaults to `hex`.
     */
    encoding?: EJSHashingEncoding | null;
  }

  /**
   * Data accepted by hashing helpers.
   */
  type EJSHashingData = string | ArrayBuffer | ArrayBufferView;

  /**
   * Hash utility global.
   */
  var EJSHashing: {
    digest(algorithm: "sha256" | "sha512", data: EJSHashingData, options?: EJSHashingOptions | null): Promise<string>;
    sha256(data: EJSHashingData, options?: EJSHashingOptions | null): Promise<string>;
    sha512(data: EJSHashingData, options?: EJSHashingOptions | null): Promise<string>;
  };

  /**
   * Parsed IP address details.
   */
  interface EJSIPAddress {
    readonly address: string;
    readonly family: 4 | 6;
    readonly normalized: string;
    readonly bytes: readonly number[];
    readonly scopeId?: string;
  }

  /**
   * Minimal object shape accepted by `EJSIPAddr.contains`.
   */
  interface EJSIPCIDRLike {
    readonly family: 4 | 6;
    readonly prefixLength: number;
    readonly bytes: readonly number[];
  }

  /**
   * CIDR extended address details.
   */
  interface EJSIPCIDR extends EJSIPCIDRLike {
    readonly address: string;
    readonly normalized: string;
    readonly prefixLength: number;
  }

  /**
   * IP address parsing and validation API.
   */
  interface EJSIPAddrAPI {
    isValid(value: unknown): value is string;
    isValidIPv4(value: unknown): value is string;
    isValidIPv6(value: unknown): value is string;
    isValidCIDR(value: unknown): value is string;
    parse(value: string): EJSIPAddress;
    parseCIDR(value: string): EJSIPCIDR;
    contains(cidr: string | EJSIPCIDRLike, address: string): boolean;
    normalize(value: string): string;
  }

  /**
   * IP address parsing global.
   */
  var EJSIPAddr: EJSIPAddrAPI;

  /**
   * UUID helpers.
   */
  var EJSUUID: {
    v4(): Promise<string>;
    randomUUID(): Promise<string>;
    validate(value: unknown): boolean;
  };
}
