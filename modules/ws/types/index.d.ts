export {};

/**
 * API declarations for module `ws`.
 * The add-on installs the Web-facing bindings `globalThis.WebSocket`,
 * `globalThis.EJSWebSocket`, and `globalThis.EJSWebSocketError`.
 */

declare global {
  /** Ready-state values used by `WebSocket.readyState` and the constructor constants. */
  type EJSWebSocketReadyState = 0 | 1 | 2 | 3;

  /** Event names emitted by this WebSocket implementation. */
  type EJSWebSocketEventType = "open" | "message" | "error" | "close";

  /** The only supported `binaryType`; assigning any other value throws. */
  type EJSWebSocketBinaryType = "arraybuffer";

  /**
   * Error object shape used for websocket failures surfaced through
   * `onerror`, `addEventListener("error", ...)`, or the implementation
   * `_lastError` diagnostic field.
   */
  interface EJSWebSocketError extends Error {
    readonly name: "EJSWebSocketError";
    /** Stable provider-level error code mapped from native failures. */
    readonly code?:
      | "EINVAL"
      | "EPERM"
      | "ENOTSUP"
      | "ETIMEOUT"
      | "ENETWORK"
      | "ETLS"
      | "ECANCELLED"
      | "EINTERNAL";
    /** Module label used by the JS error shaper. */
    readonly module?: "ws";
    /** Operation active when the error was shaped. */
    readonly operation?: "connect" | "send" | "close" | "nextEvent" | "event";
    /** Native error domain when the provider includes one. */
    readonly nativeDomain?: string;
    /** Native error code when the provider includes one. */
    readonly nativeCode?: number;
  }

  /**
   * Base event payload for websocket callbacks.
   *
   * These are plain frozen objects created by the JS wrapper. They are not DOM
   * `Event` instances and do not expose browser event methods such as
   * `preventDefault()` or `stopPropagation()`.
   */
  interface WebSocketEventLike {
    readonly type: EJSWebSocketEventType;
    readonly target: WebSocket;
    readonly currentTarget: WebSocket;
  }

  /** `open` event payload. */
  interface WebSocketOpenEventLike extends WebSocketEventLike {
    readonly type: "open";
  }

  /**
   * `message` event payload. Text messages carry `string`; binary messages are
   * decoded to a new `ArrayBuffer` because only `binaryType = "arraybuffer"` is
   * supported.
   */
  interface WebSocketMessageEventLike extends WebSocketEventLike {
    readonly type: "message";
    readonly data: string | ArrayBuffer;
  }

  /**
   * `close` event payload.
   */
  interface WebSocketCloseEventLike extends WebSocketEventLike {
    readonly type: "close";
    readonly code: number;
    readonly reason: string;
    readonly wasClean: boolean;
  }

  /**
   * `error` event payload.
   */
  interface WebSocketErrorEventLike extends WebSocketEventLike {
    readonly type: "error";
    readonly error: EJSWebSocketError;
    readonly message: string;
  }

  /** Event map used by listener overloads. */
  interface EJSWebSocketEventMap {
    open: WebSocketOpenEventLike;
    message: WebSocketMessageEventLike;
    error: WebSocketErrorEventLike;
    close: WebSocketCloseEventLike;
  }

  /** Union of all WebSocket event payloads emitted by this module. */
  type EJSWebSocketEvent =
    | WebSocketOpenEventLike
    | WebSocketMessageEventLike
    | WebSocketErrorEventLike
    | WebSocketCloseEventLike;

  /** Function listeners are supported; EventListenerObject/options are ignored by the implementation. */
  type EJSWebSocketEventHandler<T extends EJSWebSocketEvent = EJSWebSocketEvent> =
    ((this: WebSocket, event: T) => void) | null;

  /**
   * WebSocket instance shape installed by `modules/ws`.
   *
   * The constructor validates `ws:`/`wss:` URLs, rejects URL fragments, accepts
   * either one protocol token or an array of protocol tokens, and rejects empty,
   * invalid, or case-insensitive duplicate protocols.
   */
  interface WebSocket {
    /** Instance constant matching `WebSocket.CONNECTING`. */
    readonly CONNECTING: 0;
    /** Instance constant matching `WebSocket.OPEN`. */
    readonly OPEN: 1;
    /** Instance constant matching `WebSocket.CLOSING`. */
    readonly CLOSING: 2;
    /** Instance constant matching `WebSocket.CLOSED`. */
    readonly CLOSED: 3;

    /** Normalized socket URL. */
    readonly url: string;
    /** Negotiated subprotocol, or `""` until open/no protocol. */
    readonly protocol: string;
    /** Current socket lifecycle state. */
    readonly readyState: EJSWebSocketReadyState;
    /** Present for browser API compatibility; this implementation keeps it at `0`. */
    readonly bufferedAmount: number;
    /** Only `"arraybuffer"` is supported; assigning `"blob"` or any other value throws. */
    binaryType: EJSWebSocketBinaryType;
    /** Last shaped websocket error, used by tests and diagnostics; `null` before the first error. */
    readonly _lastError: EJSWebSocketError | null;

    /** Called before `open` listeners when the native socket opens. */
    onopen: EJSWebSocketEventHandler<WebSocketOpenEventLike>;
    /** Called before `message` listeners with string or ArrayBuffer data. */
    onmessage: EJSWebSocketEventHandler<WebSocketMessageEventLike>;
    /** Called before `error` listeners with an `EJSWebSocketError`. */
    onerror: EJSWebSocketEventHandler<WebSocketErrorEventLike>;
    /** Called before `close` listeners; terminal close dispatch happens once. */
    onclose: EJSWebSocketEventHandler<WebSocketCloseEventLike>;

    /**
     * Send a text or binary message.
     *
     * Throws unless `readyState === WebSocket.OPEN`. Binary inputs may be an
     * `ArrayBuffer`, typed array, or `DataView`; the native provider receives a
     * copied byte buffer.
     */
    send(data: string | ArrayBuffer | ArrayBufferView): void;
    /**
     * Start closing the socket.
     *
     * `code` must be `1000` or in `3000..4999` when supplied. `reason` is
     * converted to UTF-8 and must not exceed 123 bytes. Repeated calls after
     * `CLOSING`/`CLOSED` are no-ops.
     */
    close(code?: number, reason?: string): void;
    /** Register a function listener for a supported WebSocket event. */
    addEventListener<K extends EJSWebSocketEventType>(
      type: K,
      listener: EJSWebSocketEventHandler<EJSWebSocketEventMap[K]>
    ): void;
    /** Unsupported event names and non-function listeners are ignored. */
    addEventListener(type: string, listener: EJSWebSocketEventHandler): void;
    /** Remove a previously registered function listener. */
    removeEventListener<K extends EJSWebSocketEventType>(
      type: K,
      listener: EJSWebSocketEventHandler<EJSWebSocketEventMap[K]>
    ): void;
    /** Unsupported event names and non-function listeners are ignored. */
    removeEventListener(type: string, listener: EJSWebSocketEventHandler): void;
  }

  /**
   * WebSocket constructor and constants.
   */
  var WebSocket: {
    readonly prototype: WebSocket;
    new (url: string, protocols?: string | readonly string[]): WebSocket;
    readonly CONNECTING: 0;
    readonly OPEN: 1;
    readonly CLOSING: 2;
    readonly CLOSED: 3;
  };

  /**
   * Frozen diagnostics object installed as `globalThis.EJSWebSocket`.
   */
  interface EJSWebSocketDiagnostics {
    /** Always `true` after the module has installed successfully. */
    readonly installed: true;
    /** Native module id used by the provider bridge. */
    readonly moduleID: "ejs.ws";
    /** Event names accepted by `addEventListener` and `removeEventListener`. */
    readonly events: readonly EJSWebSocketEventType[];
    /** Binary payload modes accepted by `binaryType`. */
    readonly supportedBinaryTypes: readonly EJSWebSocketBinaryType[];
  }

  /**
   * Module diagnostics binding.
   */
  var EJSWebSocket: EJSWebSocketDiagnostics;

  /**
   * Factory/constructor for websocket-specific error objects.
   */
  var EJSWebSocketError: {
    (message?: string): EJSWebSocketError;
    new(message?: string): EJSWebSocketError;
  };
}
