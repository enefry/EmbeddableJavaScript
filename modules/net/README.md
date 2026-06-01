# EJSNet

`modules/net` is the raw network add-on. It is optional and must remain separate
from `core`, root `platform/*`, and WinterTC.

Current implementation scope is DNS lookup plus TCP client/server and UDP
bind/send/recv/close sockets on Apple.

## JavaScript API

```js
const one = await EJSNet.lookup("example.com", { family: 4 });
const all = await EJSNet.lookup("example.com", { family: 0, all: true });

const socket = await EJSNet.tcp.connect({
  host: "127.0.0.1",
  port: 8080,
  family: 4,
  noDelay: true,
  timeoutMs: 3000
});
await socket.write(new Uint8Array([112, 105, 110, 103]));
const chunk = await socket.read({ maxBytes: 4096 });
await socket.shutdown();
await socket.close();

const listener = await EJSNet.tcp.listen({
  host: "127.0.0.1",
  port: 0,
  family: 4,
  backlog: 128,
  reuseAddress: true
});
const accepted = await listener.accept({ timeoutMs: 3000 });
await accepted.close();
await listener.close();

const udpA = await EJSNet.udp.bind({
  host: "127.0.0.1",
  port: 0,
  family: 4,
  reuseAddress: true
});
const udpB = await EJSNet.udp.bind({
  host: "127.0.0.1",
  port: 0,
  family: 4
});
await udpA.send(new Uint8Array([112, 105, 110, 103]), {
  host: "127.0.0.1",
  port: udpB.localAddress.port,
  family: 4
});
const packet = await udpB.recv({ maxBytes: 65507, timeoutMs: 3000 });
await udpA.close();
await udpB.close();
```

`lookup()` returns `{ address, family, canonicalName }` by default and an array
when `all: true`.

`EJSNet.tcp.connect()` and `listener.accept()` return an `EJSTCPSocket` object
with `localAddress`, `remoteAddress`, `read`, `write`, `shutdown`, and
idempotent `close`. `EJSNet.tcp.listen()` returns an `EJSTCPListener` with
`localAddress`, `accept`, and idempotent `close`. The JS API never exposes
POSIX file descriptors.

`EJSNet.udp.bind()` returns an `EJSUDPSocket` with `localAddress`, `send`,
`recv`, and idempotent `close`. `recv()` returns one datagram at a time as
`{ data: Uint8Array, remoteAddress }`.

Provider failures are shaped by the JavaScript wrapper as `EJSNetworkError` with
fields such as `code`, `module`, `operation`, `syscall`, `host`, `family`,
`nativeDomain`, and `nativeCode`.

For provider `Network` failures, the wrapper keeps a stable code mapping when
native detail is available: POSIX `ECONNREFUSED`, `ECONNRESET` (and peer-reset
class), `EHOSTUNREACH`, `ENETUNREACH`, and timeout-class errors map to
`ECONNREFUSED`, `ECONNRESET`, `EHOSTUNREACH`, `ENETUNREACH`, and `ETIMEOUT`.
`getaddrinfo` failures (`lookup` and connect/send resolution) map to `EDNS`.
The original `nativeDomain/nativeCode` values are preserved for diagnostics.

## Apple Notes

The Apple provider reads `EJSNetworkConfigurationKey` / `"ejs.network"` policy
at install time. Missing policy installs successfully but fails closed: `lookup`
rejects with `EPERM`. Malformed policy fails installation.

DNS uses asynchronous provider dispatch and `getaddrinfo`. TCP client sockets use
non-blocking POSIX sockets on a provider-owned queue. The provider does not use
`invokeSync`, libuv, C++, or root `platform/*` network hooks.

TCP connect requires `capabilities.tcpConnect: true` and an outbound allow rule
matching host, port, and the `tcp` protocol. TCP listen requires
`capabilities.tcpListen: true` and an inbound allow rule matching address, port,
and `tcp`; `port: 0` is accepted for local bind allocation and returns the
assigned local port.

UDP requires `capabilities.udp: true`. UDP bind is checked against inbound
allow rules with `protocols: ["udp"]`, and UDP send is checked against outbound
allow rules with `protocols: ["udp"]`; TCP authorization does not imply UDP.
Remote UDP ports must match an explicit `ports` or `portRange` rule, and the
resolved address must also match an allowed CIDR or literal IP rule unless the
policy default allows outbound traffic. For `port: 0` binds, the assigned local
port is rechecked against inbound policy. UDP datagrams are bounded by
`limits.maxDatagramBytes` and the protocol maximum. `close()` is idempotent, and
operations after close reject as `ECANCELLED`.

## Verification

```sh
node --check modules/net/js/net.js
node tests/js/network_js_test.js
cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure
```
