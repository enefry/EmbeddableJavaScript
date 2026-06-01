export {};

/**
 * API declarations for module `system`.
 * Promise-based host-system API exposed as `globalThis.EJSSystem`.
 *
 * The JavaScript facade performs lightweight argument validation and forwards
 * requests to the native `ejs.system` provider. These declarations describe the
 * JavaScript-visible surface only; native installer and provider internals are
 * intentionally not included.
 */

declare global {
  /**
   * Platform identifier returned by the current Apple provider.
   */
  type EJSSystemPlatform = "darwin";

  /**
   * Output of `EJSSystem.uname()`, sourced from `uname(3)` on Apple.
   */
  interface EJSSystemUname {
    /** Operating-system name, for example `"Darwin"`. */
    sysname: string;
    /** Network node name reported by the host. */
    nodename: string;
    /** Operating-system release string. */
    release: string;
    /** Operating-system version string. */
    version: string;
    /** Hardware architecture name, matching `EJSSystem.arch()`. */
    machine: string;
  }

  /**
   * CPU metadata returned by `EJSSystem.cpuInfo()`.
   *
   * The Apple provider returns one entry per processor. Optional details degrade
   * field-by-field: `model` can be an empty string and unavailable speed is `0`.
   */
  interface EJSSystemCPUInfo {
    /** CPU model or brand string when the host exposes it. */
    model: string;
    /** CPU speed in MHz when available; Apple currently reports `0`. */
    speed: number;
  }

  /**
   * Network interface entry returned by `EJSSystem.networkInterfaces()`.
   *
   * The Apple provider includes IPv4 and IPv6 addresses and omits interfaces
   * whose address cannot be converted to text.
   */
  interface EJSSystemNetworkInterface {
    /** Numeric IP address text, for example `"127.0.0.1"` or `"::1"`. */
    address: string;
    /** Address family reported for the entry. */
    family: "IPv4" | "IPv6";
    /** Whether the native interface is marked as loopback. */
    internal: boolean;
  }

  /**
   * User info returned by `EJSSystem.userInfo()`.
   */
  interface EJSSystemUserInfo {
    /** Numeric user id from `getuid()`. */
    uid: number;
    /** Numeric primary group id from `getgid()`. */
    gid: number;
    /** Login/user name when available. */
    username: string;
    /** Home directory path. The property name intentionally matches the API. */
    homedir: string;
    /** Login shell path when available; otherwise an empty string. */
    shell: string;
  }

  /**
   * Map returned by `EJSSystem.env()`.
   */
  type EJSSystemEnvironment = Record<string, string>;

  /**
   * Network interfaces grouped by native interface name.
   */
  type EJSSystemNetworkInterfaces = Record<string, EJSSystemNetworkInterface[]>;

  /**
   * Promise-based host-system API exposed as `globalThis.EJSSystem`.
   */
  interface EJSSystemAPI {
    /**
     * Resolve the process-wide current working directory.
     */
    cwd(): Promise<string>;

    /**
     * Change the process-wide current working directory.
     *
     * `path` must be a non-empty string. Because this mutates process state,
     * embedders should expose the module only where that behavior is acceptable.
     */
    chdir(path: string): Promise<void>;

    /**
     * Resolve a snapshot of the process environment.
     */
    env(): Promise<EJSSystemEnvironment>;

    /**
     * Resolve an environment variable value, or `null` when it is not set.
     *
     * `name` must be a non-empty string and cannot contain `"="`.
     */
    getenv(name: string): Promise<string | null>;

    /**
     * Set or overwrite an environment variable.
     *
     * `name` must be a non-empty string without `"="`; `value` is converted with
     * `String(value)` by the JavaScript facade before it reaches the provider.
     */
    setenv(name: string, value: unknown): Promise<void>;

    /**
     * Remove an environment variable.
     *
     * `name` must be a non-empty string and cannot contain `"="`.
     */
    unsetenv(name: string): Promise<void>;

    /**
     * Resolve the current process id.
     */
    pid(): Promise<number>;

    /**
     * Resolve the parent process id.
     */
    ppid(): Promise<number>;

    /**
     * Resolve the current user's home directory path.
     */
    homeDir(): Promise<string>;

    /**
     * Resolve the platform temporary directory path.
     */
    tmpDir(): Promise<string>;

    /**
     * Resolve the executable path when the host exposes one.
     */
    exePath(): Promise<string>;

    /**
     * Resolve the host name.
     */
    hostName(): Promise<string>;

    /**
     * Resolve the platform identifier. The current Apple provider returns
     * `"darwin"`.
     */
    platform(): Promise<EJSSystemPlatform>;

    /**
     * Resolve the machine architecture from `uname(3)`.
     */
    arch(): Promise<string>;

    /**
     * Resolve host and kernel metadata from `uname(3)`.
     */
    uname(): Promise<EJSSystemUname>;

    /**
     * Resolve system uptime in seconds.
     */
    uptime(): Promise<number>;

    /**
     * Resolve 1, 5, and 15 minute load averages. Providers that cannot obtain
     * load data return `[0, 0, 0]`.
     */
    loadAvg(): Promise<[number, number, number]>;

    /**
     * Resolve the active processor count, always at least `1`.
     */
    availableParallelism(): Promise<number>;

    /**
     * Resolve per-processor CPU metadata.
     */
    cpuInfo(): Promise<EJSSystemCPUInfo[]>;

    /**
     * Resolve network interfaces grouped by interface name. Missing or
     * unavailable native network data resolves to an empty object.
     */
    networkInterfaces(): Promise<EJSSystemNetworkInterfaces>;

    /**
     * Resolve user id, group id, username, home directory, and shell metadata.
     */
    userInfo(): Promise<EJSSystemUserInfo>;
  }

  var EJSSystem: EJSSystemAPI;
}
