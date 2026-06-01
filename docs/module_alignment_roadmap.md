# EJS 模块对齐 Roadmap（嵌入式优先）

更新时间：2026-05-30
项目状态：`阶段3 Phase 0/1 + Phase 2A DNS lookup + Phase 2B TCP client + Phase 3A TCP server + Phase 3B UDP + Phase 3C error diagnostics + Phase 4A/4B/4C XHR + Phase 5A WS Basic 已落地；阶段5 npm-to-ejspkg 离线转换器 MVP + core source-table loader MVP 已落地`
文档目标：把模块对齐路线改为可执行 TODO，看板化追踪实现进度。

## 1. 项目约束

- 维持可选 add-on 架构：`core` 与 root `platform/*` 不承载模块私有策略。
- 保持你确认的阶段顺序：先简单能力，再挑战能力，再网络，再桌面/服务，最后模块加载策略。
- 同一任务完成时必须同步：实现、测试、模块 README、`docs/design.md`（若行为变化）。

## 2. 里程碑（阶段门禁）

| TODO | 阶段 | 门禁定义（全部满足才算完成） |
| --- | --- | --- |
| [x] | 阶段1 | `fs/system/hashing/uuid/fswatch` 任务全部完成，相关测试可运行并通过。 (已验证: `ctest --test-dir build -R "ejs_phase1_modules_js_test|ejs_fs_apple_test|ejs_system_apple_test|ejs_fswatch_apple_test|ejs_stdlib_apple_test" --output-on-failure`) |
| [x] | 阶段2 | `worker` 核心能力可用，生命周期和错误路径有回归测试。（Wasm 已移至阶段4） |
| [ ] | 阶段3 | `ws/net/xhr/ipaddr` 基础能力可用，网络错误可诊断。 |
| [ ] | 阶段4 | `ffi/getopts/assert/process/wasm` 按平台能力启用，受限平台返回明确错误。 |
| [ ] | 阶段5 | npm 纯 JS 包离线转换器 MVP、`core` source table loader MVP 与 Apple package installer MVP 已实现；剩余门禁是 CLI module mode、audited download 和 runtime package approval 接入。详见 [npm_ejspkg_conversion_plan.md](npm_ejspkg_conversion_plan.md)。 |

## 3. TODO 看板（功能点级）

| TODO | 阶段 | 模块 | 功能点（DoD） |
| --- | --- | --- | --- |
| [x] | 1 | `modules/fs` | `stat` 字段补齐（mode/uid/gid/time 等）并补测试。 (已验证: ctest -R ejs_fs_apple_test 通过) |
| [x] | 1 | `modules/fs` | `lstat` 语义与 `stat` 区分清楚并补测试。 (已验证: ctest -R ejs_fs_apple_test 通过) |
| [x] | 1 | `modules/fs` | `open(path, flags, mode)` + `FileHandle.read/write/close`。 (已验证: `ejs_fs_apple_test`) |
| [x] | 1 | `modules/fs` | `FileHandle.truncate/datasync/sync` 行为定义与测试。 (已验证: `ejs_fs_apple_test`) |
| [x] | 1 | `modules/fs` | `readLink/link/symlink` 对齐与平台限制说明。 (已验证: `ejs_fs_apple_test`; README/design 已同步) |
| [x] | 1 | `modules/fs` | `statFs` 能力与返回结构稳定。 (已验证: `ejs_fs_apple_test`) |
| [x] | 1 | `modules/fs` | `makeTempDir/makeTempFile/remove` 语义补齐。 (已验证: `ejs_fs_apple_test`) |
| [x] | 1 | `modules/fs` | `chmod/chown/lchown/utime/lutime`：受限平台返回明确错误。 (已验证: `ejs_fs_apple_test`) |
| [x] | 1 | `modules/system` | `cwd/chdir` 可用并有异常路径测试。 (已验证: `ejs_system_apple_test`) |
| [x] | 1 | `modules/system` | `env/getenv/setenv/unsetenv` 可用并有边界测试。 (已验证: `ejs_system_apple_test`) |
| [x] | 1 | `modules/system` | `pid/ppid/homeDir/tmpDir/exePath` 返回一致。 (已验证: `ejs_system_apple_test`) |
| [x] | 1 | `modules/system` | `hostName/platform/arch/uname/uptime/loadAvg/availableParallelism`。 (已验证: `ejs_system_apple_test`) |
| [x] | 1 | `modules/system` | `cpuInfo/networkInterfaces/userInfo`：缺失字段有稳定降级。 (已验证: `ejs_system_apple_test`) |
| [x] | 1 | `modules/fswatch` | `watch(path, handler)` + `close()`；`change/rename` 事件覆盖测试。 (已验证: `ejs_fswatch_apple_test`) |
| [x] | 1 | `modules/fswatch` | 递归监听策略与平台差异文档化。 (已验证: `ejs_fswatch_apple_test`; README/design 已同步) |
| [x] | 1 | `modules/stdlib/hashing` | 提供 hash API（如 sha256/sha512）与类型声明。 (已验证: `ejs_stdlib_apple_test`) |
| [x] | 1 | `modules/stdlib/uuid` | UUID 生成与格式验证，补类型声明与测试。 (已验证: `ejs_stdlib_apple_test`) |
| [x] | 2 | `modules/worker` | `new Worker(specifier, options)` 可用，入口规则清晰（按 3.2 规划落地）。 (已验证: `ejs_worker_js_test`, `ejs_worker_apple_test`) |
| [x] | 2 | `modules/worker` | `postMessage/onmessage` 可用，异常路径可诊断（按 3.2 规划落地）。 (已验证: `ejs_worker_js_test`, `ejs_worker_apple_test`) |
| [x] | 2 | `modules/worker` | `terminate()` 幂等且资源回收可靠（按 3.2 规划落地）。 (已验证: `ejs_worker_apple_test`) |
| [x] | 2 | `modules/worker` | `ArrayBuffer` transfer 支持与回归测试（按 3.2 规划落地）。 (已验证: `ejs_worker_js_test`, `ejs_worker_apple_test`) |
| [x] | 3 | `modules/net` | `lookup(host, { family, all })` 支持 IPv4/IPv6。 (已验证: `ejs_network_js_test`, `ejs_net_apple_test`) |
| [x] | 3 | `modules/net` | TCP client `connect/read/write/shutdown/close`。 (已验证: `ejs_network_js_test`, `ejs_net_apple_test`) |
| [x] | 3 | `modules/net` | TCP server `listen/accept/close`。 (已验证: `ejs_network_js_test`, `ejs_net_apple_test`) |
| [x] | 3 | `modules/net` | TCP client `localAddress/remoteAddress/noDelay/keepAlive`。 (已验证: `ejs_network_js_test`, `ejs_net_apple_test`) |
| [x] | 3 | `modules/net` | UDP `bind/send/recv/close` + `reuseAddr/ipv6Only`。 (已验证: `ejs_network_js_test`, `ejs_net_apple_test`) |
| [x] | 3 | `modules/net` | 错误码和异常信息可诊断（含目标地址信息）。 (已验证: `ejs_network_js_test`, `ejs_net_apple_test`) |
| [x] | 3 | `modules/ws` | `WebSocket` 状态机与 `onopen/onmessage/onerror/onclose`。 (已验证: `ejs_network_js_test`, `ejs_ws_apple_test`) |
| [x] | 3 | `modules/ws` | `sendText/sendBinary/close(code, reason)`。 (已验证: `ejs_network_js_test`, `ejs_ws_apple_test`) |
| [x] | 3 | `modules/xhr` | `open/send/abort/headers` 基础兼容层。 (已验证: `ejs_network_js_test`, `ejs_xhr_apple_test`) |
| [x] | 3 | `modules/xhr` | `responseType` 非文本模式、完整 readyState/事件兼容与进度事件 + Phase 4C delegate streaming body-limit early abort。 (已验证: `node tests/js/network_js_test.js`; 非 sandbox `ctest -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test"` 通过) |
| [x] | 3 | `modules/stdlib/ipaddr` | IP/CIDR 解析校验能力与测试。 (已验证: `ejs_network_js_test`, `ejs_stdlib_apple_test`) |
| [ ] | 4 | `modules/wasm` | `parseModule/buildInstance/callFunction` 可用。 |
| [ ] | 4 | `modules/wasm` | `moduleExports/linkWasi`（可选）行为与边界说明。 |
| [ ] | 4 | `modules/ffi` | `dlopen/symbol` 可用并加权限闸门。 |
| [ ] | 4 | `modules/ffi` | 参数/返回映射与指针生命周期安全。 |
| [ ] | 4 | `modules/stdlib/getopts` | 参数解析能力、类型声明和测试。 |
| [ ] | 4 | `modules/stdlib/assert` | 断言工具能力、类型声明和测试。 |
| [ ] | 4 | `modules/process` | `spawn/wait/kill/exec`；移动端受限路径统一错误语义。 |
| [x] | 5 | `tools/ejs-pkg-convert` | 离线 npm-to-ejspkg 转换器 MVP：本地目录/tarball 输入、lockfile integrity 校验、deterministic unpacked `.ejspkg`、manifest/report、fixture 回归测试。 (已验证: `node tests/ejspkg/converter_test.js`) |
| [x] | 5 | `core` 模块加载策略 | `EJSCoreModuleSource` + `ejs_context_register_module_sources(...)` source-table loader 已落地；loader callback 只读 context 内存表，不做 I/O/provider 调用。 (已验证: `ejs_core_test`) |
| [x] | 5 | `core` 模块导入能力 | loader 对接 `ejs_eval_module`，支持已注册源码表中的静态 `import/export`。 (已验证: `ejs_core_test`) |
| [x] | 5 | `core` 模块导入能力 | 相对路径归一化、模块缓存、循环依赖安全。 (已验证: `ejs_core_test`) |
| [ ] | 5 | `core` 模块导入能力 | `import()` 按策略启用；当前 MVP 仅覆盖静态 import。 |
| [x] | 5 | `core` 模块导入能力 | `import.meta.url`、未解析模块/语法错误诊断（含 `ejs-pkg://` source URL）。 (已验证: `ejs_core_test`) |
| [x] | 5 | `modules/package` | Apple `.ejspkg` 安装器 MVP：approval manifest/expected hash 校验、模块 hash 校验、capability 默认拒绝、path traversal/symlink escape 边界和 source-table 注册。 (已验证: `cmake --build build --target ejs_package_apple_test ejs_platform_boundary_check`; `ctest --test-dir build -R "ejs_package_apple_test|ejs_platform_boundary_test" --output-on-failure`) |

## 3.1 阶段1完成记录

阶段1本轮实现范围：

- `modules/fs`：补齐 `open`/`FileHandle`、链接、`statFs`、临时路径、权限/时间元数据 API；同步 `modules/fs/README.md`、`modules/fs/types/index.d.ts`、`docs/design.md`、Apple 测试和 JS wrapper 测试。
- `modules/system`：新增可选 add-on，覆盖 cwd/env/process/host/machine/network/user 信息，并补 README/types/Apple 测试。
- `modules/fswatch`：新增可选 add-on，覆盖 direct watch、`change`/`rename`、`close()` 和递归监听拒绝语义，并补 README/types/Apple 测试。
- `modules/stdlib/hashing`：新增 `EJSHashing.digest/sha256/sha512`，支持 `hex`/`base64`，并补 README/types/Apple 测试。
- `modules/stdlib/uuid`：新增 `EJSUUID.v4/randomUUID/validate`，并补 README/types/Apple 测试。

阶段1验证命令：

```sh
node --check modules/fs/js/fs.js
node --check modules/system/js/system.js
node --check modules/fswatch/js/fswatch.js
node --check modules/stdlib/hashing/js/hashing.js
node --check modules/stdlib/uuid/js/uuid.js
node tests/js/phase1_modules_js_test.js
cmake --build build --target ejs_fs_apple_test ejs_system_apple_test ejs_fswatch_apple_test ejs_stdlib_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_phase1_modules_js_test|ejs_fs_apple_test|ejs_system_apple_test|ejs_fswatch_apple_test|ejs_stdlib_apple_test" --output-on-failure
```

## 3.2 阶段2 Worker 实施计划

Worker 详细规划已抽取为独立文档：[worker_implementation_plan.md](worker_implementation_plan.md)。

本 roadmap 保留阶段验收摘要：

- `modules/worker` 保持可选 add-on 边界，root `platform/*` 和 `core` 不承载 Worker 私有策略。
- 首版是浏览器 Web Worker 形态的嵌入式子集，不做 Node.js `worker_threads` 兼容层。
- Worker 入口加载必须受 `EJSWorkerConfigurationKey` / `"ejs.worker"` 配置约束。
- Apple 首版实现以独立 `EJSRuntime` + `EJSContext`、parent/child JS wrapper、provider inbox、生命周期队列为核心。
- 阶段完成前必须通过 Worker JS wrapper 测试、Apple Worker 测试、core/platform 回归、QuickJS 边界扫描和 `git diff --check`。

## 3.3 阶段3 网络实施计划

网络模块详细规划已抽取为独立文档：[network_implementation_plan.md](network_implementation_plan.md)。

当前完成记录：

- Phase 0：`docs/design.md` 已同步阶段3概要；`ejs_platform_boundary_check` 已扩展网络关键字扫描；`modules/net`、`modules/xhr`、`modules/ws` 已新增 README/types skeleton，尚不提供 native I/O。
- Phase 1：`modules/stdlib/ipaddr` 已实现纯 JS IPv4/IPv6/CIDR 解析、Apple bundle installer、类型声明和 Node/Apple 回归测试；不注册 native provider，缺少 root `platform/*` 对应实现是设计边界而非缺口。
- Phase 2A：`modules/net` 已实现 Apple `EJSNet.lookup`、`EJSNetworkConfigurationKey` / `"ejs.network"` fail-closed DNS policy、JS `EJSNetworkError` shaping、Node mock 测试和 Apple 本地 `localhost` lookup 测试。
- Phase 2B：`modules/net` 已实现 Apple TCP client `connect/read/write/shutdown/close`、端口/协议 policy、JS wrapper 类型声明和本地 loopback ping/pong 回归测试。
- Phase 3A：`modules/net` 已实现 Apple TCP server `listen/accept/close`、`capabilities.tcpListen` + inbound allow rule 授权、`port: 0` 本地分配回填、listener close 幂等与 close 后 `ECANCELLED` 回归测试。
- Phase 3B：`modules/net` 已实现 Apple UDP `bind/send/recv/close`、`capabilities.udp` + inbound/outbound `udp` 协议授权、outbound remote port 显式约束、resolved IP/CIDR 二次授权、`limits.maxDatagramBytes`、`port: 0` assigned-port 二次校验、recv timeout/cancel 与 close 幂等回归测试。
- Phase 3C：`modules/net` 已实现 `EJSNetworkError` 网络错误细分映射（`ECONNREFUSED`/`ECONNRESET`/`EHOSTUNREACH`/`ENETUNREACH`/`ETIMEOUT`/`EDNS`），并保留 `nativeDomain/nativeCode` 与目标地址诊断字段。
- Phase 4A：`modules/xhr` 已实现 global `XMLHttpRequest`、async-only `open`、`setRequestHeader/getResponseHeader/getAllResponseHeaders`、`send(null|string|ArrayBuffer|ArrayBufferView)`、`abort`、`readyState/status/statusText/responseURL/responseText/response`、`on*` + `addEventListener/removeEventListener`、`responseType` (`""`/`"text"`)，并落地 Apple `NSURLSessionDataTask` provider 与 `ejs.network` (`capabilities.xhr` + outbound allow, default deny, IP-literal resolved-address recheck, header/body limits, system proxy disabled) 授权。
- Phase 4B：`modules/xhr` 已扩展 `responseType` (`arraybuffer`/`json`)、`loadstart/progress` 事件、single bounded progress payload（`loaded/total/lengthComputable`）、`json` invalid parse 的 `error + loadend` 路径，并通过 base64 JSON 字段回传 bounded binary body。
- Phase 4C：`modules/xhr` Apple provider 已切换到 module-owned `NSURLSessionDataDelegate` buffering；`didReceiveData` 在超过 `limits.maxBodyBytes` 时立即 cancel 并返回 `EPERM`，且完成单次 finish + task state 清理；`ejs_xhr_apple_test` 新增 streaming 超限 fixture 验证早停。
- Phase 5A：`modules/ws` 已实现 global `WebSocket`、`CONNECTING/OPEN/CLOSING/CLOSED` 状态机、`onopen/onmessage/onerror/onclose` 与 `addEventListener/removeEventListener`、`send(string|ArrayBuffer|ArrayBufferView)`、`close(code?, reason?)` 校验，并落地 Apple `NSURLSessionWebSocketTask` provider 与 `ejs.network` (`capabilities.ws` + outbound allow/default deny + IP-literal private/link-local policy + system proxy disabled) 授权。

本轮验证命令：

```sh
node --check modules/stdlib/ipaddr/js/ipaddr.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_platform_boundary_check ejs_stdlib_apple_test
ctest --test-dir build -R "ejs_network_js_test|ejs_platform_boundary_test|ejs_stdlib_apple_test" --output-on-failure
ctest --test-dir build -R ejs_platform_boundary_negative_test --output-on-failure
node --check modules/net/js/net.js
cmake --build build --target ejs_net_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_net_apple_test|ejs_platform_boundary_test" --output-on-failure
node --check modules/xhr/js/xhr.js
cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure
node --check modules/ws/js/ws.js
cmake --build build --target ejs_ws_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_ws_apple_test|ejs_platform_boundary_test" --output-on-failure
```

## 4. 执行顺序（锁定）

1. 阶段1：`fs/system/hashing/uuid/fswatch`
2. 阶段2：`worker`
3. 阶段3：`ws/net/xhr/ipaddr`
4. 阶段4：`ffi/getopts/assert/process/wasm`
5. 阶段5：`import/loader`（嵌入式策略最后）

## 5. 进度记录规则

| 操作 | 规则 |
| --- | --- |
| 开始任务 | 将对应 TODO 行标记为 `[~]`（进行中，可选）并补充分支/PR 链接。 |
| 完成任务 | 将 TODO 从 `[ ]` 改为 `[x]`，并附验证命令与结果摘要。 |
| 变更范围 | 不跨阶段并行拉大范围；如需跨阶段，先在本文件记录原因。 |
