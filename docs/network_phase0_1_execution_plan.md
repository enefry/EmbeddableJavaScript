# Network Phase 0/1 Execution Plan

Source: `docs/network_implementation_plan.md`
Date: 2026-05-28
Status: implemented

## Scope

This delivery covers the first bounded slice of stage 3 network work:

- Phase 0 contract and boundary setup.
- Phase 1 `modules/stdlib/ipaddr`.

Native DNS, TCP, UDP, XHR, and WebSocket I/O remain out of scope for this slice.

## Target Behavior

- `docs/design.md` summarizes the stage 3 network architecture without claiming native I/O is already implemented.
- `ejs_platform_boundary_check` rejects root `platform/*` references to network module implementation names.
- `modules/net`, `modules/xhr`, and `modules/ws` exist as add-on skeletons with README and type contracts only.
- `modules/stdlib/ipaddr` provides pure JS IPv4, IPv6, and CIDR parsing helpers through `globalThis.EJSIPAddr`.
- `EJSIPAddr` is installable into Apple contexts through a bundle-only add-on and has Node-side JS regression coverage.

## Expected File Scope

- `CMakeLists.txt`
- `cmake/check_platform_boundary.cmake`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_phase0_1_execution_plan.md`
- `modules/net/README.md`
- `modules/net/types/index.d.ts`
- `modules/xhr/README.md`
- `modules/xhr/types/index.d.ts`
- `modules/ws/README.md`
- `modules/ws/types/index.d.ts`
- `modules/stdlib/ipaddr/**`
- `tests/CMakeLists.txt`
- `tests/js/network_js_test.js`
- `tests/stdlib/apple/ejs_stdlib_apple_test.m`

## Implementation Lanes

1. Phase 0 docs and boundary checks.
2. Network module README/type skeletons.
3. Pure JS `EJSIPAddr` parser and Apple bundle installer.
4. Node and Apple regression tests.

## Regression Tests

- `node --check modules/stdlib/ipaddr/js/ipaddr.js`
- `node --check tests/js/network_js_test.js`
- `node tests/js/network_js_test.js`
- `cmake --build build --target ejs_platform_boundary_check ejs_stdlib_apple_test`
- `ctest --test-dir build -R "ejs_network_js_test|ejs_platform_boundary_test|ejs_stdlib_apple_test" --output-on-failure`

## Evidence Log

- Baseline: `cmake --build build --target ejs_platform_boundary_check ejs_stdlib_apple_test` passed.
- Baseline: `ctest --test-dir build -R "ejs_platform_boundary_test|ejs_stdlib_apple_test" --output-on-failure` passed, 2/2 tests.
- `node --check modules/stdlib/ipaddr/js/ipaddr.js` passed.
- `node --check tests/js/network_js_test.js` passed.
- `node tests/js/network_js_test.js` passed.
- `cmake --build build --target ejs_platform_boundary_check ejs_stdlib_apple_test` passed.
- `ctest --test-dir build -R "ejs_network_js_test|ejs_platform_boundary_test|ejs_stdlib_apple_test" --output-on-failure` passed, 3/3 tests.
- `ctest --test-dir build -R ejs_platform_boundary_negative_test --output-on-failure` passed, 1/1 test.
- `git diff --check -- <network phase 0/1 touched files>` passed.
- Full `git diff --check` is still red because pre-existing unrelated whitespace remains in `tools/apple/examples/api_check.js`.
