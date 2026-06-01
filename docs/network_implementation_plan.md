# EJS 阶段3：网络模块实施规划

更新时间：2026-05-29
状态：`Phase 0/1 + Phase 2A DNS lookup + Phase 2B TCP client + Phase 3A TCP server + Phase 3B UDP + Phase 3C error diagnostics + Phase 4A/4B/4C XHR + Phase 5A WS 已落地`

本文档细化 `docs/module_alignment_roadmap.md` 中“阶段3（网络模块）”的实施路径。阶段3目标是让 `ws/net/xhr/ipaddr` 基础能力可用、网络错误可诊断，并继续保持 EJS 的嵌入式安全边界。

## 1. 总体边界

### 1.1 必须遵守的约束

1. **可选 Add-on 架构**：`modules/net`、`modules/xhr`、`modules/ws`、`modules/stdlib/ipaddr` 均是独立 add-on。`core` 和 root `platform/*` 只提供通用 provider/配置/生命周期能力，不写网络私有策略，不自动安装网络模块。
2. **API 语义以 POSIX 为基线**：`net` 的 DNS、TCP、UDP 行为以 POSIX socket/getaddrinfo/errno 语义为准，JS 层做易用封装。这样 Android、Linux、Windows 等平台后续更容易实现同一语义。
3. **Apple 实现不引入 C++**：Apple provider 使用 Objective-C `.m` 和必要的 C/POSIX API；不新增 `.mm`/C++ 类型，不向 public header 暴露 C++。
4. **模块不依赖 libuv**：网络 add-on 不直接依赖 core 内部 libuv loop，也不包含 `uv_*` API。Apple raw socket 首版使用 POSIX 非阻塞 socket + provider-owned queue/source；高层 HTTP/WS 使用系统 SDK。
5. **高层协议优先系统栈**：`modules/xhr` 使用 `NSURLSession`；`modules/ws` 使用 `NSURLSessionWebSocketTask`。不引入 curl、Boost.Asio、第三方 HTTP/WebSocket parser。
6. **不能阻塞 JS owner thread**：所有 DNS、socket、HTTP、WS 操作都走 `__ejs_native__.invoke` 的异步 provider 路径；`invokeSync` 只允许 bounded/non-blocking 能力，网络模块不得使用。
7. **JS wrapper 负责易用性，Native 负责策略与 I/O**：JS 侧做参数校验、事件模型、Promise/iterator 包装和错误 shaping；native 侧做权限、DNS、socket/session 生命周期、buffer limit 和真实 I/O。

### 1.2 模块依赖方向

```text
Application
  -> modules/ws | modules/xhr | modules/net | modules/stdlib/ipaddr
  -> platform/apple
  -> core
```

`modules/xhr` 与 `modules/ws` 不依赖 WinterTC。现有 `modules/wintertc` 的 `fetch` provider 可作为 Apple `NSURLSession` 生命周期和 stream framing 的参考，但阶段3不能要求安装 WinterTC 才能使用 XHR/WS。

## 2. 安全模型

网络能力默认必须 **fail closed**：未配置策略时，模块安装可以成功但所有受限操作必须返回 `EPERM`/`ENOTSUP` 风格错误；策略 JSON 格式错误或字段非法时，模块安装必须失败，不得隐式放开网络。

### 2.1 配置入口

新增统一网络策略键：

- Apple 常量：`EJSNetworkConfigurationKey`
- 字符串 key：`"ejs.network"`

`modules/net`、`modules/xhr`、`modules/ws` 都读取同一份 JSON policy。每个 add-on 在安装时解析一次并冻结策略快照；root `platform/apple` 只保存和暴露字符串配置，不解析 schema。

示例：

```json
{
  "version": 1,
  "capabilities": {
    "dns": true,
    "tcpConnect": true,
    "tcpListen": false,
    "udp": false,
    "xhr": true,
    "ws": true
  },
  "outbound": {
    "default": "deny",
    "allow": [
      { "host": "api.example.com", "ports": [443], "protocols": ["tcp", "xhr", "ws"] },
      { "hostSuffix": ".example.test", "portRange": [8000, 8999], "protocols": ["tcp"] },
      { "cidr": "127.0.0.0/8", "portRange": [1024, 65535], "protocols": ["tcp", "udp"] }
    ],
    "denyPrivateNetworks": false,
    "denyLinkLocal": true
  },
  "inbound": {
    "default": "deny",
    "allow": [
      { "address": "127.0.0.1", "portRange": [0, 65535], "protocols": ["tcp"] }
    ]
  },
  "limits": {
    "connectTimeoutMs": 15000,
    "idleTimeoutMs": 30000,
    "requestTimeoutMs": 30000,
    "maxSockets": 64,
    "maxListeners": 8,
    "maxPendingAccept": 128,
    "maxDatagramBytes": 65507,
    "maxReadBufferBytes": 1048576,
    "maxWriteQueueBytes": 1048576,
    "maxHeaderBytes": 65536,
    "maxBodyBytes": 8388608
  },
  "tls": {
    "useSystemTrust": true,
    "allowInvalidCertificates": false
  },
  "http": {
    "useSystemProxy": false,
    "allowCookies": false,
    "allowRedirects": true
  }
}
```

### 2.2 授权规则

1. **先校验原始目标，再校验解析结果**：outbound 请求先按 host/port/protocol 检查 allowlist；DNS 解析后还要按 resolved IP/CIDR 再检查一次，避免 DNS rebinding 绕过。XHR Phase 4C 已改为 delegate buffering，但仍不做 preflight DNS pin，因此 default-deny + resolved-address 限制模式只允许 IP-literal URL；hostname URL 需要 outbound default allow 且不能启用 private/link-local resolved-address 限制。
2. **listen 与 connect 分离授权**：`tcpConnect` 不代表允许 `listen`；`tcpListen` 必须单独开启，并受 inbound address/port policy 限制。
3. **UDP 单独授权**：UDP 默认关闭。即使 TCP 允许，同 host/port 也不自动允许 UDP。
4. **0 端口只代表“系统分配本地端口”**：`port: 0` 只允许用于 `bind` 或 `localPort`，不代表允许任意远端端口。远端端口必须命中明确的 `ports` 或 `portRange`。
5. **TLS 不允许关闭系统校验**：`allowInvalidCertificates` 首版固定要求 `false`。如果未来支持 debug override，必须是测试构建或显式开发配置，不进入默认生产路径。
6. **Header/Cookie 受策略控制**：XHR/WS 禁止 JS 设置 hop-by-hop 或敏感 header；cookie 默认不持久化，除非 policy 显式允许。
7. **不暴露 native fd**：JS API 不返回 POSIX fd，避免跨平台不可移植和 sandbox escape 风险。JS 只持有 socket/listener/session ID 或包装对象。
8. **错误不泄露敏感数据**：错误对象可以包含 host/address/port/native code，但不得包含 request body、Authorization、Cookie、完整 header 值。

### 2.3 Worker 继承策略

Worker 子上下文不能自动扩大网络权限。父上下文创建 Worker 时，只能继承同一份 `ejs.network` 配置或传入更严格的子策略。子策略扩大能力时必须拒绝创建 Worker 或拒绝安装网络 add-on。

## 3. 错误模型

Provider 使用 `EJSProviderErrorCode` 做第一层映射，JS wrapper 再生成稳定的 `EJSNetworkError`：

```js
{
  name: "EJSNetworkError",
  code: "ECONNREFUSED",
  module: "net",
  operation: "connect",
  syscall: "connect",
  host: "127.0.0.1",
  address: "127.0.0.1",
  port: 65535,
  family: 4,
  nativeDomain: "NSPOSIXErrorDomain",
  nativeCode: 61,
  message: "connect 127.0.0.1:65535 failed: connection refused"
}
```

建议错误码：

| JS code | Provider code | 场景 |
| --- | --- | --- |
| `EINVAL` | `InvalidArgument` | 参数错误、非法 IP/CIDR、非法 header |
| `EPERM` | `Security` | policy 拒绝、未授权 host/port/protocol |
| `ENOTSUP` | `Unsupported` | 当前平台不支持、禁用能力 |
| `ETIMEOUT` | `Timeout` | DNS/connect/read/write/request timeout |
| `ECONNREFUSED` | `Network` | TCP connect refused |
| `ECONNRESET` | `Network` | peer reset/WS abnormal close |
| `EHOSTUNREACH` | `Network` | host unreachable |
| `ENETUNREACH` | `Network` | network unreachable |
| `EDNS` | `Network` | DNS 解析失败 |
| `ETLS` | `TLS` | TLS 握手/证书错误 |
| `ECANCELLED` | `Aborted` | abort/close/cancel |

错误对象必须尽量包含目标 host、解析后的 address、port、family、operation/syscall。DNS 失败没有 address 时应省略 address，而不是填空字符串。

## 4. API 设计

### 4.1 `modules/stdlib/ipaddr`

纯 JS 模块，无 native provider，无网络权限要求。

目标 API：

```js
EJSIPAddr.isValidIPv4(value);
EJSIPAddr.isValidIPv6(value);
EJSIPAddr.parse(value);
EJSIPAddr.parseCIDR(value);
EJSIPAddr.contains(cidr, address);
EJSIPAddr.normalize(value);
```

首版范围：

- IPv4 dotted decimal 严格解析，不接受八进制/十六进制混写。
- IPv6 支持 `::` 压缩、IPv4-mapped IPv6、zone id 拒绝或明确文档化。
- CIDR 校验 prefix range，返回 `{ address, family, prefixLength, normalized }`。
- 为 network policy 的 CIDR 检查提供内部可复用函数，但不暴露 native 依赖。

### 4.2 `modules/net`

`modules/net` 是 POSIX-oriented raw network add-on。对外暴露 `EJSNet`，不污染 Node.js 全局对象，不承诺完整 Node `net`/`dgram` 兼容；命名尽量贴近常见 socket 语义，便于迁移。

DNS：

```js
const one = await EJSNet.lookup("example.com", { family: 4 });
const all = await EJSNet.lookup("example.com", { family: 0, all: true });
```

返回：

```js
{ address: "93.184.216.34", family: 4, canonicalName: "" }
```

TCP client：

```js
const socket = await EJSNet.tcp.connect({
  host: "127.0.0.1",
  port: 8080,
  family: 4,
  localAddress: "127.0.0.1",
  noDelay: true,
  keepAlive: { enabled: true, initialDelayMs: 30000 },
  timeoutMs: 5000
});

await socket.write(new Uint8Array([1, 2, 3]));
const chunk = await socket.read({ maxBytes: 65536 });
await socket.shutdown();
await socket.close();
```

TCP server：

```js
const server = await EJSNet.tcp.listen({
  host: "127.0.0.1",
  port: 0,
  backlog: 128,
  reuseAddr: true,
  ipv6Only: false
});

const address = server.localAddress;
const socket = await server.accept();
await server.close();
```

UDP：

```js
const udp = await EJSNet.udp.bind({
  host: "127.0.0.1",
  port: 0,
  reuseAddr: true,
  ipv6Only: false
});

await udp.send(new Uint8Array([1]), { host: "127.0.0.1", port: 9999 });
const datagram = await udp.recv({ maxBytes: 65507 });
await udp.close();
```

对象语义：

- `close()` 幂等，返回 Promise。
- pending `read/accept/recv` 在 `close()` 后以 `ECANCELLED` reject。
- `write/send` 必须受 `maxWriteQueueBytes`/`maxDatagramBytes` 限制。
- `read/recv` 默认一次返回一个 chunk/datagram，不做无限缓存。
- `socket.localAddress` / `socket.remoteAddress` 返回 `{ address, port, family }`。
- 不支持 raw fd、`fork` 后 fd 继承、Unix domain socket、multicast、broadcast；这些可作为后续扩展。

Apple 实施：

- DNS 使用 `getaddrinfo` 在 provider-owned queue 执行，不在 owner thread 同步阻塞。
- TCP/UDP 使用 POSIX nonblocking socket。
- socket readiness 使用 provider-owned dispatch source 或等价 Apple C/ObjC 机制，不使用 libuv。
- socket state table 以 native ID 管理，context invalidate/runtime teardown 时统一 cancel 并释放。

### 4.3 `modules/xhr`

`modules/xhr` 提供浏览器 `XMLHttpRequest` 的嵌入式子集。安装 add-on 后注册 `globalThis.XMLHttpRequest`，同时可暴露只读 `EJSXHR` 诊断对象。

Phase 4C 当前支持：

- `new XMLHttpRequest()`
- `open(method, url, async = true)`
- `setRequestHeader(name, value)`
- `send(body?)`
- `abort()`
- `getResponseHeader(name)` / `getAllResponseHeaders()`
- `readyState`、`status`、`statusText`、`responseURL`
- `responseType`: `""`/`"text"`/`"arraybuffer"`/`"json"`
- `onreadystatechange`、`onloadstart`、`onprogress`、`onload`、`onerror`、`ontimeout`、`onabort`、`onloadend`
- success path 稳定顺序：`readystatechange(OPENED)`（`open` 后）-> `loadstart`（`send` 后）-> `HEADERS_RECEIVED/LOADING` -> `progress` -> `DONE` -> `load` -> `loadend`
- `progress` event 提供 `loaded`、`total`、`lengthComputable`
- `abort()` 回到 `UNSENT`，active request 派发 `abort + loadend`
- `responseType="json"` 在 JS wrapper 解析 UTF-8 JSON，invalid JSON 保留 `OPENED/HEADERS_RECEIVED/LOADING/DONE` readyState 过渡后走 `error + loadend`

Phase 4C 不支持：

- 同步 XHR。
- `document` / XML parser。
- 浏览器 CORS 语义。EJS 是嵌入式 runtime，跨域策略由 `ejs.network` policy 控制。
- 自动持久 cookie，除非 policy 显式允许。
- upload progress event target 和增量 streaming progress。

Apple 实施：

- 使用 module-owned `NSURLSession` delegate buffering。
- policy 限制 scheme/host/port/header/body size/timeout。
- response body 在 `didReceiveData` 超过 `maxBodyBytes` 时立即 cancel 并返回 `EPERM` 风格错误，不等待完整响应下载。
- `arraybuffer` 响应通过 bounded JSON payload 中的 base64 字段回传，不扩展 provider responder ABI。
- `abort()` 必须 cancel native task，并保证事件顺序稳定：`abort` -> `loadend`。

### 4.4 `modules/ws`

`modules/ws` 提供 WebSocket client。安装 add-on 后注册 `globalThis.WebSocket`，同时可暴露只读 `EJSWebSocket` 诊断对象。

首版 API：

```js
const ws = new WebSocket("wss://example.com/socket", ["chat"]);
ws.binaryType = "arraybuffer";
ws.onopen = () => {};
ws.onmessage = (event) => {};
ws.onerror = (event) => {};
ws.onclose = (event) => {};
ws.send("hello");
ws.send(new Uint8Array([1, 2, 3]));
ws.close(1000, "done");
```

兼容目标：

- `CONNECTING`/`OPEN`/`CLOSING`/`CLOSED` constants。
- `url`、`protocol`、`readyState`、`bufferedAmount`、`binaryType`。
- `send(string | ArrayBuffer | ArrayBufferView)`。
- `close(code?, reason?)` 校验 code/reason。
- `message` event 的 `data` 根据 `binaryType` 返回 string 或 ArrayBuffer。

首版不做 WebSocket server。需要 server 能力时先通过 `modules/net` 的 TCP server 提供基础设施，后续再规划协议层。

Apple 实施：

- 使用 `NSURLSessionWebSocketTask`。
- native 侧负责 handshake、ping/pong、frame 收发和 close code/reason。
- JS 侧负责标准事件派发和 readyState 状态机。
- `close()`、context invalidate、runtime teardown 必须都能取消 task，并保证不会重复派发 terminal event。

## 5. 实施顺序

### Phase 0：契约与边界先行

- 在 `docs/design.md` 增加阶段3概要。
- 在 `docs/network_implementation_plan.md` 固化 policy、错误模型、API 形状。
- 增加 `ejs_platform_boundary_check` 的网络关键字扫描，确保 root `platform/*` 不引用 `EJSNet`、`EJSNetwork`、`XMLHttpRequest`、`WebSocket` 或模块私有 provider。
- 新增各模块 README/types skeleton，不实现 native I/O。

### Phase 1：`modules/stdlib/ipaddr`

- 实现纯 JS IP/CIDR parser。
- 补 `types/index.d.ts`。
- 补 Node-side JS 单元测试，不依赖 Apple provider。

### Phase 2：`modules/net` DNS + TCP client

- 实现 `lookup`。（Phase 2A 已完成）
- 实现 TCP `connect/read/write/shutdown/close`。（Phase 2B 已完成）
- 添加 local loopback 测试：本地测试 server/client、policy denied、端口授权拒绝。
- 先不做 server/UDP，降低首轮生命周期复杂度。

### Phase 3：`modules/net` TCP server + UDP

- Phase 3A（已完成）：实现 `listen/accept/close`，补 inbound policy 与本地 loopback server/client 回归。
- Phase 3B（已完成）：实现 UDP `bind/send/recv/close`、`capabilities.udp` gate、inbound/outbound `udp` policy、outbound remote port 显式约束、resolved IP/CIDR 二次授权、`limits.maxDatagramBytes`、`port: 0` assigned-port 二次校验、recv timeout/cancel 与 close 幂等回归。
- Phase 3C（已完成）：在不改变 `EJSNetworkError` shape 前提下，基于 native detail 将网络类错误细分映射为 `ECONNREFUSED`、`ECONNRESET`、`EHOSTUNREACH`、`ENETUNREACH`、`ETIMEOUT`，并将 `getaddrinfo` 失败稳定映射到 `EDNS`；保持 `operation/syscall/host/address/port/family/nativeDomain/nativeCode` 诊断字段。
- 补 buffer limit、pending accept/read/recv cancel、context invalidate 回归。

### Phase 4：`modules/xhr`

- Phase 4A（已完成）：实现 XHR JS 状态机基础层、Apple `NSURLSessionDataTask` provider、本地 HTTP fixture 回归（无公网依赖），覆盖 constructor/success/header access/abort/policy+native error path，并执行 `limits.maxHeaderBytes` / `limits.maxBodyBytes`、IP-literal resolved-address 二次授权与 system-proxy 禁用。
- Phase 4B（已完成）：扩展 `responseType`（`arraybuffer`/`json`）、补齐 `loadstart/progress` 和 bounded progress payload。
- Phase 4C（已完成）：Apple provider 切到 module-owned `NSURLSessionDataDelegate` buffering，`didReceiveData` 超限早停返回 `EPERM`，并补齐 single-finish/状态清理、streaming fixture 早停回归与诊断收口。

### Phase 5：`modules/ws`

- Phase 5A（已完成）：实现 `WebSocket` JS 状态机（`CONNECTING/OPEN/CLOSING/CLOSED`、`onopen/onmessage/onerror/onclose`、`addEventListener/removeEventListener`）、`send(string|ArrayBuffer|ArrayBufferView)`、`close(code?, reason?)` 校验、`binaryType` 仅 `arraybuffer`；Apple provider 基于 `NSURLSessionWebSocketTask`，并在 `modules/ws` 内完成 `ejs.network` (`capabilities.ws` + outbound allow/default deny + IP-literal private/link-local policy + `http.useSystemProxy` 禁用) 解析与授权；测试覆盖 JS mock 状态机与 Apple policy/install/request-shaping 路径。
- Phase 5B（待实施）：如需更强 native 覆盖，可补本地 WebSocket echo fixture（text/binary/close）、send-close 竞态、runtime teardown/pending waiter abort，以及更完整 close/error 诊断细节。

### Phase 6：收口与文档同步

- 更新 `docs/design.md`、`docs/module_alignment_roadmap.md`、各模块 README。
- 完成 `.d.ts`。
- 记录平台差异：Apple 已实现；其他平台保持 `ENOTSUP` 或不编译 add-on。

## 6. 验收标准

阶段3完成必须满足：

1. 四个模块均在 `modules` 下独立实现，不污染 root `platform/*`。
2. Apple provider 不新增 C++，不依赖 libuv，不暴露 QuickJS/private core 类型。
3. 网络操作全部走 async `invoke`，不使用 `invokeSync`。
4. 所有网络入口都受 `ejs.network` policy 控制，默认拒绝未授权能力。
5. JS API 具备稳定错误对象，至少覆盖 `EPERM`、`ENOTSUP`、`EINVAL`、`ETIMEOUT`、`ECONNREFUSED`、`ECONNRESET`、`EDNS`、`ETLS`、`ECANCELLED`。
6. 类型声明完整，且不宣传未实现的 DOM/Node API。
7. 测试不依赖公网；公网 HTTPS/WS 只作为可选环境验证。
8. `docs/design.md`、`docs/module_alignment_roadmap.md`、模块 README 与实现状态一致。

当前 Phase 0/1 验证命令：

```sh
node --check modules/stdlib/ipaddr/js/ipaddr.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_platform_boundary_check ejs_stdlib_apple_test
ctest --test-dir build -R "ejs_network_js_test|ejs_platform_boundary_test|ejs_stdlib_apple_test" --output-on-failure
ctest --test-dir build -R ejs_platform_boundary_negative_test --output-on-failure
```

完整阶段3收口时再扩展为：

```sh
node --check modules/stdlib/ipaddr/js/ipaddr.js
node --check modules/net/js/net.js
node --check modules/xhr/js/xhr.js
node --check modules/ws/js/ws.js
node tests/js/network_js_test.js
cmake --build build --target ejs_net_apple_test ejs_xhr_apple_test ejs_ws_apple_test ejs_platform_boundary_check ejs_apple_platform_test
ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_xhr_apple_test|ejs_ws_apple_test|ejs_platform_boundary_test|ejs_apple_platform_test" --output-on-failure
```

测试结果未在当前验证 pass 中实际运行时，不得在 roadmap 中标记为已完成。
