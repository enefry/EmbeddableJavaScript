export {};

/**
 * API declarations for module `stdlib/uuid`.
 *
 * Installing the module exposes the web-facing `globalThis.EJSUUID` helper.
 * Apple installer and testing hooks are platform-private and intentionally not
 * declared here.
 */

declare global {
  /**
   * Global UUID helper installed by `modules/stdlib/uuid`.
   */
  var EJSUUID: {
    /**
     * Generates an RFC 4122 version-4 UUID string.
     *
     * The JavaScript facade dispatches to the native `ejs.uuid` provider, so the
     * result is delivered asynchronously.
     */
    v4(): Promise<string>;

    /**
     * Alias for `v4()`.
     *
     * This is Promise-based like `v4()`, unlike the synchronous Web Crypto
     * `crypto.randomUUID()` API.
     */
    randomUUID(): Promise<string>;

    /**
     * Returns true when `value` is a canonical hyphenated UUID string.
     *
     * Validation is synchronous and accepts any input. Matching is
     * case-insensitive, requires an RFC 4122 variant nibble, and accepts UUID
     * versions 1 through 5.
     */
    validate(value: unknown): boolean;
  };
}
