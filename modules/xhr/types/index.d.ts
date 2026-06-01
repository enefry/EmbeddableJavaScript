export {};

/**
 * API declarations for module `xhr`.
 * Declares the JS-visible XMLHttpRequest add-on installed as
 * `globalThis.XMLHttpRequest`, `globalThis.EJSXHR`, and
 * `globalThis.EJSXHRError`.
 */

declare global {

  /**
   * JSON value supported as `response` under `responseType: "json"`.
   */
  type EJSXHRJSONValue =
    | string
    | number
    | boolean
    | null
    | { [key: string]: EJSXHRJSONValue }
    | EJSXHRJSONValue[];

  /**
   * Supported `XMLHttpRequest.responseType` values.
   */
  type EJSXHRResponseType = "" | "text" | "arraybuffer" | "json";

  /**
   * Ready-state constants exposed on the constructor and each instance.
   */
  type EJSXHRReadyState = 0 | 1 | 2 | 3 | 4;

  /**
   * Request body values accepted by `send()`.
   *
   * Strings are sent as UTF-8 text. ArrayBuffer and ArrayBufferView values are
   * passed through the native transfer-buffer path. Other Web body types such
   * as Blob, FormData, URLSearchParams, streams, and Document are not accepted.
   */
  type EJSXHRBodyInit = string | ArrayBuffer | ArrayBufferView | null;

  /**
   * Event names emitted by XMLHttpRequest instances. The implementation ignores
   * unknown event names instead of registering listeners for them.
   */
  type EJSXHREventType =
    | "readystatechange"
    | "loadstart"
    | "progress"
    | "load"
    | "error"
    | "abort"
    | "timeout"
    | "loadend";

  /**
   * String codes used on `xhr._lastError` for terminal native/provider failures.
   */
  type EJSXHRErrorCode =
    | "EINVAL"
    | "ECANCELLED"
    | "ENETWORK"
    | "ETLS"
    | "ETIMEOUT"
    | "ENOTSUP"
    | "EPERM"
    | "EINTERNAL";

  /**
   * Error object shape exposed by `EJSXHRError()` and by `xhr._lastError`.
   *
   * Provider-backed failures add `code`, `module`, `operation`, and optional
   * native diagnostics. Errors constructed directly with `EJSXHRError()` only
   * guarantee the `Error` fields plus `name`.
   */
  interface EJSXHRError extends Error {
    readonly name: "EJSXHRError";
    readonly code?: EJSXHRErrorCode;
    readonly module?: "xhr";
    readonly operation?: "send";
    readonly nativeDomain?: string;
    readonly nativeCode?: number;
  }

  /**
   * Frozen module diagnostics object installed as `globalThis.EJSXHR`.
   *
   * This object reports only JS-facing module metadata; native provider
   * configuration such as `ejs.network` policy is intentionally not exposed.
   */
  interface EJSXHRDiagnostics {
    readonly installed: true;
    readonly moduleID: "ejs.xhr";
    readonly supportedResponseTypes: readonly ["", "text", "arraybuffer", "json"];
    readonly events: readonly [
      "readystatechange",
      "loadstart",
      "progress",
      "load",
      "error",
      "abort",
      "timeout",
      "loadend"
    ];
  }

  /**
   * Base event payload for XHR callbacks.
   *
   * XHR events are frozen plain objects with `type`, `target`, and
   * `currentTarget`; they are not DOM `Event` instances and do not expose
   * browser event methods such as `preventDefault()` or `stopPropagation()`.
   */
  interface XMLHttpRequestEventLike<TType extends EJSXHREventType = EJSXHREventType> {
    readonly type: TType;
    readonly target: XMLHttpRequest;
    readonly currentTarget: XMLHttpRequest;
  }

  /**
   * Progress payload for XHR `progress` events.
   *
   * One `progress` event is dispatched after headers are received and while
   * `readyState === LOADING`. `total` is zero when `lengthComputable` is false.
   */
  interface XMLHttpRequestProgressEventLike extends XMLHttpRequestEventLike<"progress"> {
    readonly loaded: number;
    readonly total: number;
    readonly lengthComputable: boolean;
  }

  type EJSXHREventHandler<TEvent extends XMLHttpRequestEventLike> =
    ((this: XMLHttpRequest, event: TEvent) => void) | null;

  type EJSXHRListener<TEvent extends XMLHttpRequestEventLike> =
    (this: XMLHttpRequest, event: TEvent) => void;

  /**
   * XMLHttpRequest binding installed by `modules/xhr`.
   *
   * The implementation is intentionally smaller than browser XHR: requests are
   * async-only, upload progress is not modeled, XML/document responses are not
   * parsed, and cookies/CORS/browser cache semantics are not provided.
   */
  interface XMLHttpRequest {
    readonly UNSENT: 0;
    readonly OPENED: 1;
    readonly HEADERS_RECEIVED: 2;
    readonly LOADING: 3;
    readonly DONE: 4;

    readonly readyState: EJSXHRReadyState;
    readonly status: number;
    readonly statusText: string;
    readonly responseURL: string;
    /**
     * Text response body. This is the decoded UTF-8 response for `""`, `"text"`,
     * and `"json"` response types, and an empty string for `"arraybuffer"`.
     */
    readonly responseText: string;
    /**
     * Final response value. `""` and `"text"` produce a string, `"json"`
     * produces the parsed JSON value, and `"arraybuffer"` produces an
     * ArrayBuffer.
     */
    readonly response: string | ArrayBuffer | EJSXHRJSONValue;
    /**
     * Per-request timeout in milliseconds. Non-positive and non-finite values
     * behave as no JS-level override and the native policy timeout is used.
     */
    timeout: number;
    /**
     * Supported response types are `""`, `"text"`, `"arraybuffer"`, and
     * `"json"`. Assigning any other value throws a TypeError synchronously.
     */
    responseType: EJSXHRResponseType;
    /**
     * Last terminal request failure. This non-standard diagnostic slot is reset
     * by `open()` and set for native/provider failures and JSON parse failures.
     */
    readonly _lastError: EJSXHRError | null;

    onreadystatechange: EJSXHREventHandler<XMLHttpRequestEventLike<"readystatechange">>;
    onloadstart: EJSXHREventHandler<XMLHttpRequestEventLike<"loadstart">>;
    onprogress: EJSXHREventHandler<XMLHttpRequestProgressEventLike>;
    onload: EJSXHREventHandler<XMLHttpRequestEventLike<"load">>;
    onerror: EJSXHREventHandler<XMLHttpRequestEventLike<"error">>;
    onabort: EJSXHREventHandler<XMLHttpRequestEventLike<"abort">>;
    ontimeout: EJSXHREventHandler<XMLHttpRequestEventLike<"timeout">>;
    onloadend: EJSXHREventHandler<XMLHttpRequestEventLike<"loadend">>;

    /**
     * Opens a request. Passing `false` for `async` throws because synchronous
     * XHR is not implemented.
     */
    open(method: string, url: string, async?: true): void;
    /**
     * Sets a request header while the request is OPENED and not yet sent.
     * Duplicate names are combined with `", "`. Invalid token names or values
     * containing CR/LF throw synchronously; forbidden header names are rejected
     * by the native provider during `send()`.
     */
    setRequestHeader(name: string, value: string): void;
    /**
     * Starts the async request. Errors are delivered through terminal events and
     * `xhr._lastError`; `send()` itself does not return a Promise.
     */
    send(body?: EJSXHRBodyInit): void;
    /**
     * Cancels an active request. Active requests dispatch `abort` then
     * `loadend`; aborting an opened but unsent request only resets state.
     */
    abort(): void;
    getResponseHeader(name: string): string | null;
    getAllResponseHeaders(): string;
    addEventListener(
      type: "progress",
      listener: EJSXHRListener<XMLHttpRequestProgressEventLike> | null,
      options?: unknown
    ): void;
    addEventListener<TType extends Exclude<EJSXHREventType, "progress">>(
      type: TType,
      listener: EJSXHRListener<XMLHttpRequestEventLike<TType>> | null,
      options?: unknown
    ): void;
    addEventListener(
      type: string,
      listener: EJSXHRListener<XMLHttpRequestEventLike> | null,
      options?: unknown
    ): void;
    removeEventListener(
      type: "progress",
      listener: EJSXHRListener<XMLHttpRequestProgressEventLike> | null,
      options?: unknown
    ): void;
    removeEventListener<TType extends Exclude<EJSXHREventType, "progress">>(
      type: TType,
      listener: EJSXHRListener<XMLHttpRequestEventLike<TType>> | null,
      options?: unknown
    ): void;
    removeEventListener(
      type: string,
      listener: EJSXHRListener<XMLHttpRequestEventLike> | null,
      options?: unknown
    ): void;
  }

  /**
   * XMLHttpRequest constructor and lifecycle constants.
   */
  var XMLHttpRequest: {
    new (): XMLHttpRequest;
    readonly UNSENT: 0;
    readonly OPENED: 1;
    readonly HEADERS_RECEIVED: 2;
    readonly LOADING: 3;
    readonly DONE: 4;
  };

  /**
   * Module diagnostics binding.
   */
  var EJSXHR: EJSXHRDiagnostics;

  /**
   * Constructor/function for XHR runtime errors.
   *
   * The JS implementation returns an Error object named `EJSXHRError`; it can
   * be called with or without `new`.
   */
  var EJSXHRError: {
    (message?: string): EJSXHRError;
    new(message?: string): EJSXHRError;
  };
}
