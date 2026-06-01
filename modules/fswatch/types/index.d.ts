export {};

/**
 * API declarations for module `fswatch`.
 * File-watch API exposed as `globalThis.EJSFSWatch`.
 */

declare global {
  /**
   * Watch event types emitted by current Apple builds.
   *
   * Content and metadata mutations are reported as `"change"`. Delete,
   * rename, revoke, and parent-directory entry notifications are reported as
   * `"rename"`.
   */
  type EJSFSWatchEventType = "change" | "rename";

  /**
   * Callback invoked when the native watcher reports an event.
   *
   * The JavaScript wrapper coerces both arguments with `String(...)` before
   * calling the handler. The handler return value is ignored.
   */
  type EJSFSWatchHandler = (eventType: EJSFSWatchEventType, path: string) => void;

  /**
   * Options for a filesystem watch registration.
   */
  interface EJSFSWatchOptions {
    /**
     * Configured root name used to resolve relative watch paths.
     *
     * `null` and `undefined` select the configured default root. Any other
     * value is coerced with `String(...)` by the JavaScript wrapper before the
     * native request is made.
     */
    root?: unknown;
    /**
     * Request recursive watching.
     *
     * `null` and `undefined` omit the option. Non-null values must be actual
     * booleans or `watch()` throws a `TypeError` before making a native
     * request. Current Apple builds reject `true` as unsupported and return
     * watchers with `recursive === false`.
     */
    recursive?: boolean | null;
  }

  /**
   * Active watcher handle returned by `EJSFSWatch.watch()`.
   */
  interface EJSFSWatcher {
    /**
     * Stable native watcher id, coerced to string from the native response.
     */
    readonly id: string;
    /**
     * Whether recursive watching was accepted for this registration.
     */
    readonly recursive: boolean;
    /**
     * Close the native watcher and detach the JavaScript handler.
     *
     * Closing is idempotent: repeated calls do not issue additional native
     * close requests and resolve or reject with the original close operation.
     */
    close(): Promise<void>;
  }

  /**
   * Global entry point for registering filesystem watchers.
   */
  var EJSFSWatch: {
    /**
     * Watch a non-empty string path for native file events.
     *
     * `path` must be a non-empty string. Relative paths are resolved by the
     * native side under either `options.root` or its configured default root.
     * The returned watcher should be closed when no longer needed.
     */
    watch(path: string, handler: EJSFSWatchHandler, options?: EJSFSWatchOptions): Promise<EJSFSWatcher>;
  };
}
