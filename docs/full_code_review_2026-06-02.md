# Full Code Review - 2026-06-02

This review was split across three temporary worktrees:

- `/private/tmp/ejs-review-core-20260602`
- `/private/tmp/ejs-review-modules-20260602`
- `/private/tmp/ejs-review-types-docs-20260602`

The lanes were read-only. Source fixes are not included in this artifact unless
called out as documentation or declaration updates in the main checkout.

## Summary

- Confirmed findings: 12
- P0: 0
- P1: 1
- P2: 11

## P1 Findings

### Android network providers do not enforce allow rules and private/link-local restrictions

- Severity: P1
- Locations:
  - `modules/net/platform/android/java/com/ejs/modules/net/EJSNetProvider.java`
  - `modules/xhr/platform/android/java/com/ejs/modules/xhr/EJSXHRProvider.java`
  - `modules/ws/platform/android/java/com/ejs/modules/ws/EJSWebSocketProvider.java`
- Trigger: a host configures narrow `ejs.network` policy, default-deny outbound
  rules, or private/link-local denial. Apple enforces those policies; Android
  only checks coarse capability booleans and then connects or opens URLs.
- Root cause: Android policy parsing keeps capability and limit fields but does
  not model outbound/inbound allow rules, resolved-address checks, assigned-port
  rechecks, `denyPrivateNetworks`, or `denyLinkLocal`.
- Suggested fix: mirror or share the Apple network policy model on Android and
  add Android behavior tests for net/xhr/ws default-deny, host mismatch,
  private/link-local denial, and listen/bind port checks.

## P2 Findings

### Android sync invoke error strings leak

- Locations:
  - `platform/android/jni/ejs_android_platform.cpp`
  - `core/src/ejs_engine_quickjs_ng.c`
- Trigger: repeated Android `__ejs_native__.invokeSync(...)` calls that fail
  because no provider exists or a provider throws.
- Root cause: the Android sync bridge assigns `strdup(...)` strings to
  `EJSCoreHostError.message`, but core treats host error string fields as
  callback-lifetime host-owned pointers.
- Suggested fix: use static/thread-local callback-lifetime storage or free any
  heap allocation before returning after core has copied the message.

### Android append file handles lose append semantics

- Locations:
  - `modules/fs/js/fs.js`
  - `modules/fs/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java`
- Trigger: open an existing file with `"a"` or `"a+"`, move the file pointer
  through read or positioned write, then call unpositioned `handle.write(...)`.
- Root cause: Android seeks to EOF only once at open time. `RandomAccessFile`
  does not provide persistent `O_APPEND`, and the handle does not remember that
  it should append on each unpositioned write.
- Suggested fix: store the append flag on the handle and seek to `file.length()`
  before every unpositioned append-handle write under the same handle lock.

### Android KV and SQLite ignore documented nested limits

- Locations:
  - `modules/kv/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java`
  - `modules/sqlite/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java`
  - `modules/kv/README.md`
  - `modules/sqlite/README.md`
- Trigger: policy uses the documented `"limits"` object, such as
  `{ "limits": { "maxValueBytes": 128 } }`.
- Root cause: Android reads limit keys from the policy root instead of
  `object.optJSONObject("limits")`, so configured limits silently fall back to
  defaults.
- Suggested fix: parse all documented limit keys from the nested `"limits"`
  object and add Android policy tests.

### Android SQLite returns BLOB columns as bare base64 strings

- Locations:
  - `modules/sqlite/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java`
  - `modules/sqlite/js/sqlite.js`
  - `modules/sqlite/types/index.d.ts`
  - `modules/sqlite/README.md`
- Trigger: querying a BLOB column on Android returns `"AQI="` rather than the
  documented `{ type: "blob", base64: "AQI=" }` object.
- Root cause: Android serializes cursor BLOB fields directly as base64 strings;
  Apple and the shared JS/type contract use a discriminator object.
- Suggested fix: serialize BLOB columns as `{ type: "blob", base64 }`, enforce
  `maxBlobBytes`, and add Android query tests.

### Android SQLite truncates over-limit queries by rewriting SQL

- Locations:
  - `modules/sqlite/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java`
  - `modules/sqlite/platform/apple/src/EJSSQLiteApple.m`
  - `tests/sqlite/apple/ejs_sqlite_apple_test.m`
- Trigger: with `maxRows` set to `1`, a query that would return two rows
  succeeds on Android with one row but rejects on Apple.
- Root cause: Android appends `LIMIT maxRows` to arbitrary caller SQL rather
  than executing the original read-only statement and failing when iteration
  exceeds `maxRows`.
- Suggested fix: execute the original statement, count cursor rows, reject on
  over-limit results, and test SQL that already contains `LIMIT`.

### Path docs omit implemented resolve, parse, and format

- Locations:
  - `README.md`
  - `modules/path/README.md`
  - `docs/design.md`
- Trigger: readers rely on docs and miss supported `EJSPath.posix.resolve`,
  `parse`, and `format`.
- Root cause: docs were not updated after the JS wrapper, declarations, and JS
  tests added those methods.
- Status in this branch: docs updated.

### IPAddr docs describe scoped IPv6 incorrectly

- Locations:
  - `modules/stdlib/ipaddr/README.md`
  - `docs/design.md`
- Trigger: callers avoid scoped IPv6 inputs such as `fe80::1%lo0` because docs
  say zone identifiers are rejected.
- Root cause: docs are stale. The implementation and tests preserve scoped IPv6
  suffixes and expose `scopeId`.
- Status in this branch: docs updated.

### Aggregate stdlib declarations drifted from module-local declarations

- Location: `modules/stdlib/api.d.ts`
- Trigger: callers include `modules/stdlib/api.d.ts` and lose supported shapes
  such as nullable hashing options and minimal CIDR-like objects accepted by
  `EJSIPAddr.contains`.
- Root cause: the aggregate file was not aligned with the module-local
  `types/index.d.ts` files.
- Status in this branch: aggregate declaration aligned.

### Design doc points to a non-existent WinterTC type file

- Location: `docs/design.md`
- Trigger: a maintainer follows the declaration ownership list to
  `modules/wintertc/types/index.d.ts`, which does not exist.
- Root cause: WinterTC currently uses `modules/wintertc/api.d.ts`.
- Status in this branch: design doc updated.

### WinterTC getRandomValues declaration accepts unsupported views

- Location: `modules/wintertc/api.d.ts`
- Trigger: TypeScript permits `Float32Array` or `DataView` for
  `crypto.getRandomValues`, but runtime validation rejects them.
- Root cause: declaration used `ArrayBufferView`; implementation accepts only
  integer typed arrays.
- Status in this branch: declaration narrowed to integer typed arrays.

### WinterTC declares placeholder-only SubtleCrypto encrypt/decrypt

- Location: `modules/wintertc/api.d.ts`
- Trigger: typed callers see `crypto.subtle.encrypt` and `decrypt` as usable
  Promise APIs even though the implementation currently throws
  `"Not implemented yet"`.
- Root cause: declarations advertised placeholder methods as stable API.
- Status in this branch: stable declaration now exposes only `digest`.

## Verification Notes

Lane-level verification included:

- `cmake -DROOT_DIR=/private/tmp/ejs-review-core-20260602 -P cmake/check_platform_boundary.cmake`
- `node --check modules/wintertc/js/crypto.js`
- `node --check modules/path/js/path.js`
- `node tests/js/phase1_modules_js_test.js`
- `node tests/js/network_js_test.js`

The module lane was source-review only and did not run build/test commands that
would generate artifacts. TypeScript smoke was attempted in the types/docs lane,
but local `npx --no-install tsc` attempted registry access and could not be
completed in the read-only lane.
