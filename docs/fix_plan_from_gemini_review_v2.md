# Fix Plan From Gemini Review V2

Source review: `gemini_review_v2.md` (current worktree also contains `docs/gemini_review_v2.md`)
Plan date: 2026-05-27

## Execution Rules

- Verify every finding against the current source before changing code.
- Keep fixes issue-scoped and behavior-preserving unless the reviewed issue requires an API correction.
- Add targeted regression coverage for defect fixes.
- Treat broad performance or architecture suggestions as follow-up items unless a narrow, low-risk fix exists.

## Planned Order

1. Build/contract correctness: `GM-001`, `GM-002`, `GM-003`.
2. Apple lifecycle and sync/async invoke correctness: `GM-004`, `GM-005`, `GM-007`, `GM-008`.
3. Module correctness: `GM-010`, `GM-011`, `GM-012`.
4. Performance/design follow-ups: `GM-006`, `GM-009`, `GM-013`.

## Issue Matrix

| ID | Source item | Status | Current-source finding | Minimal fix proposal | Regression test proposal | Verification |
| --- | --- | --- | --- | --- | --- | --- |
| GM-001 | Core sync binary argument validation | Fixed (2026-05-27) | `ejs_native_invoke_sync` lacked the invalid-binary `else` branches already present in async invoke. | Rejected non-string/non-binary payload and transfer buffer with `TypeError`, cleaning temporary JS values before return. | Extended `test_js_invoke_sync` with invalid payload and invalid transfer object cases. | `cmake --build build --target ejs_core_test`; `ctest -R ejs_core_test --output-on-failure` |
| GM-002 | Core top-level-await module result | Fixed (2026-05-27) | `ejs_result_from_eval` frees non-exception values. For module TLA, QuickJS rejection is surfaced only by draining jobs later, while `ejs_eval_module` reported initial success. | Module eval now drains pending jobs and maps fulfilled/rejected/pending module promises to `EJSCoreResult`. Ordinary script eval remains unchanged. | Added module test where `await Promise.reject(new Error(...))` makes `ejs_eval_module` return error. | `cmake --build build --target ejs_core_test`; `ctest -R ejs_core_test --output-on-failure` |
| GM-003 | Core invoke ownership comments | Fixed (2026-05-27) | Code already had detailed lifecycle comments, but the `host_ref_released` defensive release could be made explicit. | Added a short `host_ref_released` ownership comment; no behavior change. | Existing core lifecycle tests are sufficient. | `cmake --build build --target ejs_core_test` |
| GM-004 | `EJSRuntime dealloc` self-retain | Fixed (2026-05-27) | `-[EJSRuntime dealloc]` calls `invalidate`, and `invalidate` can assign `_selfRetainForPendingTeardown = self` while deallocating. | Added a deallocating flag and skipped self-retain when invalidation is running from `dealloc`; explicit invalidate keeps existing async teardown retention. | Existing platform teardown/lifecycle regressions cover invalidate behavior; no practical live-context dealloc path exists because `EJSContext` strongly retains its runtime. | `cmake --build build --target ejs_apple_platform_test`; `ctest -R ejs_apple_platform_test --output-on-failure` |
| GM-005 | Apple async invoke early completion returns handle | Not a bug | Independent reviews and source inspection show `EJSCoreHostOperation` has caller/completion references; completing before return does not free the caller reference. | No code change. Do not return `NULL`, because that would overwrite provider errors with core internal errors. | Existing nil-provider/nil-operation tests cover this behavior. | `cmake --build build --target ejs_apple_platform_test`; `ctest -R ejs_apple_platform_test --output-on-failure` |
| GM-006 | Apple active-call thread depth performance | Deferred | Finding is real as a performance cost, but the current dictionary is also part of the teardown self-deadlock guard. | Defer to a dedicated performance patch; TLS needs careful handling for nested calls and multiple contexts. | Add perf/lifecycle stress coverage before changing. | Not in this fix batch |
| GM-007 | Apple byte-view NSData copy | Fixed (2026-05-27) | `ejs_apple_data_from_byte_view` copies borrowed invoke buffers even for sync calls. | Added a sync-only borrowed NSData helper using `dataWithBytesNoCopy:length:freeWhenDone:NO`; async invoke keeps copying. | Covered by existing async/sync invoke tests. | `cmake --build build --target ejs_apple_platform_test`; `ctest -R ejs_apple_platform_test --output-on-failure` |
| GM-008 | Apple empty sync result buffer init | Fixed (2026-05-27) | `result_out` was zeroed, but empty successful result did not go through `ejs_byte_buffer_init`. | Explicitly initialize `result_out` with `NULL, 0` through `ejs_byte_buffer_init`. | Existing sync empty-result test covers JS behavior; compile/test guards ABI use. | `cmake --build build --target ejs_apple_platform_test`; `ctest -R ejs_apple_platform_test --output-on-failure` |
| GM-009 | Module provider queue concurrency | Deferred | Serial fs/sqlite queues are a design tradeoff for provider-owned mutable state and SQLite connection safety; KV is already concurrent with per-store locks. | Defer broader queue redesign; do not replace queues mechanically. | Requires stress tests per provider before code changes. | Not in this fix batch |
| GM-010 | FS write loop handles `write == 0` | Fixed (2026-05-27) | `EJSFSWriteExclusiveData` only treated negative write as failure. | Treat `write == 0` as an internal write failure to avoid a stuck loop. | Existing fs write tests cover normal path; code branch is defensive. | `cmake --build build --target ejs_fs_apple_test`; `ctest -R ejs_fs_apple_test --output-on-failure` |
| GM-011 | SQLite close with pending statements | Fixed (2026-05-27) | `EJSSQLiteConnection.close` ignored `sqlite3_close` result. | Switched owned connection and failed-open cleanup to `sqlite3_close_v2`. | Existing sqlite tests cover close behavior; compile against sqlite is the guard. | `cmake --build build --target ejs_sqlite_apple_test`; `ctest -R ejs_sqlite_apple_test --output-on-failure` |
| GM-012 | SQLite JS transaction shared `_activeTx` | Fixed (2026-05-27) | Instance-level `_activeTx` made concurrent ordinary `db.query/execute` join an active transaction. | Introduced a dedicated transaction client passed to the callback; base `db.query/execute` rejects while a transaction is active. | Added JS regression that a base `db.query` during a transaction rejects instead of joining the transaction, while `tx.query` succeeds. | `node --check modules/sqlite/js/sqlite.js`; `cmake --build build --target ejs_sqlite_apple_test`; `ctest -R ejs_sqlite_apple_test --output-on-failure` |
| GM-013 | JS UTF-8 helper duplication | Deferred | Duplication is real, but moving encoding to native crosses module boundaries and changes optional-package architecture. | Defer to a design pass for shared JS helper or native text codec; no opportunistic refactor here. | Needs bundle/design-system validation across modules. | Not in this fix batch |

## Evidence Log

- Initial source inspection completed on 2026-05-27.
- Two independent read-only reviews completed before finalizing implementation; both flagged GM-005 as not a bug and GM-006/GM-009/GM-013 as design/performance follow-ups.
- Syntax: `node --check modules/sqlite/js/sqlite.js` (passed).
- Syntax: `node --check modules/fs/js/fs.js` (passed).
- Whitespace: `git diff --check` (passed).
- Build: `cmake --build build --target ejs_core_test ejs_apple_platform_test ejs_fs_apple_test ejs_sqlite_apple_test` (passed).
- Tests: `ctest -R "ejs_core_test|ejs_apple_platform_test|ejs_fs_apple_test|ejs_sqlite_apple_test" --output-on-failure` in `build` (4/4 passed).
