# Fix Plan From Final Review

Source review: `docs/final_review.md`  
Plan date: 2026-05-27

## Re-review Snapshot (2026-05-27, Complete)

- Current closure: `30 / 30` issues fixed.
- Remaining: `0 / 30` issues still pending.
- All `FR-*` items in the matrix are marked `Fixed`.
- Remaining IDs: none.

## Execution Rules

- Fix issue-by-issue with minimal deltas.
- Run two independent subagent reviews before each implementation item.
- Add targeted regression tests for each closed item.
- Validate with focused module tests instead of full-suite first.

## Planned Order

1. P0 security/data-boundary: `FR-009`, `FR-007`.
2. Node/Web input-boundary corrections: `FR-022`, `FR-008`.
3. Node/Web semantic alignment: `FR-018`, `FR-019`, `FR-020`, `FR-021`.
4. Platform/core lifecycle correctness: `FR-006`, `FR-005`, `FR-003`.
5. Data/result correctness and memory behavior: `FR-004`, `FR-010`, `FR-011`, `FR-012`, `FR-013`, `FR-014`.
6. Contract/docs hardening: `FR-001`, `FR-002`, `FR-015`, `FR-027`, `FR-028`, `FR-029`, `FR-030`.
7. Performance/scale follow-ups: `FR-016`, `FR-017`, `FR-023`, `FR-024`, `FR-025`, `FR-026`.

## Issue Matrix

| ID | Priority | Status | Goal | Minimal fix proposal | Regression test proposal | Verification |
| --- | --- | --- | --- | --- | --- | --- |
| FR-009 | P0 | Fixed (2026-05-27) | Prevent KV manifest path escape via tampered `fileName` | Removed the manifest backend from the KV read/write path by migrating to SQLite-only storage before release | Added stale poisoned-manifest test asserting manifest data is ignored and outside sentinel remains unchanged | `ctest -R ejs_kv_apple_test --output-on-failure` (passed) |
| FR-007 | P0 | Fixed (2026-05-27) | Preserve `"wx"` exclusive-create semantics without TOCTOU | Replace pre-check+write with atomic create (`open` + `O_CREAT|O_EXCL|O_NOFOLLOW`) for `writeFile/copyFile` `"wx"` path | Added FS `writeFile(wx)` non-overwrite regression; existing `copyFile(wx)` regression kept | `ctest -R ejs_fs_apple_test --output-on-failure` (passed) |
| FR-006 | P1 | Fixed (2026-05-27) | Avoid teardown indefinite wait on blocked provider | Added bounded invalidate wait and timeout fallback that detaches core context for deferred destroy completion | Added platform teardown test with stalled provider call and timeout assertion | `ctest -R ejs_apple_platform_test --output-on-failure` (passed) |
| FR-005 | P1 | Fixed (2026-05-27) | Break `EJSContext` / core user_data retain cycle | Introduced weak host bridge object for core host callbacks to avoid retaining `EJSContext` | Added lifecycle test proving context dealloc after dropping external strong refs | `ctest -R ejs_apple_platform_test --output-on-failure` (passed) |
| FR-003 | P1 | Fixed (2026-05-27) | Ensure terminal shutdown failure does not skip cleanup | Added local terminal-shutdown fallback when `runtime_loop_call_sync` fails during runtime destroy | Added core regression for stop-requested loop path to ensure host/context cleanup still runs | `ctest -R ejs_core_test --output-on-failure` (passed) |
| FR-004 | P1 | Fixed (2026-05-27) | Align async/sync invalid result-buffer contract | Reject invalid async buffers (`size > 0 && data == NULL`) and avoid overriding internal errors with `EJS_ERROR_NONE` host error payloads | Added async invalid-result-buffer regression in core invoke test | `ctest -R ejs_core_test --output-on-failure` (passed) |
| FR-008 | P1 | Fixed (2026-05-27) | Stop truthy-coercing string booleans in FS JS wrapper | `boolOption` now only accepts primitive booleans and throws `TypeError` for non-boolean option values | Added mkdir/rm boolean-option regressions for string `"false"` inputs | `ctest -R ejs_fs_apple_test --output-on-failure` (passed) |
| FR-010 | P1 | Fixed (2026-05-27) | Bound SQLite query response memory for TEXT-heavy result sets | Added `maxTextBytes` and `maxResponseBytes` policy limits with strict UTF-8/text/blob accounting in query path | Added SQLite text/response byte-limit regressions | `ctest -R ejs_sqlite_apple_test --output-on-failure` (passed) |
| FR-011 | P1 | Fixed (2026-05-27) | Prevent silent precision loss for int64 over JS safe integer | Return out-of-range integers as tagged `{type:'int64', value:'...'}` and decode to `BigInt` (or exact string fallback) in JS wrapper | Added SQLite >2^53-1 roundtrip regression | `ctest -R ejs_sqlite_apple_test --output-on-failure` (passed) |
| FR-012 | P1 | Fixed (2026-05-27) | Make abort effective during request body transfer phase | Made request-body stream transfer abort-aware by racing `reader.read()` with `AbortSignal` and cancelling the source stream on abort | Added fetch regression with slow streaming request body and timeout-bound abort | `ctest -R ejs_wintertc_apple_test --output-on-failure` (passed) |
| FR-013 | P1 | Fixed (2026-05-27) | Release unconsumed response stream state on completion | Added best-effort auto-cancel of unconsumed response body streams (grace period) to release provider stream state | Added fetch status-only regression asserting auto-cancel callback path | `ctest -R ejs_wintertc_apple_test --output-on-failure` (passed) |
| FR-014 | P1 | Fixed (2026-05-27) | Prevent pending read starvation in stream pull logic | Added controller `_pullAgain` scheduling so pull requests are not dropped while a pull is in-flight | Added pull-driven concurrent read regression (`streams-pull-concurrent-read-ok`) to cover one-chunk-per-pull starvation path | `ctest -R ejs_wintertc_apple_test --output-on-failure` (passed) |
| FR-015 | P1 | Fixed (2026-05-27) | Enforce add-on boundary checks beyond `platform/*` | Expanded boundary checker to inspect root/platform/cmake target mutation calls for `ejs_apple_platform` and to cover non-WinterTC add-on target tokens | Added negative fixture and will-fail boundary test for forbidden dependency injection | `ctest -R "ejs_platform_boundary_(test|negative_test)" --output-on-failure` (passed) |
| FR-001 | P2 | Fixed (2026-05-27) | Document runtime/context destroy ABI contract clearly | Added explicit runtime/context lifetime contract in `core/include/ejs_runtime.h`, and synchronized the same contract language into `README.md` and `docs/design.md` | Existing lifecycle tests remain the guard; doc changes align public contract with runtime behavior | `ctest -R ejs_core_test --output-on-failure` (passed) |
| FR-002 | P2 | Fixed (2026-05-27) | Document platform-side serial destroy requirement | Added explicit "serialize destroy per runtime" guidance in runtime header and durable docs; also removed runtime-lock hold around context creation to avoid lock-contention teardown behavior | Updated Apple race test to assert invalidate no longer waits on create-context hook | `ctest -R ejs_apple_platform_test --output-on-failure` (passed) |
| FR-016 | P2 | Fixed (2026-05-27) | Ensure stopped owner-thread loop does not leak joinable thread resource | Added `thread_joined` tracking and owner-stop cleanup path so `ejs_runtime_loop_destroy` joins an unjoined stopped owner thread before freeing loop state | Added libuv+EJS_TEST assertion that owner-thread stop path triggers exactly one join during destroy | `ctest -R ejs_core_test --output-on-failure` (passed) |
| FR-017 | P2 | Fixed (2026-05-27) | Reduce lock hold time around context creation | Moved create-context hook and `ejs_context_create(...)` outside `EJSRuntime.stateLock` and added pending-create teardown accounting to keep invalidate/runtime destroy safe during in-flight creates | Updated platform race test to verify runtime invalidate returns while create hook is blocked and create returns invalidated error | `ctest -R ejs_apple_platform_test --output-on-failure` (passed) |
| FR-018 | P2 | Fixed (2026-05-27) | Align rename overwrite behavior with Node/POSIX | Replaced `moveItemAtPath` with POSIX `rename(2)` in fs provider rename path | Upgraded fs rename regression to cover overwrite of existing destination + source disappearance | `ctest -R ejs_fs_apple_test --output-on-failure` (passed) |
| FR-019 | P2 | Fixed (2026-05-27) | Make `exists` on broken symlink return false | `exists` now relies on `fileExistsAtPath` only, removing broken-symlink truthy fallback | Added broken-symlink `exists === false` assertion to fs stat/exists regression | `ctest -R ejs_fs_apple_test --output-on-failure` (passed) |
| FR-020 | P2 | Fixed (2026-05-27) | Align mixed absolute/relative `path.relative` behavior with Node | `relative()` now resolves relative inputs against cwd (`process.cwd()` fallback `/`) before computing | Updated path Apple test to validate mixed abs/rel behavior via resolved-absolute expectations | `ctest -R ejs_path_apple_test --output-on-failure` (passed) |
| FR-021 | P2 | Fixed (2026-05-27) | Implement or explicitly reject unsupported fetch redirect modes | Added redirect-mode validation and explicit `manual/error` rejection in JS + Apple native; added follow redirect URL/redirected metadata wiring | Added redirect mode rejection tests (JS + native bypass) and follow-redirect metadata test in WinterTC Apple suite | `ctest -R ejs_wintertc_apple_test --output-on-failure` (passed) |
| FR-022 | P2 | Fixed (2026-05-27) | Reject CR/LF in header values | Added JS-level CR/LF rejection in `normalizeHeaderValue`; added native header validation and fail-fast in `wintertc.fetch start` for array/dictionary header inputs | Added JS rejection test and native-bypass rejection test in WinterTC Apple harness | `ctest -R ejs_wintertc_apple_test --output-on-failure` (passed) |
| FR-023 | P2 | Fixed (2026-05-27) | Narrow binary extraction accepted types and side effects | Tightened binary payload extraction and changed invoke validation to reject non-string/non-binary payload or transfer objects with explicit `TypeError` instead of silent empty-payload fallback | Added malicious getter-object regression asserting rejection and no getter side effects while keeping typed-array acceptance | `ctest -R ejs_core_test --output-on-failure` (passed) |
| FR-024 | P2 | Fixed (2026-05-27) | Reduce provider-level head-of-line blocking | Made the KV provider dispatch queue concurrent while retaining deterministic per-store serialization | Existing concurrent multi-runtime KV test now exercises the SQLite-backed provider without provider-wide serialization | `ctest -R ejs_kv_apple_test --output-on-failure` (passed) |
| FR-025 | P2 | Fixed (2026-05-27) | Address manifest full-read/full-write scale bottleneck | Migrated KV Apple backend from manifest/value files to per-store SQLite-only storage (`kv.sqlite3`) with WAL, prepared statements, and `maxTotalKeys` | Added SQLite persistence, stale manifest ignored, concurrent access, and total-key-limit regressions | `ctest -R ejs_kv_apple_test --output-on-failure` (passed) |
| FR-026 | P2 | Fixed (2026-05-27) | Prevent CLI timeout overflow | Added timeout-to-nanoseconds overflow-safe conversion helper and reject values that cannot be represented as `dispatch_time` delta | Added CLI regression test covering valid timeout execution and huge-timeout rejection | `ctest -R ejs_apple_cli_test --output-on-failure` (passed) |
| FR-027 | P2 | Fixed (2026-05-27) | Keep README verification list aligned with wired Apple module tests | Expanded README Apple verification commands to include `path/buffer/kv/sqlite` test targets and binaries | Verified those module tests all pass with the documented targets | `ctest -R "ejs_(fs|path|buffer|kv|sqlite)_apple_test" --output-on-failure` (passed) |
| FR-028 | P2 | Fixed (2026-05-27) | Sync `docs/design.md` with current CMake/testing behavior | Corrected `docs/design.md` to state tests are added only with `BUILD_TESTING=ON`; replaced stale `docs/README.md` entry with root `README.md` | Boundary check still passes after doc synchronization | `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_platform_boundary_check` (passed) |
| FR-029 | P2 | Fixed (2026-05-27) | Reduce flaky fixed-sleep waits in tests | Replaced key runtime lifecycle destroy waits in `ejs_core_test` with condition-variable waiter synchronization and bounded timed waits; retained WinterTC local-server sleeps that intentionally model transport timing | Core + WinterTC test pass confirms lifecycle synchronization updates did not regress add-on behavior | `ctest -R "ejs_core_test|ejs_wintertc_apple_test" --output-on-failure` (passed; WinterTC rerun outside sandbox for local bind) |
| FR-030 | P2 | Fixed (2026-05-27) | Avoid misleading stack-host-user-data sample pattern | Converted `sample/ejs_sample.c` host state from stack object to heap object with retain/release callbacks and explicit final release | Built and executed sample binary successfully after lifetime model update | `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_sample && /Users/chenrenwei/developer/js-runtime/ejs/build/sample/ejs_sample` (passed) |

## This Run Scope

- Closed `FR-001`, `FR-002`, `FR-016`, `FR-017`, `FR-024`, `FR-025`, `FR-027`, `FR-028`, `FR-029`, and `FR-030`.
- Overall status is complete (`30/30` closed).

## This Run Evidence

- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_fs_apple_test ejs_kv_apple_test` (passed)
- Tests: `ctest -R "ejs_(kv|fs)_apple_test" --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (2/2 passed)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_wintertc_apple_test` (passed)
- Tests: `ctest -R ejs_wintertc_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed; rerun outside sandbox due local HTTP bind restriction)
- Tests: `ctest -R ejs_wintertc_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed again after FR-021 redirect updates; rerun outside sandbox due local HTTP bind restriction)
- Tests: `ctest -R ejs_wintertc_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed again after FR-014 pull-concurrency fix; rerun outside sandbox due local HTTP bind restriction)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_fs_apple_test` (passed)
- Tests: `ctest -R ejs_fs_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_path_apple_test` (passed)
- Tests: `ctest -R ejs_path_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Tests: `ctest --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed outside sandbox, `10/10`)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_core_test ejs_apple_platform_test ejs_sqlite_apple_test ejs_wintertc_apple_test` (passed)
- Tests: `ctest -R ejs_core_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Tests: `ctest -R ejs_apple_platform_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Tests: `ctest -R ejs_sqlite_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Tests: `ctest -R ejs_wintertc_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed outside sandbox due local HTTP bind restriction)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_core_test ejs_platform_boundary_check ejs_apple_cli_test` (passed)
- Tests: `ctest -R ejs_core_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Tests: `ctest -R "ejs_platform_boundary_(test|negative_test)|ejs_apple_cli_test" --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_core_test ejs_apple_platform_test ejs_sample` (passed)
- Tests: `ctest -R "ejs_core_test|ejs_apple_platform_test" --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (2/2 passed)
- Tests: `ctest -R "ejs_(fs|path|buffer|kv|sqlite)_apple_test" --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (5/5 passed)
- Build: `cmake --build /Users/chenrenwei/developer/js-runtime/ejs/build --target ejs_platform_boundary_check` (passed)
- Tests: `ctest -R ejs_wintertc_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed outside sandbox due local HTTP bind restriction)
- Sample: `/Users/chenrenwei/developer/js-runtime/ejs/build/sample/ejs_sample` (passed)
- Build: `cmake --build build --target ejs_kv_apple_test` (passed)
- Tests: `ctest -R ejs_kv_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Build: `cmake --build build --target ejs_sqlite_apple_test ejs_core_test ejs_apple_platform_test` (passed)
- Tests: `ctest -R ejs_sqlite_apple_test --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (passed)
- Tests: `ctest -R "ejs_core_test|ejs_apple_platform_test" --output-on-failure` in `/Users/chenrenwei/developer/js-runtime/ejs/build` (2/2 passed)
