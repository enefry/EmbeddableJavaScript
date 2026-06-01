# Fix Plan From Gemini Review

Status date: 2026-05-29

This plan tracks the source-verified follow-up work from `docs/gemini_review/`.
The review reports are treated as an issue queue, not as proof that the current
tree already contains each fix.

## Repair Order

1. Review current uncommitted fixes for regressions.
2. Close low-risk JS/API mismatches.
3. Close Apple lifecycle and concurrency hazards.
4. Revisit broader compatibility gaps that need more design or test work.

## Current Diff Review

| Area | Status | Notes |
| --- | --- | --- |
| `fs` JS handle lifecycle | fixed, verified | Current diff adds `TextEncoder`/`TextDecoder`, finalizer-safe native close, and close de-duping. |
| `fswatch` JS/native | fixed, verified | Current diff adds registry cleanup, safe close helper, main-queue event delivery, stale watcher filtering, and a real UTF-8 fallback. |
| `kv` native SQLite lifecycle | fixed, verified | Current diff switches from per-operation close to provider-scoped cached connections, serializes provider work to avoid shared-handle races, handles duplicate open races, and closes with `sqlite3_close_v2`. |
| `sqlite` JS lifecycle | fixed, verified | Current diff adds `FinalizationRegistry`, finalizer-safe native close, concurrent close de-duping, and rollback-failure close hardening. |
| generated `api.d.ts` files | partially fixed, verified | Concrete SQLite and WinterTC mismatches from `api_ts_review` are fixed. Broad generated comments remain low priority. |

## Confirmed Fix Queue

| ID | Source | Status | Minimal fix |
| --- | --- | --- | --- |
| API-001 | `api_ts_review.md` | fixed, verified | Added `bigint` to SQLite row column types. |
| API-002 | `api_ts_review.md` | fixed, verified | Added runtime `desiredSize` to `ReadableStreamDefaultController`. |
| API-003 | `api_ts_review.md` | fixed, verified | Added `ReadableStreamDefaultReader.closed` and `cancel()`. |
| API-004 | `api_ts_review.md` | fixed, verified | Added `URL.origin` runtime getter. |
| FSW-JS-001 | `fswatch_review.md` | fixed, verified | Replaced Latin-1 fallback with real UTF-8 decoding. |
| JS-BIN-001 | `buffer/system/stdlib/ws/xhr` reviews | fixed, verified | Added native encoder/decoder fast paths and chunked fallbacks where confirmed. |
| NATIVE-001 | `net_review.md` | fixed, verified | Avoided invalid cancel fd registration and moved blocking `select` waits outside socket locks. |
| NATIVE-002 | `worker_review.md` | fixed, verified | Worker terminate/start-cancel now interrupts runtime before queued invalidation. |
| NATIVE-003 | `system/ws/xhr/fswatch` reviews | fixed, verified | Added targeted Apple-side locking, safe string bridging, async responder routing, and stale watcher filtering. |
| PATH-001 | `path_review.md` | fixed, verified | Added `resolve`, `parse`, and `format`; fixed root-dir `format` edge case. |

## Deferred Or Partial Items

| ID | Source | Status | Notes |
| --- | --- | --- | --- |
| SQLITE-BLOB-001 | `sqlite_review.md` | deferred | Native SQLite blob/base64 transport can still allocate large intermediate strings. Needs a protocol-level response-shape change. |
| WS-XHR-BINARY-001 | `ws_review.md`, `xhr_review.md` | partial | JS decode hot paths improved and GC finalizers now close/abort native tasks. Native protocols still use JSON/base64/number-array wrappers for some binary payloads. |
| STD-NATIVE-001 | `stdlib_review.md` | fixed, verified | Added CommonCrypto one-shot length guard and IPv6 scope id parsing/type support. Streaming hash remains deferred. |
| PATH-PERF-001 | `path_review.md` | partial | API gaps closed. The broader allocation/perf cleanup is not required for correctness and remains lower priority. |

## Verification Plan

Targeted verification should run after integration:

```sh
ctest --test-dir build -R "ejs_(fswatch|kv|sqlite|worker|net|wintertc|ws|xhr|buffer|system|stdlib|path).*" --output-on-failure
```

If the build tree predates new targets, rerun CMake before the targeted tests.

## Verification Evidence

- `node --check` passed for all modified JS runtime files and the updated JS network test.
- `cmake --build build --target ejs_net_apple ejs_ws_apple ejs_xhr_apple ejs_system_apple ejs_hashing_apple ejs_fswatch_apple ejs_kv_apple ejs_sqlite_apple ejs_path_apple` passed.
- `cmake --build build --target ejs_stdlib_apple_test` passed after updating scope-id coverage.
- `ctest --test-dir build -R "ejs_.*(buffer|system|fswatch|path|kv|sqlite|net|network|xhr|ws|stdlib|worker|wintertc).*" --output-on-failure` passed outside the sandbox where local network fixtures are allowed: 14/14.
