export {};

/**
 * API declarations for module `stdlib`.
 * Utility APIs exposed as `globalThis.EJSHashing`, `globalThis.EJSIPAddr`, and `globalThis.EJSUUID`.
 */

declare global {
  /**
   * Algorithm options for digest helpers.
   */
  interface EJSHashingOptions {
    encoding?: "hex" | "base64";
  }

  /**
   * Hash utility global.
   */
  var EJSHashing: {
    digest(algorithm: "sha256" | "sha512", data: string | ArrayBuffer | ArrayBufferView, options?: EJSHashingOptions): Promise<string>;
    sha256(data: string | ArrayBuffer | ArrayBufferView, options?: EJSHashingOptions): Promise<string>;
    sha512(data: string | ArrayBuffer | ArrayBufferView, options?: EJSHashingOptions): Promise<string>;
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
   * CIDR extended address details.
   */
  interface EJSIPCIDR extends EJSIPAddress {
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
    contains(cidr: string | EJSIPCIDR, address: string): boolean;
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
