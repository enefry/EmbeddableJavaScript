# Network Phase 3B UDP Execution Plan

更新时间：2026-05-28
状态：`implementation complete; review closure complete; verification complete`

源计划：`docs/network_implementation_plan.md` Phase 3 `modules/net` UDP `bind/send/recv/close`。

## Scope

Phase 3B completes the first POSIX-oriented UDP surface for `modules/net`:

- `EJSNet.udp.bind({ host, port, family, reuseAddress, ipv6Only })`
- UDP socket instance methods:
  - `send(data, { host, port, family })`
  - `recv({ maxBytes, timeoutMs })`
  - `close()`
- `udp.localAddress` metadata with `{ address, port, family }`
- idempotent close semantics
- pending `recv` cancellation on close with stable `ECANCELLED`

## Security And Semantics

- Network policy remains fail-closed.
- `capabilities.udp` must be true before any UDP bind/send.
- `bind` is authorized by inbound rules with `protocols: ["udp"]`.
- `send` is authorized by outbound rules with `protocols: ["udp"]`.
- TCP authorization does not imply UDP authorization.
- `port: 0` is allowed only for local bind. After binding, the assigned port is rechecked against inbound policy.
- Remote UDP sends must target an explicit allowed remote port or port range.
- JS does not expose native file descriptors.
- UDP datagrams are bounded by `limits.maxDatagramBytes` and the protocol maximum.
- `recv` returns one datagram at a time and does not create an unbounded native queue.

## Out Of Scope

- multicast and broadcast
- connected UDP sockets
- Unix domain sockets
- IPv6-only edge-case expansion beyond existing socket option plumbing
- XHR/WebSocket implementation
- root `platform/*` network-specific policy parsing

## Likely Files

- `modules/net/js/net.js`
- `modules/net/types/index.d.ts`
- `modules/net/platform/apple/include/EJSNetApple.h`
- `modules/net/platform/apple/src/EJSNetApple.m`
- `modules/net/README.md`
- `tests/js/network_js_test.js`
- `tests/net/apple/ejs_net_apple_test.m`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`

## Implementation Lane

- Main thread:
  - save this plan,
  - run baseline verification,
  - dispatch one bounded implementation worker,
  - inspect and reconcile the worker result,
  - run final tests and update docs.
- Worker:
  - implement Phase 3B only,
  - preserve existing DNS/TCP behavior,
  - avoid unrelated dirty files and destructive git operations.

## Regression Tests

JS wrapper tests:

- `EJSNet.udp.bind` option validation
- UDP socket `send` payload normalization
- `recv` response shaping into `Uint8Array`
- post-close `send`/`recv` errors as `ECANCELLED`
- malformed native UDP responses become `EINVAL`
- malformed native UDP bind responses become `EINVAL`

Apple integration tests:

- missing or disabled `capabilities.udp` denies bind/send
- inbound UDP policy denies disallowed bind port
- `port: 0` bind is rechecked against assigned local port
- outbound UDP rules without explicit `ports`/`portRange` deny sends
- host precheck without resolved IP/CIDR match denies sends
- `limits.maxDatagramBytes` bounds UDP send and recv
- loopback UDP send/recv between two sockets succeeds
- `recv` timeout maps to `ETIMEOUT`
- pending `recv` canceled by `close` maps to `ECANCELLED`
- `close` remains idempotent

## Verification Matrix

Run after baseline and after implementation:

```sh
node --check modules/net/js/net.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/net tests/js/network_js_test.js tests/net/apple/ejs_net_apple_test.m docs/network_phase3b_udp_execution_plan.md
```

The focused `ctest` command may require sandbox escalation because the Apple integration tests use localhost sockets.

## Evidence Log

- Baseline `node --check modules/net/js/net.js`: pass.
- Baseline `node --check tests/js/network_js_test.js`: pass.
- Baseline `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Baseline `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`: pass.
- Baseline sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`: failed in `ejs_net_apple_test` with `expected=EJSNetworkError:EPERM:0 actual=EJSNetworkError:ENETWORK:0`.
- Baseline escalated same `ctest` command for localhost sockets: pass, 3/3 tests.
- Post-implementation `node --check modules/net/js/net.js`: pass.
- Post-implementation `node --check tests/js/network_js_test.js`: pass.
- Post-implementation `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Post-implementation `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`: pass.
- Post-implementation sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`: failed in `ejs_net_apple_test` with `expected=EJSNetworkError:EPERM:0 actual=EJSNetworkError:ENETWORK:0`.
- Post-implementation escalated same `ctest` command for localhost sockets: pass, 3/3 tests.
- Review closure agent `Dirac`: found resolved-address fail-open, UDP rules without explicit port constraints, malformed UDP bind response handling.
- Review closure agent `Pauli`: independently found resolved-address fail-open, UDP `EAGAIN` retry gap, missing `limits.maxDatagramBytes` enforcement.
- Fixed review findings:
  - resolved-address second-pass policy now requires default allow or a matching CIDR/literal-IP rule; UDP still requires explicit `udp` protocol and port constraint,
  - UDP sends require explicit outbound `ports` or `portRange`,
  - malformed UDP bind responses throw `EJSNetworkError` with `EINVAL`,
  - UDP send retries the same address after `EAGAIN`/`EWOULDBLOCK`,
  - native policy parses and enforces `limits.maxDatagramBytes`,
  - regressions added for UDP no-port deny, resolved-address deny, datagram limits, malformed bind response, and invalid limit policy.
- Post-review `node --check modules/net/js/net.js`: pass.
- Post-review `node --check tests/js/network_js_test.js`: pass.
- Post-review `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Post-review `cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check`: pass.
- Post-review sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`: failed in `ejs_net_apple_test` with the known localhost sandbox artifact.
- Post-review escalated same `ctest` command for localhost sockets: pass, 3/3 tests.
- Final focused `git diff --check -- modules/net tests/js/network_js_test.js tests/net/apple/ejs_net_apple_test.m docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase3b_udp_execution_plan.md`: pass.
- Final sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure`: failed in `ejs_net_apple_test` with the known localhost sandbox artifact.
- Final escalated same `ctest` command for localhost sockets: pass, 3/3 tests.
