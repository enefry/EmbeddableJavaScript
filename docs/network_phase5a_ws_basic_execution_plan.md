# Network Phase 5A WebSocket Basic Execution Plan

更新时间：2026-05-29
状态：`completed`

源计划：

- `docs/network_implementation_plan.md` Phase 5：`modules/ws`
- `docs/module_alignment_roadmap.md`：`modules/ws` TODO `WebSocket 状态机与 onopen/onmessage/onerror/onclose`、`sendText/sendBinary/close(code, reason)`

## Scope

Phase 5A lands the first usable embedded WebSocket client subset:

- Install a global `WebSocket` constructor from optional `modules/ws`.
- Support `new WebSocket(url[, protocols])` for `ws:` and `wss:` URLs.
- Support constants and instance state: `CONNECTING`, `OPEN`, `CLOSING`, `CLOSED`, `url`, `protocol`, `readyState`, `bufferedAmount`, `binaryType`.
- Support event handlers and listeners for `open`, `message`, `error`, and `close`.
- Support `send(string | ArrayBuffer | ArrayBufferView)`.
- Support `close(code?, reason?)` with close-code and reason-byte validation.
- Use Apple `NSURLSessionWebSocketTask` through async native invoke.
- Enforce `EJSNetworkConfigurationKey` / `"ejs.network"` with `capabilities.ws`, outbound rules, and default-deny behavior.

Phase 5A keeps compatibility intentionally narrow:

- Client only; no WebSocket server.
- `binaryType` supports `"arraybuffer"` and `"blob"` is rejected or treated as unsupported because EJS has no Blob module.
- Browser CORS and document-origin semantics are out of scope; `ejs.network` policy is the authority.
- Compression extensions, custom ping/pong API, cookies, and automatic reconnect are out of scope.
- Public subprotocol negotiation is limited to provider-returned selected protocol.

## Platform And Policy Boundary

- Root `platform/*` stays generic and must not parse WS/network policy.
- `modules/ws` owns policy parsing, request shaping, provider IDs, and event mapping.
- `modules/ws` does not depend on WinterTC, XHR, or `modules/net`.
- Apple uses `NSURLSessionWebSocketTask`; no C++, no libuv, and no synchronous native invoke.
- System proxy use is disabled in Phase 5A unless a future policy model can authorize proxy endpoints.
- Because Phase 5A uses `NSURLSessionWebSocketTask` and cannot pin preflight
  DNS results, default-deny resolved-address restrictions require IP-literal
  URLs. Hostname URLs are allowed only with outbound default allow and no
  private/link-local resolved-address restriction.

## Likely Files

- `modules/ws/js/ws.js`
- `modules/ws/cmake/generate_ws_bundle.cmake`
- `modules/ws/CMakeLists.txt`
- `modules/ws/platform/apple/include/EJSWebSocketApple.h`
- `modules/ws/platform/apple/src/EJSWebSocketApple.m`
- `modules/ws/types/index.d.ts`
- `modules/ws/README.md`
- `tests/js/network_js_test.js`
- `tests/ws/apple/ejs_ws_apple_test.m`
- `tests/CMakeLists.txt`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`

## Implementation Lane

- Single implementation lane:
  - keep edits scoped to `modules/ws`, focused tests, and docs/status updates,
  - reuse the optional add-on installer/provider pattern from `modules/xhr`,
  - mirror `ejs.network` parsing boundaries from XHR without moving policy into root platform,
  - preserve the existing network/XHR behavior.

## Regression Tests

JS wrapper tests:

- constructor constants, initial state, handler/listener dispatch.
- URL and protocol argument validation.
- mocked native open success drives `open` and selected protocol.
- mocked text and binary native messages dispatch `message`.
- `binaryType = "arraybuffer"` returns `ArrayBuffer` for binary payloads.
- `send()` rejects before open and after closing/closed, and shapes text/binary payloads correctly.
- `close()` validates code/reason, sends native close once, and reaches `CLOSED`.
- native error and native close dispatch terminal events exactly once.

Apple tests:

- missing/default-deny `capabilities.ws` fails closed at request time.
- disabled `capabilities.ws` fails closed.
- policy-denied URL fails before native task.
- unsupported `http.useSystemProxy: true` is rejected at install time.
- local WebSocket echo fixture covers open, text echo, binary echo, close, and abort/cancel when feasible.
- If a fully local native WebSocket server is too large for this phase, Apple integration may focus on policy/install/request-shaping and JS mock coverage must cover the state machine.

## Verification Matrix

```sh
node --check modules/ws/js/ws.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_ws_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_ws_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/ws tests/js/network_js_test.js tests/ws/apple/ejs_ws_apple_test.m tests/CMakeLists.txt docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase5a_ws_basic_execution_plan.md
```

Local socket or WebSocket fixture tests may require sandbox escalation.

## Evidence Log

- `node --check modules/ws/js/ws.js`: pass.
- `node --check tests/js/network_js_test.js`: pass.
- `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- `cmake --build build --target ejs_ws_apple_test ejs_platform_boundary_check`: pass.
- `ctest --test-dir build -R "ejs_network_js_test|ejs_ws_apple_test|ejs_platform_boundary_test" --output-on-failure`: pass, 3/3 tests.
- Review fix: late native `open` after `close()` during `CONNECTING` is ignored; JS regression added.
- Review fix: WebSocket URLs with fragments are rejected; JS regression added.
- Review fix: Apple provider now enforces single pending `nextEvent` waiter per socket and drains waiters on socket cleanup; Apple regression added for duplicate waiter rejection.
- Review fix: Apple provider send completion now returns errors even when socket state was concurrently removed.
- Review fix: Apple provider now applies XHR-style IP-literal private/link-local and hostname unpinned policy checks; Apple regressions added for private-address, hostname, and link-local denial.
- `git diff --check -- modules/ws tests/js/network_js_test.js tests/ws/apple/ejs_ws_apple_test.m tests/CMakeLists.txt docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase5a_ws_basic_execution_plan.md`: pass.

说明：

- 本轮未引入本地 native WebSocket echo server，优先覆盖了 JS mock 状态机与 Apple policy/install/request-shaping 路径。
- send-close completion 竞态仍需要本地 WebSocket echo 或 provider test seam 才能稳定覆盖，保留到 Phase 5B/收口验证。
