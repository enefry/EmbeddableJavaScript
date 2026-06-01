export {};

/**
 * API declarations for module `worker`.
 * Worker runtime API exposed as `globalThis.Worker`, `globalThis.EJSWorker` and worker scope globals.
 * Runtime shape is aligned with `modules/worker/js` implementation bindings.
 */

declare global {
  /** Worker script execution mode accepted by the JS wrapper and Apple provider. */
  type EJSWorkerType = "classic" | "module";

  /**
   * Options accepted by `new Worker(specifier, options)`.
   *
   * `root` and `type` apply to direct path resolution. Named `scripts` and
   * `inlineScripts` from the host `ejs.worker` configuration use the policy
   * selected for that name. `name` is diagnostics-only and is returned to the
   * native worker instance; it does not change the worker global scope.
   */
  interface EJSWorkerOptions {
    /** Configured root name used when resolving direct worker script paths. */
    root?: string;
    /** Direct worker script execution mode; defaults to `"classic"`. */
    type?: EJSWorkerType;
    /** Optional diagnostics name for the worker instance. */
    name?: string;
  }

  /**
   * Values that this worker module can serialize through `postMessage`.
   *
   * This is a deliberately smaller subset than browser structured clone:
   * finite numbers, booleans, strings, null, undefined, arrays, plain objects,
   * ArrayBuffer, and ArrayBuffer views. Functions, symbols, bigint primitives,
   * Date, Map, Set, RegExp, Error objects, SharedArrayBuffer, non-finite
   * numbers, cyclic graphs, and non-plain objects throw at runtime.
   */
  type EJSWorkerMessageValue =
    | null
    | undefined
    | boolean
    | string
    | number
    | ArrayBuffer
    | ArrayBufferView
    | EJSWorkerMessageValue[]
    | { [key: string]: EJSWorkerMessageValue };

  /**
   * Transfer entries accepted by worker message APIs.
   *
   * Every transferred buffer must also appear somewhere inside the message
   * value. Duplicate buffers and SharedArrayBuffer-backed entries throw.
   */
  type EJSWorkerTransfer = ArrayBuffer | ArrayBufferView;

  /** Events emitted by parent-side Worker instances. */
  type EJSWorkerParentEventType = "message" | "error" | "messageerror";

  /** Events supported by the worker child global scope. */
  type EJSWorkerScopeEventType =
    | EJSWorkerParentEventType
    | "unhandledrejection"
    | "rejectionhandled";

  /** Event names supported across the parent Worker and child worker scope. */
  type EJSWorkerEventType = EJSWorkerScopeEventType;

  /** Common shape for synthetic worker events emitted by this module. */
  interface EJSWorkerBaseEvent {
    /** Event type. */
    type: EJSWorkerEventType;
    /** Dispatch target: parent Worker instance or child global scope. */
    target: Worker | typeof globalThis;
    /** Current dispatch target: parent Worker instance or child global scope. */
    currentTarget: Worker | typeof globalThis;
  }

  /** `message` event carrying a decoded worker message value. */
  interface EJSWorkerMessageEvent<T = EJSWorkerMessageValue> extends EJSWorkerBaseEvent {
    type: "message";
    data: T;
  }

  /** `error` event reported by worker startup, native dispatch, or child errors. */
  interface EJSWorkerErrorEvent extends EJSWorkerBaseEvent {
    type: "error";
    /** Error text. */
    message: string;
    /** Script filename when reported by the runtime; otherwise an empty string or absent. */
    filename?: string;
    /** Stack string when available. */
    stack?: string;
    /** Wrapped JS error or native error payload. */
    error?: unknown;
  }

  /** `messageerror` event emitted when message serialization/deserialization fails. */
  interface EJSWorkerMessageErrorEvent extends EJSWorkerBaseEvent {
    type: "messageerror";
    /** Serialization or deserialization error text. */
    message?: string;
    /** Original serialization or deserialization error. */
    error?: unknown;
  }

  /** Promise rejection event emitted only inside the child worker global scope. */
  interface EJSWorkerPromiseRejectionEvent extends EJSWorkerBaseEvent {
    type: "unhandledrejection" | "rejectionhandled";
    /** Promise instance passed by the runtime rejection tracker. */
    promise: Promise<unknown>;
    /** Rejection reason passed by the runtime rejection tracker. */
    reason: unknown;
    /** `true` only for `unhandledrejection`; `false` for `rejectionhandled`. */
    cancelable: boolean;
    /** Set by `preventDefault()` when the event is cancelable. */
    defaultPrevented: boolean;
    /** Suppresses native error reporting for cancelable unhandled rejections. */
    preventDefault(): void;
  }

  /** Union of worker events produced by this module. */
  type EJSWorkerEvent<T = EJSWorkerMessageValue> =
    | EJSWorkerMessageEvent<T>
    | EJSWorkerErrorEvent
    | EJSWorkerMessageErrorEvent
    | EJSWorkerPromiseRejectionEvent;

  /** Generic event handler type for worker callbacks. */
  type EJSWorkerEventHandler<T extends EJSWorkerEvent = EJSWorkerEvent> = (event: T) => void;

  /** Parent-side Worker object created by `new Worker(...)`. */
  interface Worker {
    /** Receives messages sent from the child worker via child `postMessage()`. */
    onmessage: EJSWorkerEventHandler<EJSWorkerMessageEvent> | null;
    /** Receives startup, native dispatch, and child-reported errors. */
    onerror: EJSWorkerEventHandler<EJSWorkerErrorEvent> | null;
    /** Receives local or inbound message serialization failures. */
    onmessageerror: EJSWorkerEventHandler<EJSWorkerMessageErrorEvent> | null;
    /**
     * Queue a message to the child worker.
     *
     * Calls made during startup are queued up to the configured
     * `maxQueuedMessages`. Calls after `terminate()` or child `close()` throw.
     * Transferable ArrayBuffers are detached synchronously when supported.
     */
    postMessage(value: EJSWorkerMessageValue, transferList?: Iterable<EJSWorkerTransfer>): void;
    /** Request worker shutdown; repeated calls are no-ops. */
    terminate(): void;
    /** Register a parent-side message listener. */
    addEventListener(type: "message", handler: EJSWorkerEventHandler<EJSWorkerMessageEvent>): void;
    /** Register a parent-side error listener. */
    addEventListener(type: "error", handler: EJSWorkerEventHandler<EJSWorkerErrorEvent>): void;
    /** Register a parent-side message serialization/deserialization listener. */
    addEventListener(type: "messageerror", handler: EJSWorkerEventHandler<EJSWorkerMessageErrorEvent>): void;
    /** Unsupported event names are ignored; non-function handlers throw. */
    addEventListener(type: string, handler: EJSWorkerEventHandler): void;
    /** Remove a previously registered parent-side message listener. */
    removeEventListener(type: "message", handler: EJSWorkerEventHandler<EJSWorkerMessageEvent>): void;
    /** Remove a previously registered parent-side error listener. */
    removeEventListener(type: "error", handler: EJSWorkerEventHandler<EJSWorkerErrorEvent>): void;
    /** Remove a previously registered parent-side message error listener. */
    removeEventListener(type: "messageerror", handler: EJSWorkerEventHandler<EJSWorkerMessageErrorEvent>): void;
    /** Unsupported event names and non-function handlers are ignored. */
    removeEventListener(type: string, handler: EJSWorkerEventHandler): void;
  }

  /** Constructor for spawning a configured worker instance. */
  var Worker: {
    prototype: Worker;
    new(specifier: string, options?: EJSWorkerOptions): Worker;
  };

  /** Worker child global `self`; the wrapper ensures `self === globalThis`. */
  var self: typeof globalThis;

  /** Child worker global `message` handler. */
  var onmessage: EJSWorkerEventHandler<EJSWorkerMessageEvent> | null;
  /** Child worker global `error` handler. */
  var onerror: EJSWorkerEventHandler<EJSWorkerErrorEvent> | null;
  /** Child worker global `messageerror` handler. */
  var onmessageerror: EJSWorkerEventHandler<EJSWorkerMessageErrorEvent> | null;
  /** Child worker global `unhandledrejection` handler. */
  var onunhandledrejection: EJSWorkerEventHandler<EJSWorkerPromiseRejectionEvent> | null;
  /** Child worker global `rejectionhandled` handler. */
  var onrejectionhandled: EJSWorkerEventHandler<EJSWorkerPromiseRejectionEvent> | null;

  /**
   * Send a message from the child worker global scope to the parent Worker.
   *
   * Calls after `close()` throw. Transferable ArrayBuffers are detached
   * synchronously when supported.
   */
  function postMessage(value: EJSWorkerMessageValue, transferList?: Iterable<EJSWorkerTransfer>): void;
  /** Close the current child worker global scope; queued outgoing messages flush before native close. */
  function close(): void;

  /** Register a child-scope message listener. */
  function addEventListener(type: "message", handler: EJSWorkerEventHandler<EJSWorkerMessageEvent>): void;
  /** Register a child-scope error listener. */
  function addEventListener(type: "error", handler: EJSWorkerEventHandler<EJSWorkerErrorEvent>): void;
  /** Register a child-scope message serialization/deserialization listener. */
  function addEventListener(type: "messageerror", handler: EJSWorkerEventHandler<EJSWorkerMessageErrorEvent>): void;
  /** Register a child-scope promise rejection listener. */
  function addEventListener(
    type: "unhandledrejection" | "rejectionhandled",
    handler: EJSWorkerEventHandler<EJSWorkerPromiseRejectionEvent>
  ): void;
  /** Unsupported event names are ignored; non-function handlers throw. */
  function addEventListener(type: string, handler: EJSWorkerEventHandler): void;
  /** Remove a child-scope message listener. */
  function removeEventListener(type: "message", handler: EJSWorkerEventHandler<EJSWorkerMessageEvent>): void;
  /** Remove a child-scope error listener. */
  function removeEventListener(type: "error", handler: EJSWorkerEventHandler<EJSWorkerErrorEvent>): void;
  /** Remove a child-scope message error listener. */
  function removeEventListener(type: "messageerror", handler: EJSWorkerEventHandler<EJSWorkerMessageErrorEvent>): void;
  /** Remove a child-scope promise rejection listener. */
  function removeEventListener(
    type: "unhandledrejection" | "rejectionhandled",
    handler: EJSWorkerEventHandler<EJSWorkerPromiseRejectionEvent>
  ): void;
  /** Unsupported event names and non-function handlers are ignored. */
  function removeEventListener(type: string, handler: EJSWorkerEventHandler): void;

  /** Read-only metadata object installed with the worker add-on. */
  interface EJSWorkerMetadata {
    /** Native module id used by this add-on. */
    readonly moduleID: "ejs.worker";
    /** JS wrapper API version. */
    readonly version: 1;
  }

  /** Module metadata for worker add-on. */
  var EJSWorker: EJSWorkerMetadata;
}
