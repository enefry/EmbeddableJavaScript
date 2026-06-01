# Network Phase 3C Error Diagnostics Execution Plan

更新时间：2026-05-28
状态：`complete`

源计划：

- `docs/module_alignment_roadmap.md`：`modules/net` TODO `错误码和异常信息可诊断（含目标地址信息）`
- `docs/network_implementation_plan.md` 阶段3验收标准：稳定 `EJSNetworkError`，至少覆盖 `EPERM`、`ENOTSUP`、`EINVAL`、`ETIMEOUT`、`ECONNREFUSED`、`ECONNRESET`、`EDNS`、`ETLS`、`ECANCELLED`

## Scope

Phase 3C tightens diagnostics for existing `modules/net` DNS/TCP/UDP operations:

- Preserve the existing JS `EJSNetworkError` shape.
- Map provider network failures to stable JS codes where native error detail is available:
  - POSIX `ECONNREFUSED` -> `ECONNREFUSED`
  - POSIX `ECONNRESET`/local peer reset class -> `ECONNRESET`
  - POSIX `EHOSTUNREACH` -> `EHOSTUNREACH`
  - POSIX `ENETUNREACH` -> `ENETUNREACH`
  - POSIX timeout class -> `ETIMEOUT`
  - `getaddrinfo` failures during lookup or connect/send resolution -> `EDNS`
- Preserve diagnostic fields: `operation`, `syscall`, `host`, `address`, `port`, `family`, `nativeDomain`, `nativeCode`.
- Do not expose native file descriptors.
- Do not change networking policy semantics.

## Platform Error Transport

Apple currently passes only the high-level `EJSProviderErrorDomain` code as `platform_code`.
This branch may add a narrow, generic platform improvement:

- A provider error may carry `NSUnderlyingErrorKey` for native subsystem detail.
- Apple platform error conversion must keep the top-level provider code for `EJSCoreErrorCode`.
- `platform_domain` / `platform_code` exposed to JS may use the underlying error domain/code when present.
- Existing provider errors without an underlying error must remain unchanged.

This is generic provider-error metadata transport only. Root `platform/*` must not parse network policy, know `EJSNet`, or contain network-specific mappings.

## Out Of Scope

- XHR and WebSocket implementation.
- New public JS network APIs.
- Public native ABI/header expansion unless already required by the generic platform path.
- Reworking all provider modules.
- Full synthetic coverage for every errno on every OS; add focused regression for representative mappings.

## Likely Files

- `modules/net/js/net.js`
- `modules/net/types/index.d.ts`
- `modules/net/platform/apple/src/EJSNetApple.m`
- `tests/js/network_js_test.js`
- `tests/net/apple/ejs_net_apple_test.m`
- `platform/apple/src/EJSApplePlatform.m` only if needed for generic `NSUnderlyingErrorKey` propagation
- `modules/net/README.md`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`

## Implementation Lane

- Main thread:
  - save this plan,
  - run baseline verification,
  - dispatch one bounded implementation worker,
  - inspect and reconcile the worker result,
  - run double review closure and final verification.
- Worker:
  - implement Phase 3C only,
  - keep edits scoped to net diagnostics and optional generic provider-error metadata transport,
  - preserve existing DNS/TCP/UDP behavior and policy.

## Regression Tests

JS wrapper tests:

- mock POSIX provider errors map to stable `EJSNetworkError.code` values.
- `nativeDomain` and `nativeCode` are retained from provider errors.
- existing `EDNS`, `EPERM`, `ETIMEOUT`, `ECANCELLED`, and malformed-provider paths continue to pass.

Apple tests:

- refused local TCP connect reports `ECONNREFUSED` with target host/port and native POSIX detail.
- DNS/getaddrinfo failure reports `EDNS` with host/family and native resolver detail.
- existing policy-denied, timeout, close/cancel, TCP/UDP loopback tests continue to pass.

## Verification Matrix

```sh
node --check modules/net/js/net.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/net tests/js/network_js_test.js tests/net/apple/ejs_net_apple_test.m platform/apple/src/EJSApplePlatform.m docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase3c_error_diagnostics_execution_plan.md
```

The focused `ctest` command may require sandbox escalation because the Apple integration tests use localhost sockets.

## Evidence Log

- Baseline `node --check modules/net/js/net.js`: pass.
- Baseline `node --check tests/js/network_js_test.js`: pass.
- Baseline `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Baseline `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`: pass.
- Baseline sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`: failed in `ejs_net_apple_test` with the known localhost sandbox artifact.
- Baseline escalated same `ctest` command for localhost sockets: pass, 3/3 tests.
- Implementation `node --check modules/net/js/net.js`: pass.
- Implementation `node --check tests/js/network_js_test.js`: pass.
- Implementation `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Implementation `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`: pass.
- Implementation sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`: failed with localhost socket limitation.
- Implementation escalated same `ctest` command for localhost sockets: pass, 3/3 tests.
- Main reconciliation after worker:
  - updated TypeScript `EJSNetworkError.code` union for `ECONNREFUSED`/`ECONNRESET`/`EHOSTUNREACH`/`ENETUNREACH`;
  - added JS mock coverage for POSIX timeout-class mapping to `ETIMEOUT`;
  - converted Apple TCP listen POSIX failure paths to carry underlying `NSPOSIXErrorDomain` detail.
- Final `node --check modules/net/js/net.js`: pass.
- Final `node --check tests/js/network_js_test.js`: pass.
- Final `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Final `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check ejs_apple_platform_test`: pass.
- Final sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test|ejs_apple_platform_test" --output-on-failure`: failed with `failed to reserve loopback port for tcp-refused test`, matching sandbox localhost restrictions.
- Final escalated same `ctest` command for localhost sockets: pass, 4/4 tests.
- Focused whitespace checks on touched tracked files and new Phase 3C files emitted no findings.
- Double review closure:
  - error-mapping review: no actionable correctness issues; residual risk is representative rather than exhaustive Apple end-to-end coverage for every POSIX subclass.
  - platform-boundary review: no actionable layering issues; root Apple platform remains generic and underlying `NSError` only enriches platform diagnostics.
