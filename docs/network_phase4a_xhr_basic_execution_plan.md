# Network Phase 4A XHR Basic Execution Plan

更新时间：2026-05-28
状态：`completed`

源计划：

- `docs/network_implementation_plan.md` Phase 4：`modules/xhr`
- `docs/module_alignment_roadmap.md`：`modules/xhr` TODO `open/send/abort/headers 基础兼容层`

## Scope

Phase 4A lands the first usable embedded `XMLHttpRequest` subset:

- Install a global `XMLHttpRequest` constructor from optional `modules/xhr`.
- Support async-only `open(method, url[, async])`.
- Support `setRequestHeader`, `getResponseHeader`, `getAllResponseHeaders`.
- Support `send()` with no body, string body, `ArrayBuffer`, or `ArrayBufferView`.
- Support `abort()` for unsent/opened/loading requests and terminal event dispatch.
- Expose core state fields: `readyState`, `status`, `statusText`, `responseURL`, `responseText`, `response`.
- Dispatch `readystatechange`, `load`, `error`, `abort`, `timeout`, and `loadend` via `on*` handlers and `addEventListener`.
- Use Apple `NSURLSessionDataTask` through async native invoke.
- Enforce `EJSNetworkConfigurationKey` / `"ejs.network"` with `capabilities.xhr` and outbound rules.
- Default deny when no valid policy grants the request.

Phase 4A keeps response handling intentionally narrow:

- `responseType` supports only `""` and `"text"`.
- Non-text/binary/JSON response types remain Phase 4B.
- Redirect policy follows `NSURLSession` defaults; explicit redirect control is out of scope.
- Upload/download progress events are out of scope.

## Platform And Policy Boundary

- Root `platform/*` stays generic and must not parse XHR/network policy.
- `modules/xhr` owns policy parsing and request shaping.
- Because Phase 4A uses `NSURLSessionDataTask` and cannot pin preflight DNS
  results, default-deny resolved-address restrictions require IP-literal URLs.
  Hostname URLs are allowed only with outbound default allow and no
  private/link-local resolved-address restriction.
- System proxy use is disabled in Phase 4A; future proxy support must include
  proxy endpoint policy checks.
- No sync native invoke.
- No public native ABI growth unless required by the module installer pattern.
- No C++ and no libuv dependency.

## Likely Files

- `modules/xhr/js/xhr.js`
- `modules/xhr/cmake/generate_xhr_bundle.cmake`
- `modules/xhr/CMakeLists.txt`
- `modules/xhr/platform/apple/include/EJSXHRApple.h`
- `modules/xhr/platform/apple/src/EJSXHRApple.m`
- `modules/xhr/types/index.d.ts`
- `modules/xhr/README.md`
- `tests/js/network_js_test.js`
- `tests/xhr/apple/ejs_xhr_apple_test.m`
- `tests/CMakeLists.txt`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`

## Implementation Lane

- Single implementation lane:
  - keep edits scoped to `modules/xhr`, focused tests, and docs/status updates,
  - reuse the existing optional add-on installer/provider pattern from `modules/net`/`modules/worker`,
  - preserve root platform and net module boundaries.

## Regression Tests

JS wrapper tests:

- constructor initial state and event handler dispatch.
- `open` rejects sync requests and invalid methods/URLs.
- `setRequestHeader` only works after `open` and before `send`.
- mocked successful send drives `readystatechange`, `load`, `loadend`, headers, status, and `responseText`.
- mocked policy/native failures drive `error` and a diagnostic `EJSXHRError` or equivalent internal failure state without throwing from event dispatch.
- `abort()` before send and during send reaches aborted terminal state.

Apple tests:

- missing/disabled `capabilities.xhr` fails closed at request time.
- policy-denied request fails before native HTTP.
- local HTTP fixture returns status/body/headers.
- request headers reach the local fixture.
- response body policy limits fail closed.
- resolved private-address recheck fails closed for host-only rules when
  `denyPrivateNetworks` is enabled.
- unsupported `http.useSystemProxy: true` is rejected at install time.
- abort path is deterministic with a local delayed fixture.

## Verification Matrix

```sh
node --check modules/xhr/js/xhr.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m tests/CMakeLists.txt docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase4a_xhr_basic_execution_plan.md
```

The focused `ctest` command may require sandbox escalation because the Apple integration tests use localhost HTTP sockets.

## Evidence Log

- Baseline `node --check tests/js/network_js_test.js`: pass.
- Baseline `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Baseline `cmake --build build --target ejs_platform_boundary_check`: pass.
- Baseline `ctest --test-dir build -R "ejs_network_js_test|ejs_platform_boundary_test" --output-on-failure`: pass, 2/2 tests.
- `node --check modules/xhr/js/xhr.js`: pass.
- `node --check tests/js/network_js_test.js`: pass.
- `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- `cmake -S . -B build`: pass (regenerated build files to include `ejs_xhr_apple_test` target).
- `cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check`: pass.
- `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (sandboxed): failed (`ejs_xhr_apple_test` local fixture socket bind `Operation not permitted`).
- `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (escalated): pass, 3/3 tests.
- `git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m tests/CMakeLists.txt docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase4a_xhr_basic_execution_plan.md`: pass.
