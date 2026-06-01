export {};

/**
 * API declarations for module `path`.
 * Pure POSIX string path helper API exposed as `globalThis.EJSPath`.
 *
 * The module does not touch the filesystem, resolve symlinks, infer native
 * separators, or expose the Apple installer/test hooks used to mount it.
 */

declare global {

  /**
   * Types used by the `EJSPath.posix` helper namespace.
   */
  namespace EJSPath {
    /**
     * Object shape returned by `EJSPath.posix.parse`.
     *
     * All fields are always present. Missing components are represented by an
     * empty string.
     */
    interface ParsedPath {
      /** Root marker, currently `"/"` for absolute POSIX paths or `""`. */
      root: string;
      /** Directory without the trailing basename, or `""` when absent. */
      dir: string;
      /** Final path segment including extension. */
      base: string;
      /** Extension from the last non-leading dot in `base`, or `""`. */
      ext: string;
      /** Basename without `ext`. */
      name: string;
    }

    /**
     * Object accepted by `EJSPath.posix.format`.
     *
     * `dir` takes precedence over `root`. `base` takes precedence over
     * `name + ext`.
     */
    interface FormatInput {
      root?: string;
      dir?: string;
      base?: string;
      ext?: string;
      name?: string;
    }

    /**
     * POSIX-only path operations object exposed as `EJSPath.posix`.
     */
    interface PosixPath {
      /**
       * Collapse duplicate separators, `.` segments, and resolvable `..`
       * segments while preserving a trailing slash when one was present.
       */
      normalize(path: string): string;

      /**
       * Join path parts with `/`, ignore empty parts, then normalize the
       * result. With no non-empty parts, returns `"."`.
       */
      join(...parts: string[]): string;

      /**
       * Return the directory portion of `path`; leaf-only paths return `"."`.
       */
      dirname(path: string): string;

      /**
       * Return the final path segment. When `suffix` is a non-empty string and
       * matches the end of the segment, the suffix is removed.
       */
      basename(path: string, suffix?: string): string;

      /**
       * Return the extension from the final path segment, including the dot.
       * Dotfiles such as `.profile` and parent references such as `..` return
       * an empty string.
       */
      extname(path: string): string;

      /**
       * Return whether `path` starts with `/`.
       */
      isAbsolute(path: string): boolean;

      /**
       * Return the POSIX relative path from `from` to `to`.
       *
       * Relative inputs are resolved against the runtime current working
       * directory before comparison.
       */
      relative(from: string, to: string): string;

      /**
       * Resolve path parts from right to left into an absolute normalized path.
       *
       * If no absolute part is found, the runtime current working directory is
       * used. Empty parts are ignored.
       */
      resolve(...parts: string[]): string;

      /**
       * Split `path` into POSIX path components.
       */
      parse(path: string): ParsedPath;

      /**
       * Build a path string from `dir`/`root` and `base` or `name + ext`.
       */
      format(pathObject: FormatInput): string;
    }
  }

  /**
   * Exported path namespace object.
   */
  var EJSPath: {
    /** POSIX-only path helper API. */
    readonly posix: EJSPath.PosixPath;
  };
}
