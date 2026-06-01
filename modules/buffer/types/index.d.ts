export {};

/**
 * API declarations for module `buffer`.
 * Pure JavaScript binary helper API exposed as `globalThis.EJSBinary`.
 */

/**
 * Byte input accepted by `EJSBinary` methods.
 *
 * Runtime accepts an `ArrayBuffer` or any `ArrayBufferView`, including typed
 * arrays and `DataView`. Views are read from their visible byte range using
 * `byteOffset` and `byteLength`.
 */
export type EJSBinaryInput = ArrayBuffer | ArrayBufferView;

/**
 * Encoding labels recognized after lowercasing.
 */
export type EJSBinaryEncoding = "utf8" | "utf-8" | "base64" | "hex";

/**
 * Encoding argument accepted by conversion helpers.
 *
 * `null` and `undefined` select `utf8`. Other values are coerced with
 * `String(...)` and lowercased at runtime; unsupported labels throw a
 * `TypeError`.
 */
export type EJSBinaryEncodingInput = EJSBinaryEncoding | (string & {}) | null;

/**
 * Global binary helper object installed by `modules/buffer`.
 */
export interface EJSBinaryGlobal {
  /**
   * Converts `value` to bytes using the selected encoding.
   *
   * For `utf8`/`utf-8`, `value` is coerced with `String(value)` before UTF-8
   * encoding. For `base64` and `hex`, this delegates to `fromBase64` and
   * `fromHex`.
   */
  fromString(value: unknown, encoding?: EJSBinaryEncodingInput): Uint8Array;

  /**
   * Converts bytes to a JavaScript string using the selected encoding.
   *
   * Defaults to UTF-8. `base64` and `hex` return encoded text rather than
   * decoded Unicode.
   */
  toString(bytes: EJSBinaryInput, encoding?: EJSBinaryEncodingInput): string;

  /**
   * Decodes base64 text into bytes.
   *
   * Input is coerced with `String(value)`, JavaScript whitespace is ignored,
   * and missing padding is accepted when the remaining length is valid. Invalid
   * length, characters, or padding throw a `TypeError`.
   */
  fromBase64(value: unknown): Uint8Array;

  /**
   * Encodes bytes as padded base64 text.
   */
  toBase64(bytes: EJSBinaryInput): string;

  /**
   * Decodes hexadecimal text into bytes.
   *
   * Input is coerced with `String(value)`, JavaScript whitespace is ignored,
   * and the remaining length must be even. Invalid length or characters throw
   * a `TypeError`.
   */
  fromHex(value: unknown): Uint8Array;

  /**
   * Encodes bytes as lowercase hexadecimal text.
   */
  toHex(bytes: EJSBinaryInput): string;

  /**
   * Concatenates an array of byte inputs into a new `Uint8Array`.
   *
   * Runtime requires an actual array; generic iterables and array-like objects
   * are rejected.
   */
  concat(chunks: readonly EJSBinaryInput[]): Uint8Array;

  /**
   * Returns true when both byte inputs contain exactly the same bytes.
   */
  equals(a: EJSBinaryInput, b: EJSBinaryInput): boolean;

  /**
   * Lexicographically compares two byte inputs.
   */
  compare(a: EJSBinaryInput, b: EJSBinaryInput): -1 | 0 | 1;
}

declare global {

  /**
   * Global `EJSBinary` helpers installed by the optional `buffer` module.
   */
  var EJSBinary: EJSBinaryGlobal;
}
