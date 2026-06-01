export {};

/**
 * API declarations for module `wintertc`.
 * Web-compatible globals and helpers exposed by the WinterTC module.
 * Runtime shape is aligned with `modules/wintertc/js` implementation bindings.
 */

declare global {
  // WinterTC Diagnostics

  /**
   * Runtime global binding for WinterTC.
   */
  var WinterTC: {
    readonly version: string;
    readonly apis: readonly string[];
    readonly loaded: boolean;
  };

  // Timers

  /**
   * Runtime function provided by the wintertc API.
   */
  function setTimeout(callback: (...args: any[]) => void, delay?: number, ...args: any[]): any;

  /**
   * Runtime function provided by the wintertc API.
   */
  function clearTimeout(id: any): void;

  /**
   * Runtime function provided by the wintertc API.
   */
  function setInterval(callback: (...args: any[]) => void, delay?: number, ...args: any[]): any;

  /**
   * Runtime function provided by the wintertc API.
   */
  function clearInterval(id: any): void;

  /**
   * Runtime function provided by the wintertc API.
   */
  function queueMicrotask(callback: () => void): void;

  // URL API

  /**
   * Class type used by the wintertc API.
   */
  class URLSearchParams {
    constructor(init?: string | string[][] | Record<string, string> | URLSearchParams);
    append(name: string, value: string): void;
    delete(name: string): void;
    get(name: string): string | null;
    getAll(name: string): string[];
    has(name: string): boolean;
    set(name: string, value: string): void;
    forEach(callback: (value: string, key: string, parent: URLSearchParams) => void, thisArg?: any): void;
    toString(): string;
    [Symbol.iterator](): IterableIterator<[string, string]>;
    entries(): IterableIterator<[string, string]>;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
  }

  class URL {
    constructor(url: string, base?: string | URL);
    hash: string;
    host: string;
    hostname: string;
    href: string;
    readonly origin: string;
    pathname: string;
    port: string;
    protocol: string;
    search: string;
    readonly searchParams: URLSearchParams;
    toString(): string;
    toJSON(): string;
  }

  // Events API

  /**
   * Class type used by the wintertc API.
   */
  class Event {
    constructor(type: string, options?: { bubbles?: boolean; cancelable?: boolean });
    readonly type: string;
    readonly bubbles: boolean;
    readonly cancelable: boolean;
    readonly defaultPrevented: boolean;
    readonly target: EventTarget | null;
    readonly currentTarget: EventTarget | null;
    readonly timeStamp: number;
    preventDefault(): void;
  }

  class CustomEvent<T = any> extends Event {
    constructor(type: string, options?: { bubbles?: boolean; cancelable?: boolean; detail?: T });
    readonly detail: T;
  }

  class ErrorEvent extends Event {
    constructor(type: string, options?: { bubbles?: boolean; cancelable?: boolean; message?: string; filename?: string; lineno?: number; colno?: number; error?: any });
    readonly message: string;
    readonly filename: string;
    readonly lineno: number;
    readonly colno: number;
    readonly error: any;
  }

  class PromiseRejectionEvent extends Event {
    constructor(type: string, options?: { bubbles?: boolean; cancelable?: boolean; promise: Promise<any>; reason: any });
    readonly promise: Promise<any>;
    readonly reason: any;
  }

  class EventTarget {
    constructor();
    addEventListener(type: string, callback: EventListenerOrEventListenerObject | null): void;
    removeEventListener(type: string, callback: EventListenerOrEventListenerObject | null): void;
    dispatchEvent(event: Event): boolean;
  }

  type EventListener = (evt: Event) => void;

  /**
   * Type interface used by the wintertc API.
   */
  interface EventListenerObject {
    handleEvent(evt: Event): void;
  }

  /**
   * Type alias used by the wintertc API.
   */
  type EventListenerOrEventListenerObject = EventListener | EventListenerObject;

  class AbortSignal extends EventTarget {
    readonly aborted: boolean;
    readonly reason: any;
    onabort: ((this: AbortSignal, ev: Event) => any) | null;
    static abort(reason?: any): AbortSignal;
  }

  class AbortController {
    constructor();
    readonly signal: AbortSignal;
    abort(reason?: any): void;
  }

  // Global Event Handlers

  /**
   * Runtime global binding for onerror.
   */
  var onerror: ((event: string | Event, source?: string, lineno?: number, colno?: number, error?: Error) => any) | null;

  /**
   * Runtime global binding for onunhandledrejection.
   */
  var onunhandledrejection: ((ev: PromiseRejectionEvent) => any) | null;

  /**
   * Runtime global binding for onrejectionhandled.
   */
  var onrejectionhandled: ((ev: PromiseRejectionEvent) => any) | null;

  function addEventListener(type: string, callback: EventListenerOrEventListenerObject | null): void;

  /**
   * Runtime function provided by the wintertc API.
   */
  function removeEventListener(type: string, callback: EventListenerOrEventListenerObject | null): void;

  /**
   * Runtime function provided by the wintertc API.
   */
  function dispatchEvent(event: Event): boolean;

  /**
   * Runtime function provided by the wintertc API.
   */
  function reportError(error: any): void;

  // Encoding API

  /**
   * Class type used by the wintertc API.
   */
  class TextEncoder {
    readonly encoding: "utf-8";
    encode(input?: string): Uint8Array;
  }

  class TextDecoder {
    constructor(label?: string);
    readonly encoding: string;
    readonly fatal: boolean;
    readonly ignoreBOM: boolean;
    decode(input?: ArrayBuffer | ArrayBufferView): string;
  }

  // File API

  /**
   * Class type used by the wintertc API.
   */
  class Blob {
    constructor(blobParts?: any[], options?: { type?: string });
    readonly size: number;
    readonly type: string;
    slice(start?: number, end?: number, contentType?: string): Blob;
    arrayBuffer(): Promise<ArrayBuffer>;
    text(): Promise<string>;
    stream(): ReadableStream<Uint8Array>;
  }

  class File extends Blob {
    constructor(fileBits: any[], fileName: string, options?: { type?: string; lastModified?: number });
    readonly name: string;
    readonly lastModified: number;
  }

  // Streams API

  /**
   * Type interface used by the wintertc API.
   */
  interface ReadableStreamDefaultController<R> {
    readonly desiredSize: number | null;
    close(): void;
    enqueue(chunk?: R): void;
    error(err?: any): void;
  }

  interface ReadableStreamDefaultReader<R> {
    readonly closed: Promise<undefined>;
    cancel(reason?: any): Promise<void>;
    read(): Promise<ReadableStreamReadResult<R>>;
    releaseLock(): void;
  }

  type ReadableStreamReadResult<T> = ReadableStreamReadValueResult<T> | ReadableStreamReadDoneResult<T>;

  /**
   * Type interface used by the wintertc API.
   */
  interface ReadableStreamReadValueResult<T> {
    done: false;
    value: T;
  }

  /**
   * Type interface used by the wintertc API.
   */
  interface ReadableStreamReadDoneResult<T> {
    done: true;
    value?: T;
  }

  class ReadableStream<R = any> {
    constructor(underlyingSource?: {
      start?(controller: ReadableStreamDefaultController<R>): void | Promise<void>;
      pull?(controller: ReadableStreamDefaultController<R>): void | Promise<void>;
      cancel?(reason?: any): void | Promise<void>;
    });
    readonly locked: boolean;
    cancel(reason?: any): Promise<void>;
    getReader(): ReadableStreamDefaultReader<R>;
  }

  // Fetch API

  /**
   * Class type used by the wintertc API.
   */
  class Headers implements Iterable<[string, string]> {
    constructor(init?: HeadersInit);
    append(name: string, value: string): void;
    delete(name: string): void;
    get(name: string): string | null;
    has(name: string): boolean;
    set(name: string, value: string): void;
    forEach(callback: (value: string, key: string, parent: Headers) => void, thisArg?: any): void;
    [Symbol.iterator](): Iterator<[string, string]>;
    entries(): IterableIterator<[string, string]>;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
  }

  type HeadersInit = Headers | string[][] | Record<string, string>;

  class Request {
    constructor(input: RequestInfo, init?: RequestInit);
    readonly method: string;
    readonly url: string;
    readonly headers: Headers;
    readonly redirect: RequestRedirect;
    readonly credentials: RequestCredentials;
    readonly cache: RequestCache;
    readonly referrer: string;
    readonly integrity: string;
    readonly keepalive: boolean;
    readonly signal: AbortSignal | null;
    readonly body: ReadableStream<Uint8Array> | null;
    readonly bodyUsed: boolean;
    arrayBuffer(): Promise<ArrayBuffer>;
    blob(): Promise<Blob>;
    json(): Promise<any>;
    text(): Promise<string>;
    clone(): Request;
  }

  type RequestInfo = string | URL | Request;

  interface RequestInit {
    method?: string;
    headers?: HeadersInit;
    body?: BodyInit | null;
    redirect?: RequestRedirect;
    credentials?: RequestCredentials;
    cache?: RequestCache;
    referrer?: string;
    integrity?: string;
    keepalive?: boolean;
    signal?: AbortSignal | null;
  }

  type BodyInit = ReadableStream | XMLHttpRequestBodyInit | ArrayBufferView | ArrayBuffer | Blob | URLSearchParams | string;

  /**
   * Type alias used by the wintertc API.
   */
  type XMLHttpRequestBodyInit = Blob | BufferSource | URLSearchParams | string;

  type RequestRedirect = "follow" | "error" | "manual";

  /**
   * Type alias used by the wintertc API.
   */
  type RequestCredentials = "omit" | "same-origin" | "include";

  /**
   * Type alias used by the wintertc API.
   */
  type RequestCache = "default" | "no-store" | "reload" | "no-cache" | "force-cache" | "only-if-cached";

  class Response {
    constructor(body?: BodyInit | null, init?: ResponseInit);
    readonly status: number;
    readonly statusText: string;
    readonly ok: boolean;
    readonly headers: Headers;
    readonly url: string;
    readonly redirected: boolean;
    readonly type: ResponseType;
    readonly body: ReadableStream<Uint8Array> | null;
    readonly bodyUsed: boolean;
    arrayBuffer(): Promise<ArrayBuffer>;
    blob(): Promise<Blob>;
    json(): Promise<any>;
    text(): Promise<string>;
    clone(): Response;

    static json(data: any, init?: ResponseInit): Response;
    static redirect(url: string | URL, status?: number): Response;
    static error(): Response;
  }

  interface ResponseInit {
    status?: number;
    statusText?: string;
    headers?: HeadersInit;
  }

  type ResponseType = "basic" | "cors" | "default" | "error" | "opaque" | "opaqueredirect";

  function fetch(input: RequestInfo, init?: RequestInit): Promise<Response>;

  // Performance API

  /**
   * Runtime global binding for performance.
   */
  var performance: {
    readonly timeOrigin: number;
    now(): number;
  };

  // Console API

  /**
   * Runtime global binding for console.
   */
  var console: {
    debug(...data: any[]): void;
    error(...data: any[]): void;
    info(...data: any[]): void;
    log(...data: any[]): void;
    warn(...data: any[]): void;
  };

  // Crypto API

  /**
   * Type interface used by the wintertc API.
   */
  interface SubtleCrypto {
    digest(algorithm: string | { name: string }, data: ArrayBuffer | ArrayBufferView): Promise<ArrayBuffer>;
    encrypt(algorithm: any, key: any, data: any): Promise<any>;
    decrypt(algorithm: any, key: any, data: any): Promise<any>;
  }

  var crypto: {
    getRandomValues<T extends ArrayBufferView>(typedArray: T): T;
    randomUUID(): string;
    readonly subtle: SubtleCrypto;
  };
}
