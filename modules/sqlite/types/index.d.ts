export interface EJSSQLiteOpenOptions {
  /**
   * Request a read-only connection to the named policy database.
   *
   * Read-only connections may call `query`, but `execute` and `transaction`
   * reject because they require write permission.
   */
  readOnly?: boolean;
}

/**
 * Values accepted as SQLite bind parameters.
 *
 * `number` values must be finite at runtime. `boolean` parameters are bound as
 * integer `1` or `0`; SQLite result rows expose those values as numbers.
 * Binary/blob parameters are not supported by the JavaScript facade.
 */
export type EJSSQLiteParam = null | boolean | number | string;

/**
 * Blob column representation returned by `query`.
 */
export interface EJSSQLiteBlobColumn {
  /** Discriminator for blob result columns. */
  type: "blob";
  /** Base64-encoded SQLite BLOB bytes, subject to the host `maxBlobBytes` limit. */
  base64: string;
}

/**
 * Values returned in SQLite query rows.
 *
 * SQLite NULL, INTEGER, FLOAT, TEXT, and BLOB map to `null`, `number`,
 * `string`, and `EJSSQLiteBlobColumn`. Integers outside JavaScript's safe
 * integer range are decoded to `bigint` when `BigInt` is available, otherwise
 * they remain exact decimal strings.
 */
export type EJSSQLiteColumn = null | number | string | bigint | EJSSQLiteBlobColumn;

/**
 * Row object returned by `query`, keyed by SQLite column name or alias.
 */
export type EJSSQLiteRow = Record<string, EJSSQLiteColumn>;

export type EJSSQLiteTransactionCallback<T> = (tx: EJSSQLiteTransaction) => Promise<T> | T;

/**
 * Transaction-scoped database client passed to `EJSSQLiteDatabase.transaction`.
 *
 * Use this client for all work inside the callback. While a transaction is
 * active, the outer database connection rejects direct `execute` and `query`
 * calls so they cannot accidentally join the active transaction.
 */
export interface EJSSQLiteTransaction {
  /**
   * Execute one write statement in the active transaction.
   *
   * The SQL string must be non-empty and contain exactly one SQLite statement.
   * Bind parameter count must match the statement placeholders.
   */
  execute(sql: string, params?: ReadonlyArray<EJSSQLiteParam>): Promise<void>;

  /**
   * Run one read-only statement in the active transaction and return row objects.
   *
   * Result size is constrained by the host policy limits such as `maxRows`,
   * `maxTextBytes`, `maxBlobBytes`, and `maxResponseBytes`.
   */
  query(sql: string, params?: ReadonlyArray<EJSSQLiteParam>): Promise<EJSSQLiteRow[]>;
}

/**
 * Database connection returned by `EJSSQLite.open`.
 *
 * Connections are backed by a host-configured policy database name, not by a
 * web-supplied filesystem path.
 */
export interface EJSSQLiteDatabase {
  /**
   * Execute one write statement.
   *
   * The SQL string must be non-empty and contain exactly one SQLite statement.
   * `query` must be used for read-only statements.
   */
  execute(sql: string, params?: ReadonlyArray<EJSSQLiteParam>): Promise<void>;

  /**
   * Run one read-only statement and return row objects keyed by column name.
   *
   * `execute` must be used for write statements. Bind parameter count must
   * match the statement placeholders.
   */
  query(sql: string, params?: ReadonlyArray<EJSSQLiteParam>): Promise<EJSSQLiteRow[]>;

  /**
   * Run a callback inside a `BEGIN IMMEDIATE` transaction.
   *
   * The callback result is returned after commit. If the callback throws or
   * rejects, the transaction is rolled back and the original error is rethrown.
   * Nested transactions are rejected.
   */
  transaction<T>(callback: EJSSQLiteTransactionCallback<T>): Promise<T>;

  /**
   * Close the native connection.
   *
   * Closing is idempotent. New operations after close reject with a closed
   * database error.
   */
  close(): Promise<void>;
}

/**
 * Top-level SQLite facade exposed as `globalThis.EJSSQLite`.
 */
export interface EJSSQLiteGlobal {
  /**
   * Open a configured database by policy name.
   *
   * The name must be a non-empty string present in host policy. Web code cannot
   * open arbitrary filesystem paths.
   */
  open(name: string, options?: EJSSQLiteOpenOptions): Promise<EJSSQLiteDatabase>;
}

/**
 * API declarations for optional module `sqlite`.
 *
 * This is the web-visible asynchronous EJS SQLite facade. It is not the Node
 * `node:sqlite` API and does not expose synchronous databases, prepared
 * statement objects, or Apple provider installation functions.
 */
export {};
declare global {

  /**
   * Global SQLite binding installed by the optional SQLite module.
   */
  var EJSSQLite: EJSSQLiteGlobal;
}
