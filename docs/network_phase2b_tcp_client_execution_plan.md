# Network Phase 2B TCP Client Execution Plan

Source: `docs/network_implementation_plan.md`
Date: 2026-05-28
Status: implemented and verified

## Scope

This branch extends `modules/net` after Phase 2A DNS lookup:

- `EJSNet.tcp.connect({ host, port, family, localAddress, noDelay, keepAlive, timeoutMs })`,
- `socket.read({ maxBytes })`,
- `socket.write(data)`,
- `socket.shutdown()`,
- idempotent `socket.close()`,
- policy checks for `capabilities.tcpConnect`, host/address, port, and protocol,
- local loopback regression coverage.

TCP server, UDP, XHR, and WebSocket remain out of scope for this branch.

## Target Behavior

- Missing or disabled policy still fails closed with `EPERM`.
- TCP connect requires `tcpConnect: true` and an outbound allow rule matching host, port, and `tcp`.
- Native connect runs on the provider queue using POSIX sockets and bounded timeouts; JS owner thread is never blocked.
- JS does not expose native file descriptors, only socket IDs wrapped by JS objects.
- `close()` is idempotent; operations after close reject with `ECANCELLED`.

## Expected File Scope

- `modules/net/**`
- `tests/js/network_js_test.js`
- `tests/net/apple/ejs_net_apple_test.m`
- `tests/CMakeLists.txt`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`
- `docs/network_phase2b_tcp_client_execution_plan.md`

## Regression Tests

- `node --check modules/net/js/net.js`
- `node --check tests/js/network_js_test.js`
- `node tests/js/network_js_test.js`
- `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`
- `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`

## Evidence Log

- Baseline: `node --check modules/net/js/net.js` passed.
- Baseline: `node tests/js/network_js_test.js` passed.
- Baseline: `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check` passed.
- Baseline: `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed, 3/3 tests.
- Final: `node --check modules/net/js/net.js` passed.
- Final: `node --check tests/js/network_js_test.js` passed.
- Final: `node tests/js/network_js_test.js` passed.
- Final: `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check` passed.
- Final: sandboxed `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` failed because local loopback `bind` returned `Operation not permitted`.
- Final: escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed, 3/3 tests.
- Review fix: non-lookup provider network failures now map to `ENETWORK` instead of DNS-specific `EDNS`; Node mock coverage added for TCP connect error shaping.
- Review fix: `close()` now calls `shutdown(SHUT_RDWR)` before taking the socket lock so pending reads/writes are interrupted before fd close.
- Final after review fixes: `node tests/js/network_js_test.js`, `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`, and escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed.
- Final hygiene: focused trailing-whitespace scan over Phase 2B files passed; focused `git diff --check -- docs/design.md docs/module_alignment_roadmap.md` passed.
- Known unrelated hygiene: full `git diff --check` still fails on pre-existing trailing whitespace in `tools/apple/examples/api_check.js:933,936,939,942,944,949,952,962`.
