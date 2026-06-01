export {};

/**
 * API declarations for module `fs`.
 * File-system API exposed as `globalThis.EJSFS`.
 */

declare global {
  /**
   * UTF-8 is the only text encoding accepted by the JavaScript wrapper.
   * Omit `encoding` or pass `null` to work with raw `ArrayBuffer` data.
   */
  type EJSFSEncoding = "utf8" | "utf-8";

  /**
   * Data accepted by write operations.
   */
  type EJSFSData = string | ArrayBuffer | ArrayBufferView;

  /**
   * Base path-selection options. Paths are resolved relative to the configured
   * default root unless `root` names another configured root.
   */
  interface EJSFSRootOptions {
    root?: string;
  }

  /**
   * Options for APIs that can encode or decode UTF-8 text.
   */
  interface EJSFSEncodingOptions extends EJSFSRootOptions {
    encoding?: EJSFSEncoding | null;
  }

  /**
   * Options for file writes.
   * `flag` defaults to `"w"`; `"wx"` rejects an existing destination.
   */
  interface EJSFSWriteFileOptions extends EJSFSEncodingOptions {
    flag?: "w" | "wx";
  }

  /**
   * Result object for `stat` and `lstat` metadata lookups.
   * Numeric fields mirror the Apple provider's `stat(2)` data. Time fields are
   * epoch milliseconds and can be `null` only if a provider response omits them.
   */
  interface EJSFSStats {
    dev: number;
    ino: number;
    mode: number;
    nlink: number;
    uid: number;
    gid: number;
    rdev: number;
    size: number;
    blksize: number;
    blocks: number;
    atimeMs: number | null;
    mtimeMs: number | null;
    ctimeMs: number | null;
    birthtimeMs: number | null;
    /**
     * Readability hint derived from the native mode bits.
     * Prefer the predicate helpers for logic.
     */
    type: "file" | "directory" | "symbolicLink" | "other";
    isFile(): boolean;
    isDirectory(): boolean;
    isSymbolicLink(): boolean;
  }

  /**
   * Result object for `statFs` filesystem statistics.
   */
  interface EJSFSStatFs {
    type: number;
    bsize: number;
    blocks: number;
    bfree: number;
    bavail: number;
    files: number;
    ffree: number;
  }

  /**
   * Backward-compatible name for APIs that accept `root` plus optional
   * UTF-8 `encoding`.
   */
  interface EJSFSOptions extends EJSFSEncodingOptions {}

  /**
   * Destination-related options for cross-root operations.
   */
  interface EJSFSDestinationOptions extends EJSFSRootOptions {
    /**
     * Destination root. When omitted, the provider uses `root`, then the
     * configured default root.
     */
    newRoot?: string;
  }

  /**
   * Options for `FileHandle.read`.
   */
  interface EJSFSFileHandleReadOptions {
    encoding?: EJSFSEncoding | null;
    /**
     * Maximum bytes to read. Defaults to 64 KiB.
     */
    length?: number;
    /**
     * Byte offset for positioned reads. Omit to advance the file descriptor.
     */
    position?: number;
  }

  /**
   * Options for `FileHandle.write`.
   */
  interface EJSFSFileHandleWriteOptions {
    encoding?: EJSFSEncoding | null;
    /**
     * Byte offset for positioned writes. Omit to advance the file descriptor.
     */
    position?: number;
  }

  /**
   * Options for `readFile`.
   */
  interface EJSFSReadFileOptions extends EJSFSEncodingOptions {}

  /**
   * Access mode accepted by `EJSFS.promises.access`.
   * Runtime normalization is case-insensitive and removes one `-`.
   */
  type EJSFSAccessMode = "read" | "write" | "readwrite" | "read-write" | "r" | "w" | "rw" | "r-w";

  /**
   * Options for `access`.
   */
  interface EJSFSAccessOptions extends EJSFSRootOptions {
    /**
     * Defaults to `"read"`.
     */
    mode?: EJSFSAccessMode;
  }

  /**
   * Open flags accepted by `EJSFS.promises.open`.
   */
  type EJSFSOpenFlag = "r" | "r+" | "w" | "w+" | "wx" | "wx+" | "a" | "a+" | "ax" | "ax+";

  /**
   * Options accepted by temp file/directory helpers.
   */
  interface EJSFSTempOptions extends EJSFSRootOptions {
    /**
     * Parent directory for the generated path. Defaults to `"."`.
     */
    dir?: string;
  }

  /**
   * Options for directory creation.
   */
  interface EJSFSMkdirOptions extends EJSFSRootOptions {
    /**
     * Create intermediate directories and accept an existing directory.
     */
    recursive?: boolean;
  }

  /**
   * Options for `rm`, `delete`, and `remove`.
   */
  interface EJSFSRemoveOptions extends EJSFSRootOptions {
    /**
     * Required to remove directories.
     */
    recursive?: boolean;
    /**
     * Resolve successfully when the path is already missing.
     */
    force?: boolean;
  }

  /**
   * Options for chmod-style metadata mutation.
   */
  interface EJSFSModeOptions extends EJSFSRootOptions {}

  /**
   * Options for ownership and time mutation.
   */
  interface EJSFSMetadataOptions extends EJSFSRootOptions {}

  /**
   * Promise-style handle returned by `open`.
   * Methods reject after the handle has been closed.
   */
  interface EJSFSFileHandle {
    /**
     * Provider handle id. It is observable for diagnostics; callers should not
     * construct or mutate handles manually.
     */
    handle: string;
    /**
     * Becomes `true` after `close()` starts.
     */
    closed: boolean;
    read(): Promise<ArrayBuffer>;
    read(options: EJSFSEncoding): Promise<string>;
    read(options: EJSFSFileHandleReadOptions & { encoding: EJSFSEncoding }): Promise<string>;
    read(options?: EJSFSFileHandleReadOptions): Promise<ArrayBuffer | string>;
    /**
     * Writes all bytes from `data` and resolves with the number of bytes
     * written. For string data, only UTF-8 encoding is accepted.
     */
    write(data: EJSFSData, options?: EJSFSFileHandleWriteOptions | EJSFSEncoding): Promise<number>;
    /**
     * Truncates the file to `length` bytes. Defaults to `0`.
     */
    truncate(length?: number): Promise<void>;
    /**
     * Flushes file data. On Apple this currently maps to `fsync(2)`.
     */
    datasync(): Promise<void>;
    /**
     * Flushes file data and metadata.
     */
    sync(): Promise<void>;
    /**
     * Closes the native file handle. Repeated calls are allowed.
     */
    close(): Promise<void>;
  }

  /**
   * Promise-based filesystem API namespace.
   */
  var EJSFS: {
    /**
     * Constructor for handle objects returned by `open`.
     * Exposed because the runtime installs the class on `EJSFS`; callers should
     * normally obtain instances through `EJSFS.promises.open`.
     */
    FileHandle: { new(handle: string): EJSFSFileHandle };
    promises: {
      /**
       * Checks whether `path` exists and satisfies the requested access mode.
       * Defaults to read access.
       */
      access(path: string, options?: EJSFSAccessOptions | EJSFSAccessMode): Promise<void>;
      /**
       * Changes POSIX permission bits. Requires write permission on the root.
       */
      chmod(path: string, mode: number, options?: EJSFSModeOptions): Promise<void>;
      /**
       * Changes owner and group while following symlinks when the host permits
       * it. Restricted platforms reject instead of silently succeeding.
       */
      chown(path: string, uid: number, gid: number, options?: EJSFSMetadataOptions): Promise<void>;
      /**
       * Copies one file. Overwrites by default; `{ flag: "wx" }` rejects an
       * existing destination. `newRoot` selects the destination root.
       */
      copyFile(srcPath: string, destPath: string, options?: EJSFSDestinationOptions & { flag?: "w" | "wx" }): Promise<void>;
      /**
       * Alias for `mkdir`.
       */
      createDirectory(path: string, options?: EJSFSMkdirOptions): Promise<void>;
      /**
       * Alias for `rm`.
       */
      delete(path: string, options?: EJSFSRemoveOptions): Promise<void>;
      /**
       * Resolves to `true` when the sandbox path exists, otherwise `false`.
       */
      exists(path: string, options?: EJSFSRootOptions): Promise<boolean>;
      /**
       * Changes owner and group without following the final symlink when the
       * host permits it.
       */
      lchown(path: string, uid: number, gid: number, options?: EJSFSMetadataOptions): Promise<void>;
      /**
       * Creates a hard link. `newRoot` selects the destination root.
       */
      link(existingPath: string, newPath: string, options?: EJSFSDestinationOptions): Promise<void>;
      /**
       * Alias for `readdir`.
       */
      list(path: string, options?: EJSFSRootOptions): Promise<string[]>;
      /**
       * Reads metadata without following the final symlink.
       */
      lstat(path: string, options?: EJSFSRootOptions): Promise<EJSFSStats>;
      /**
       * Updates access and modification times without following the final
       * symlink. Times are numbers in epoch milliseconds or `Date` instances.
       */
      lutime(path: string, atime: number | Date, mtime: number | Date, options?: EJSFSMetadataOptions): Promise<void>;
      /**
       * Creates a unique directory under `options.dir` or `"."` and resolves
       * to the sandbox-relative generated path.
       */
      makeTempDir(options?: EJSFSTempOptions): Promise<string>;
      makeTempDir(prefix?: string, options?: EJSFSTempOptions): Promise<string>;
      /**
       * Creates a unique empty file under `options.dir` or `"."` and resolves
       * to the sandbox-relative generated path.
       */
      makeTempFile(options?: EJSFSTempOptions): Promise<string>;
      makeTempFile(prefix?: string, options?: EJSFSTempOptions): Promise<string>;
      /**
       * Creates one directory, or intermediate directories when
       * `{ recursive: true }` is set.
       */
      mkdir(path: string, options?: EJSFSMkdirOptions): Promise<void>;
      /**
       * Opens a file and returns an `EJSFSFileHandle`. Defaults to flag `"r"`
       * and mode `0o666`.
       */
      open(path: string, options?: EJSFSRootOptions): Promise<EJSFSFileHandle>;
      open(path: string, flags?: EJSFSOpenFlag, options?: EJSFSRootOptions): Promise<EJSFSFileHandle>;
      open(path: string, flags?: EJSFSOpenFlag, mode?: number, options?: EJSFSRootOptions): Promise<EJSFSFileHandle>;
      readFile(path: string): Promise<ArrayBuffer>;
      readFile(path: string, options: EJSFSEncoding): Promise<string>;
      readFile(path: string, options: EJSFSReadFileOptions & { encoding: EJSFSEncoding }): Promise<string>;
      /**
       * Reads the entire file. Without UTF-8 encoding it resolves to an
       * `ArrayBuffer`; with UTF-8 encoding it resolves to a string.
       */
      readFile(path: string, options?: EJSFSReadFileOptions): Promise<ArrayBuffer | string>;
      /**
       * Reads a symbolic link target.
       */
      readLink(path: string, options?: EJSFSRootOptions): Promise<string>;
      /**
       * Lists directory entries sorted by name.
       */
      readdir(path: string, options?: EJSFSRootOptions): Promise<string[]>;
      /**
       * Alias for `rm`.
       */
      remove(path: string, options?: EJSFSRemoveOptions): Promise<void>;
      /**
       * Renames or moves a path. `newRoot` selects the destination root.
       */
      rename(oldPath: string, newPath: string, options?: EJSFSDestinationOptions): Promise<void>;
      /**
       * Removes files and symlinks. Directories require `{ recursive: true }`.
       */
      rm(path: string, options?: EJSFSRemoveOptions): Promise<void>;
      /**
       * Reads metadata while following symlinks.
       */
      stat(path: string, options?: EJSFSRootOptions): Promise<EJSFSStats>;
      /**
       * Reads filesystem-level statistics for the filesystem containing `path`.
       */
      statFs(path: string, options?: EJSFSRootOptions): Promise<EJSFSStatFs>;
      /**
       * Creates a symbolic link. Relative targets are interpreted by the host
       * filesystem; absolute or parent-traversing targets can be rejected by
       * policy.
       */
      symlink(target: string, path: string, options?: EJSFSRootOptions): Promise<void>;
      /**
       * Deletes a file or symlink, but not a directory.
       */
      unlink(path: string, options?: EJSFSRootOptions): Promise<void>;
      /**
       * Updates access and modification times while following symlinks. Times
       * are numbers in epoch milliseconds or `Date` instances.
       */
      utime(path: string, atime: number | Date, mtime: number | Date, options?: EJSFSMetadataOptions): Promise<void>;
      /**
       * Writes bytes to a file. String data is encoded as UTF-8. `flag`
       * defaults to `"w"`; `"wx"` rejects an existing destination.
       */
      writeFile(path: string, data: EJSFSData, options?: EJSFSWriteFileOptions | EJSFSEncoding): Promise<void>;
    };
  };
}
