# Network Phase 2A Lookup Execution Plan

Source: `docs/network_implementation_plan.md`
Date: 2026-05-28
Status: implemented

## Scope

This branch implements the first Phase 2 slice for `modules/net`:

- shared network policy parsing for Apple `modules/net`,
- `EJSNetworkConfigurationKey` / `"ejs.network"`,
- fail-closed DNS policy behavior,
- JavaScript `EJSNet.lookup(host, options)`,
- stable `EJSNetworkError` shaping in the JS wrapper,
- local-only regression tests.

TCP client, TCP server, UDP, XHR, and WebSocket remain out of scope for this branch.

## Target Behavior

- Installing `EJSNet` without `ejs.network` policy succeeds, but `lookup()` rejects with `EPERM`.
- Malformed or semantically invalid policy JSON makes `EJSNetInstallIntoContext(...)` fail.
- Policy must explicitly enable `capabilities.dns` and allow the requested host through `outbound.allow`.
- `lookup(host, { family, all })` validates arguments and returns `{ address, family, canonicalName }` or an array when `all: true`.
- Native DNS uses asynchronous provider dispatch and `getaddrinfo`; no `invokeSync`, libuv, C++, or root `platform/*` network coupling.

## Expected File Scope

- `modules/net/**`
- `tests/net/apple/ejs_net_apple_test.m`
- `tests/js/network_js_test.js`
- `tests/CMakeLists.txt`
- `tools/apple/*` only if CLI installation needs `EJSNet`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`
- `docs/network_phase2a_lookup_execution_plan.md`

## Implementation Lanes

1. JS wrapper and error shaping.
2. Apple installer/provider and policy parser.
3. Node mock tests and Apple local DNS tests.
4. Documentation/status sync.

## Regression Tests

- `node --check modules/net/js/net.js`
- `node --check tests/js/network_js_test.js`
- `node tests/js/network_js_test.js`
- `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`
- `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`

## Evidence Log

- Baseline: `node --check modules/stdlib/ipaddr/js/ipaddr.js` passed.
- Baseline: `node --check tests/js/network_js_test.js` passed.
- Baseline: `node tests/js/network_js_test.js` passed.
- Baseline: `cmake --build build --target ejs_platform_boundary_check ejs_stdlib_apple_test` passed.
- Baseline: `ctest --test-dir build -R "ejs_network_js_test|ejs_platform_boundary_test|ejs_stdlib_apple_test" --output-on-failure` passed, 3/3 tests.
- `node --check modules/net/js/net.js` passed.
- `node --check tests/js/network_js_test.js` passed.
- `node tests/js/network_js_test.js` passed.
- `cmake -S . -B build` passed after adding the new `ejs_net_apple_test` target.
- `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check` passed.
- `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed, 3/3 tests.
- `git diff --check -- <network phase 0/1 + phase 2A touched files>` passed.
- Full `git diff --check` is still red because pre-existing unrelated whitespace remains in `tools/apple/examples/api_check.js`.
