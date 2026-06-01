/**
 * API declarations for module `kv`.
 * Persistent key-value API exposed as `globalThis.EJSKV` and `globalThis.EJSStorage`.
 *
 * Installing this module does not install browser `localStorage` or
 * `sessionStorage` globals. `EJSStorage` is the asynchronous storage facade
 * bundled with `EJSKV`.
 */

export interface EJSKVOptions {
  /**
   * Optional non-empty store name from the native KV policy.
   *
   * When omitted, operations target the policy `defaultStore`. Unknown stores,
   * stores without the required read/write permission, or stores blocked by
   * policy limits reject at runtime.
   */
  store?: string;
}

/**
 * Storage options type used by `EJSStorage` helper methods.
 */
export type EJSStorageOptions = EJSKVOptions;

/**
 * Binary or textual value accepted by `EJSKV.set`.
 *
 * Strings are UTF-8 encoded in JavaScript. `ArrayBufferView` includes typed
 * arrays and `DataView`; views are stored using the view's byte range.
 */
export type EJSKVValue = string | ArrayBuffer | ArrayBufferView;

/**
 * Raw key/value facade exposed as `EJSKV`.
 */
export interface EJSKVGlobal {
  /**
   * Read raw bytes for a non-empty string key.
   *
   * Resolves to `null` when the key is absent. The provider may reject when the
   * selected store is not readable or a stored value exceeds configured limits.
   */
  get(key: string, options?: EJSKVOptions): Promise<ArrayBuffer | null>;

  /**
   * Store raw bytes for a non-empty string key.
   *
   * The value must be a string, `ArrayBuffer`, or `ArrayBufferView`; other
   * values throw before reaching the native provider.
   */
  set(key: string, value: EJSKVValue, options?: EJSKVOptions): Promise<void>;

  /**
   * Delete a key and resolve whether an entry was removed.
   */
  delete(key: string, options?: EJSKVOptions): Promise<boolean>;

  /**
   * Resolve whether a key exists.
   */
  has(key: string, options?: EJSKVOptions): Promise<boolean>;

  /**
   * List keys in the selected store.
   *
   * The Apple provider returns lexicographically sorted keys and rejects when
   * the key count exceeds `maxKeysPerList`.
   */
  keys(options?: EJSKVOptions): Promise<string[]>;

  /**
   * Remove every entry from the selected store.
   */
  clear(options?: EJSKVOptions): Promise<void>;

  /**
   * Read a UTF-8 JSON value and parse it with `JSON.parse`.
   *
   * Resolves to `null` when the key is absent. Invalid JSON rejects.
   */
  getJSON<T = unknown>(key: string, options?: EJSKVOptions): Promise<T | null>;

  /**
   * Serialize a value with `JSON.stringify` and store the resulting UTF-8 text.
   *
   * Values that `JSON.stringify` cannot serialize to a string reject.
   */
  setJSON(key: string, value: unknown, options?: EJSKVOptions): Promise<void>;
}

/**
 * Asynchronous `localStorage`-style facade backed by `EJSKV`.
 *
 * Keys and values are coerced with `String(...)` before storage, matching the
 * JavaScript implementation rather than the stricter `EJSKV` key/value types.
 */
export interface EJSStorageLocal {
  /**
   * Count keys in the selected store.
   */
  length(options?: EJSStorageOptions): Promise<number>;

  /**
   * Return the key at `Math.floor(Number(index))`, or `null` for negative,
   * non-finite, or out-of-range indexes.
   */
  key(index: unknown, options?: EJSStorageOptions): Promise<string | null>;

  /**
   * Read a string value for `String(key)`, or `null` when absent.
   */
  getItem(key: unknown, options?: EJSStorageOptions): Promise<string | null>;

  /**
   * Store `String(value)` under `String(key)`.
   */
  setItem(key: unknown, value: unknown, options?: EJSStorageOptions): Promise<void>;

  /**
   * Delete `String(key)`. The boolean delete result from `EJSKV` is ignored.
   */
  removeItem(key: unknown, options?: EJSStorageOptions): Promise<void>;

  /**
   * Remove every entry from the selected store.
   */
  clear(options?: EJSStorageOptions): Promise<void>;
}

/**
 * JSON convenience facade over `EJSKV` using the same key coercion as
 * `EJSStorage.local`.
 */
export interface EJSStorageJSON {
  /**
   * Read `String(key)` and parse the UTF-8 JSON value, or resolve to `null`
   * when absent.
   */
  get<T = unknown>(key: unknown, options?: EJSStorageOptions): Promise<T | null>;

  /**
   * Serialize `value` with `JSON.stringify` and store it under `String(key)`.
   */
  set(key: unknown, value: unknown, options?: EJSStorageOptions): Promise<void>;

  /**
   * Delete `String(key)`. The boolean delete result from `EJSKV` is ignored.
   */
  remove(key: unknown, options?: EJSStorageOptions): Promise<void>;
}

/**
 * Top-level asynchronous storage facade object.
 */
export interface EJSStorageGlobal {
  local: EJSStorageLocal;
  json: EJSStorageJSON;
}

/**
 * Global bindings installed by the `kv` module.
 */
export {};

declare global {
  /**
   * Raw key-value global binding.
   */
  const EJSKV: EJSKVGlobal;
  /**
   * JavaScript storage facade binding. Only `local` and `json` are installed;
   * there is no separate session storage facade.
   */
  const EJSStorage: EJSStorageGlobal;
}
