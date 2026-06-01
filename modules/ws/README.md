# EJS WebSocket

`modules/ws` is an optional embedded WebSocket client add-on. It does not
depend on WinterTC, `modules/xhr`, or `modules/net`, and only installs into
contexts where the host explicitly calls `EJSWebSocketInstallIntoContext`.

Phase 5A currently implements:

- global `WebSocket` constructor installation;
- constants/state: `CONNECTING`/`OPEN`/`CLOSING`/`CLOSED`,
  `url/protocol/readyState/bufferedAmount/binaryType`;
- `onopen/onmessage/onerror/onclose`;
- `addEventListener/removeEventListener` for `open/message/error/close`;
- `send(string | ArrayBuffer | ArrayBufferView)`;
- `close(code?, reason?)` with close-code/reason validation.

Current non-goals in Phase 5A:

- WebSocket server support;
- `binaryType = "blob"` (only `"arraybuffer"` is supported);
- compression extensions / custom ping / reconnect behavior.

Apple implementation uses `NSURLSessionWebSocketTask` with module-owned policy
parsing from `ejs.network`, `capabilities.ws`, and outbound allow rules. It is
default-deny unless outbound rules or `outbound.default = "allow"` permit the
target URL. Because `NSURLSessionWebSocketTask` cannot pin preflight DNS
results, strict private/link-local checks are limited to IP-literal URLs;
hostname URLs require outbound default allow and no private/link-local
resolved-address restriction. `http.useSystemProxy: true` is explicitly
rejected in Phase 5A.

## API Shape

```js
const ws = new WebSocket("wss://example.com/socket", ["chat"]);
ws.binaryType = "arraybuffer";
ws.onopen = () => ws.send("hello");
ws.onmessage = (event) => console.log(event.data);
ws.onerror = (event) => console.error(event.error || event.message);
ws.onclose = (event) => console.log(event.code, event.reason);
```

## Verification

```sh
node --check modules/ws/js/ws.js
cmake --build build --target ejs_platform_boundary_check
ctest --test-dir build -R ejs_platform_boundary_test --output-on-failure
```
