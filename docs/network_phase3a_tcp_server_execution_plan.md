# Network Phase 3A TCP Server Execution Plan

Source: `docs/network_implementation_plan.md`
Date: 2026-05-28
Status: implemented and verified

## Scope

This branch extends `modules/net` after Phase 2B TCP client:

- `EJSNet.tcp.listen({ host, port, family, backlog, reuseAddress })`,
- listener `accept({ timeoutMs })`,
- accepted socket reuse of the existing TCP socket `read/write/shutdown/close`,
- listener idempotent `close()`,
- inbound policy checks for `capabilities.tcpListen`, address, port, and protocol,
- local loopback regression coverage for client-to-server echo and denied listen.

UDP, XHR, WebSocket, TLS, and multi-accept server framework behavior remain out of scope for this branch.

## Target Behavior

- Missing or disabled policy fails closed with `EPERM`.
- TCP listen requires `tcpListen: true` and an inbound allow rule matching address, port, and `tcp`.
- `port: 0` is allowed only for local bind/listen and returns the assigned local port.
- Native listener sockets run on the provider queue using POSIX sockets and bounded accept waits; JS owner thread is never blocked.
- JS does not expose native file descriptors, only listener/socket IDs wrapped by JS objects.
- `close()` is idempotent for listeners and sockets; operations after close reject with `ECANCELLED`.

## Expected File Scope

- `modules/net/**`
- `tests/js/network_js_test.js`
- `tests/net/apple/ejs_net_apple_test.m`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`
- `docs/network_phase3a_tcp_server_execution_plan.md`

## Implementation Lanes

- Subagent lane: implemented TCP server/listener API, Apple provider methods, policy parsing, type declarations, focused tests, and documentation reconciliation.
- Main lane: source review, issue reconciliation, final verification, and documentation evidence.

## Regression Tests

- `node --check modules/net/js/net.js`
- `node --check tests/js/network_js_test.js`
- `node tests/js/network_js_test.js`
- `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`
- `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`

## Evidence Log

- Baseline: `node --check modules/net/js/net.js` passed.
- Baseline: `node --check tests/js/network_js_test.js` passed.
- Baseline: `node tests/js/network_js_test.js` passed.
- Baseline: `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check` passed.
- Baseline: escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed, 3/3 tests.
- Implementation: `node --check modules/net/js/net.js` passed.
- Implementation: `node --check tests/js/network_js_test.js` passed.
- Implementation: `node tests/js/network_js_test.js` passed.
- Implementation: `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check` passed.
- Implementation: non-escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` failed in sandbox (`server bind failed: Operation not permitted`).
- Implementation: escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed, 3/3 tests.
- Main review fix: `port: 0` listen now does address/protocol pre-authorization with a sentinel and validates the assigned high port after `getsockname`; Apple loopback test now uses inbound `portRange: [1024, 65535]`.
- Main review fix: `tcpAccept` now holds the listener lock across `select`/`accept`, and listener close/dealloc call `shutdown(SHUT_RDWR)` before close to reduce close-vs-accept fd reuse risk.
- Main review verification: `node --check modules/net/js/net.js`, `node --check tests/js/network_js_test.js`, `node tests/js/network_js_test.js`, `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`, and escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed.
- Double-review finding fixed: listener close no longer waits for accept timeout; listener state now has a cancel pipe, `close()` writes to it, and pending `accept()` returns `ECANCELLED`.
- Double-review finding fixed: `port: 0` final authorization uses the actual `getsockname` address and byte-normalized address matching, reducing IPv6 equivalent-string false rejects.
- Double-review finding fixed: policy booleans now require JSON booleans; numeric `tcpListen`, string `denyPrivateNetworks`, and non-object `inbound` are invalid install-time policy errors.
- Double-review finding fixed: local socket close-race errors in read/write map to `ECANCELLED` when local close is in progress.
- Double-review test closure: added Apple coverage for assigned-port policy denial, `accept` timeout, and pending `accept` cancellation; added Node mock coverage for `accept` timeout.
- Double-review rejected/deferred: changing resolved-address fallback from host-allow semantics to unconditional deny was not applied because it would reject valid host allow rules without a CIDR requirement. Existing private/link-local deny flags still gate dangerous rebinding classes; stricter per-host resolved CIDR binding should be a separate policy extension.
- Final after double-review fixes: `node --check modules/net/js/net.js`, `node --check tests/js/network_js_test.js`, `node tests/js/network_js_test.js`, `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`, and escalated `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure` passed.
- Final hygiene: focused trailing-whitespace scan over Phase 3A files passed; focused `git diff --check -- docs/design.md docs/module_alignment_roadmap.md` passed.
- Known unrelated hygiene: full `git diff --check` still fails on pre-existing trailing whitespace in `tools/apple/examples/api_check.js:933,936,939,942,944,949,952,962`.
