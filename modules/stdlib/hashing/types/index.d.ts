export {};

/**
 * API declarations for module `stdlib/hashing`.
 *
 * The module installs the web-facing `globalThis.EJSHashing` helper. Native
 * provider installation functions are intentionally not part of this surface.
 */

declare global {
  /**
   * Hash algorithms supported by `EJSHashing.digest`.
   *
   * Typed callers should use the canonical lowercase names; the JavaScript
   * wrapper normalizes runtime string values before dispatch.
   */
  type EJSHashingAlgorithm = "sha256" | "sha512";

  /**
   * Encoded string format returned by hashing helpers.
   *
   * `hex` is the default when no encoding is supplied. The JavaScript wrapper
   * normalizes runtime string values before validation.
   */
  type EJSHashingEncoding = "hex" | "base64";

  /**
   * Data accepted by hashing helpers.
   *
   * Strings are encoded as UTF-8 by the JavaScript wrapper before hashing.
   * `ArrayBufferView` inputs use the view's current byte range.
   */
  type EJSHashingData = string | ArrayBuffer | ArrayBufferView;

  /**
   * Options for one-shot digest helpers.
   */
  interface EJSHashingOptions {
    /**
     * Output encoding for the returned digest string. Omitted or null encoding
     * defaults to `hex`.
     */
    encoding?: EJSHashingEncoding | null;
  }

  /**
   * One-shot hashing helpers backed by the optional `stdlib/hashing` module.
   */
  var EJSHashing: {
    /**
     * Hashes `data` with a supported algorithm and returns an encoded digest.
     *
     * Unsupported algorithms reject through the native provider. Unsupported
     * encodings or data types reject before dispatch.
     */
    digest(algorithm: EJSHashingAlgorithm, data: EJSHashingData, options?: EJSHashingOptions | null): Promise<string>;

    /**
     * Hashes `data` with SHA-256 and returns an encoded digest string.
     */
    sha256(data: EJSHashingData, options?: EJSHashingOptions | null): Promise<string>;

    /**
     * Hashes `data` with SHA-512 and returns an encoded digest string.
     */
    sha512(data: EJSHashingData, options?: EJSHashingOptions | null): Promise<string>;
  };
}
