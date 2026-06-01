# Final Review Report

本报告整合了两类输入：

- `docs/gemini_review.md` 中的 Gemini 并发 review 结论。
- Codex 本轮并发 subagent review 结论：`core`、`platform/apple`、`modules`、`modules/wintertc`、`build/tests/docs`。

本版按新的 triage 规则重新排序：

1. 安全边界、路径边界、数据破坏风险优先修复。
2. 对外标称 Node-like 的模块，默认按 Node 行为对齐；除非明确写成 intentional divergence。
3. `core` 是给 platform 层使用的内部 ABI，不直接暴露给最终业务。原始 core handle 的不规范使用导致的异常，优先降级为“接口契约文档 + platform 侧防护/后续加固”。
4. platform 层可触发的生命周期卡死、泄漏、静默数据错误仍按高优先级处理。

当前仓库状态提示：本报告基于当前工作树，工作树已有未提交修改与新增文件，包含 `docs/gemini_review.md`、Apple install transaction、FS/KV/SQLite/WinterTC 相关改动和测试改动。

## 1. Priority Notes

### Core destroy 类问题的处理口径

`FR-001` 和 `FR-002` 不再作为第一批修复项。原因是 core runtime/context API 当前定位是 platform 内部 ABI，platform 开发者应遵守销毁顺序并在 platform 层序列化 teardown。

需要先在接口文档中明确：

- `ejs_runtime_destroy` 会使该 runtime 下所有 context handle 失效。
- runtime destroy 后，宿主不得再调用 `ejs_context_destroy` 或访问旧 context handle。
- runtime/context destroy 是单 owner 生命周期操作；platform 层必须防止重复 destroy 和并发 destroy。
- 若后续希望 core 对误用容错，再单独设计 tombstone/ref-hold/双向所有权模型，并补 ASan/TSan 回归。

因此，多次 destroy / 并发 destroy 与 cleanup-order UAF 的处理口径一致：先记入 P2 的 contract + hardening，而不是阻塞安全修复。

### Node-like 行为的处理口径

`fs`、`path`、`fetch` 等对外呈现 Node-like 或 Web-like API 时，当前报告不再把行为差异视为“需确认是否偏离”。默认结论是需要对齐 Node/Web 语义；只有产品明确决定偏离时，才把偏离写进文档和测试。

## 2. Final Issue List

### P0 Security / Data Boundary

#### FR-009 KV manifest 信任 `fileName`，篡改后可路径逃逸

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/kv/platform/apple/src/EJSKeyValueStoreApple.m:478-482`
  - `modules/kv/platform/apple/src/EJSKeyValueStoreApple.m:516-531`
  - `modules/kv/platform/apple/src/EJSKeyValueStoreApple.m:612-666`
- 问题：
  `manifest.json` 中的 value file name 被直接从 JSON 读入并拼接到 `store.path`。如果 manifest 被本地篡改为 `../../outside.txt`，`get/delete/clear` 会对 store 目录外路径执行读/删。
- 影响：
  这是明确的路径边界问题。即使 manifest 主要由本模块写入，也不能把持久化 JSON 当作可信输入。
- 期望方向：
  读取 manifest 时校验 `fileName` 必须是单段文件名，拒绝 `/`、`\`、`..`、空值和非预期扩展；所有最终路径必须 canonicalize 后确认仍位于 store 目录内。

#### FR-007 `fs.writeFile/copyFile` 的 `"wx"` 独占写存在 TOCTOU 覆盖窗口

- 来源：Gemini，当前源码确认。
- 位置：
  - `modules/fs/platform/apple/src/EJSFileSystemApple.m:698-709`
  - `modules/fs/platform/apple/src/EJSFileSystemApple.m:983-1028`
- 问题：
  `"wx"` 路径先用 `fileExistsAtPath` / symlink 检查，再执行普通 atomic write。检查和写入之间存在时间窗，另一个 actor 可以创建目标文件，最终被覆盖。
- 影响：
  独占创建语义不成立，存在数据覆盖风险。
- 期望方向：
  使用 `open(..., O_CREAT | O_EXCL | O_NOFOLLOW, ...)` 或等价原子 primitive 实现独占创建；`copyFile` 的 exclusive 模式也必须基于原子目标创建。

### P1 Platform Correctness / Data Semantics

#### FR-006 Apple context teardown 对 active core call 无限等待，provider 卡死会阻塞 invalidate/runtime teardown

- 来源：Gemini + Codex platform subagent，当前源码确认。
- 位置：
  - `platform/apple/src/EJSApplePlatform.m:1426-1439`
- 问题：
  `invalidateForRuntimeTeardown` 在非当前 active core call 场景会等待 `_activeCoreCalls` 归零，使用无超时 `[self.stateCondition wait]`。如果 provider 阻塞、等待外部信号或执行不可取消 I/O，teardown 线程会长期挂住。
- 影响：
  Runtime teardown 可被单个卡住的 provider 无限期阻塞。

#### FR-005 Apple `EJSContext` 与 core host user_data 形成强引用环

- 来源：Gemini，当前源码确认。
- 位置：
  - `platform/apple/src/EJSApplePlatform.m:1247-1268`
  - `platform/apple/src/EJSApplePlatform.m:1271-1273`
- 问题：
  `EJSContext` 强持有 `_coreContext`，同时注册到 core 的 `invoke_api.user_data` / `sync_invoke_api.user_data` 通过 `CFBridgingRetain(self)` 强持有 `EJSContext`。如果业务只释放 ObjC `EJSContext` 引用而不显式 `invalidate`，`dealloc` 不会触发，core host user_data 也不会释放。
- 影响：
  ObjC 层 context 和 core context 长期泄漏。

#### FR-003 destroy 主流程忽略 terminal shutdown 投递失败，可能跳过 context/engine 清理

- 来源：Codex core subagent，当前源码支持，需定向回归确认。
- 位置：
  - `core/src/ejs_runtime.c:594-609`
  - `tests/core/ejs_regression_smoke.c:348-352`
- 问题：
  `ejs_runtime_loop_call_sync(..., ejs_terminal_shutdown_task, ...)` 失败后仅销毁 `loop_result.error`，随后继续销毁 loop 并宣布 runtime destroy 完成。`ejs_terminal_shutdown_task` 负责清理 context list、engine runtime 和 loop handles。
- 影响：
  stop_requested/loop stopping 竞态下可能跳过关键清理，造成泄漏、悬挂 context 或未释放 engine runtime。

#### FR-004 异步 invoke completion 未校验非法 result buffer

- 来源：Codex core subagent，当前源码确认。
- 位置：
  - `core/src/ejs_engine_quickjs_ng.c:1240-1243`
  - `core/src/ejs_engine_quickjs_ng.c:1092-1096`
  - 对照同步路径：`core/src/ejs_engine_quickjs_ng.c:1713-1717`
- 问题：
  异步 completion 仅在 `result.data != NULL` 时设置 `has_result`。当宿主返回 `result.data == NULL && result.size > 0` 时，异步路径会 resolve `undefined`，同步路径则抛出 invalid result buffer。
- 影响：
  API 合约不一致，并会静默吞掉宿主返回数据错误。

#### FR-008 `fs` JS wrapper 把字符串 `"false"` 强转为 `true`

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/fs/js/fs.js:74-79`
  - `modules/fs/js/fs.js:312-315`
  - `modules/fs/js/fs.js:333-337`
- 问题：
  `boolOption` 直接 `Boolean(options[key])`，因此 `{ recursive: "false", force: "false" }` 会变成 `true`。
- 影响：
  可误触发递归创建、递归删除或 force 删除。
- 期望方向：
  按 Node 语义处理 option 类型；非 boolean 应抛 `TypeError` 或按 Node 对应 API 的实际规则对齐，不应 truthy-coerce。

#### FR-010 SQLite query 全量累积 rows，TEXT 列无字节上限

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/sqlite/platform/apple/src/EJSSQLiteApple.m:704-755`
  - `modules/sqlite/platform/apple/src/EJSSQLiteApple.m:724-727`
- 问题：
  `query` 将所有 row 全量累积到 `NSMutableArray`，只限制 row count 和 BLOB 字节数。TEXT 列直接转 `NSString`，无单列/总响应字节上限。
- 影响：
  只读查询也可构造大文本结果导致高内存占用或 OOM。

#### FR-011 SQLite INTEGER 通过 JSON number 回传，超过 JS safe integer 会精度丢失

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/sqlite/platform/apple/src/EJSSQLiteApple.m:720-723`
  - `modules/sqlite/js/sqlite.js:94-99`
  - `modules/sqlite/js/sqlite.js:177-180`
- 问题：
  `sqlite3_column_int64` 转 `NSNumber` 后经 JSON 回传，JS `JSON.parse` 得到 Number。超过 `2^53 - 1` 的 int64 会静默损失精度。
- 影响：
  ID、时间戳、计数器等 64-bit 整数会被悄悄改值。

#### FR-012 `fetch` 在 native start 前完整读取请求体，AbortSignal 不能中断慢速 request body

- 来源：Codex WinterTC subagent，当前源码确认。
- 位置：
  - `modules/wintertc/js/fetch.js:59-90`
  - `modules/wintertc/js/fetch.js:111-113`
  - `modules/wintertc/js/fetch.js:510-516`
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:935-942`
- 问题：
  `ReadableStream` body 先由 JS 全量读成 `ArrayBuffer`，之后才进入 native `wintertc.fetch start`。abort listener 只能向 native cancel 已建立的 task/stream，无法取消 `_transferBody()` 阶段。
- 影响：
  慢速或不结束的 request body 在 abort 后仍可让 fetch Promise 长时间不返回。

#### FR-013 默认 fetch provider 对未消费 response body 保留 stream state 和 chunk buffer

- 来源：Codex WinterTC subagent，当前源码确认。
- 位置：
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:931-935`
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:1165-1179`
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:1214-1217`
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:993-1004`
- 问题：
  HTTP response start 时总是创建并保存 stream state。正常 completion 只标记 `completed = YES`，不移除 `_streamsByID`；只有 pull 到 EOF、error 或 cancel 才移除。
- 影响：
  大量 `fetch()` 后只看 status、不消费 body 的场景会长期保留 stream state 和已缓冲数据。

#### FR-014 `ReadableStream` 并发 read 可能丢失后续 pull

- 来源：Codex WinterTC subagent，当前源码确认。
- 位置：
  - `modules/wintertc/js/streams.js:45-57`
  - `modules/wintertc/js/streams.js:89-94`
- 问题：
  `_pull()` 通过 `_pulling` 防重入。如果已有 pull 在执行，后续 `read()` 只加入 pendingReads 并返回；当前 pull 完成后不会检查 pendingReads 并继续拉取。
- 影响：
  当底层一次 pull 只 enqueue 一个 chunk 时，并发第二个 read 可能永久 pending。

#### FR-022 Header value 未拒绝 CR/LF 控制字符

- 来源：Codex WinterTC subagent，当前源码确认，底层实际注入效果需抓包确认。
- 位置：
  - `modules/wintertc/js/fetch.js:33-35`
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:339-350`
- 问题：
  JS 只 trim header value，不拒绝 `\r`/`\n`；native 直接 `setValue:forHTTPHeaderField:`。
- 影响：
  至少是 Fetch 规范兼容性问题；若 Foundation 未拦截，可能产生 header injection。
- 期望方向：
  按 Fetch/Node 行为拒绝非法 header value，而不是依赖底层库容错。

#### FR-015 平台边界检查可被 root CMake 或非 WinterTC 可选模块耦合绕过

- 来源：Codex build/tests/docs subagent，当前源码确认。
- 位置：
  - `cmake/check_platform_boundary.cmake:5-6`
  - `cmake/check_platform_boundary.cmake:10-21`
  - `cmake/check_platform_boundary.cmake:23-35`
- 问题：
  检查脚本只扫描 `platform/*` 文件，且 forbidden tokens 主要覆盖 WinterTC。根 `CMakeLists.txt` 或其它目录给 `ejs_apple_platform` 添加模块依赖不会被扫描；`ejs_fs_apple`、`ejs_kv_apple` 等 target 名也不会被 token 命中。
- 影响：
  root platform “保持纯平台层、不依赖 add-on” 的架构约束可被绕过。

### P2 Contract / Compatibility / Hardening

#### FR-001 Core runtime 销毁会释放宿主持有的 context handle，需文档化 core ABI 契约

- 来源：Gemini，当前源码确认；按新 triage 降级。
- 位置：
  - `core/src/ejs_runtime.c:564-575`
  - `core/src/ejs_runtime.c:920-964`
  - `core/include/ejs_runtime.h:179-185`
- 问题：
  `ejs_runtime_destroy` 的 terminal shutdown 会遍历 `runtime->context_list`，销毁 engine context 后调用 `ejs_context_release(c)`，最终可 `free(context)`。如果 platform 仍保存 `EJSCoreContext *` 并在 runtime destroy 后执行 `ejs_context_destroy(context)`，会访问已释放内存。
- 当前处理口径：
  这属于 core 原始 ABI 的销毁顺序契约，不再作为 P0。先在 `core/include/ejs_runtime.h` 或接口文档中注明 runtime destroy 会使 context handle 失效；platform 层必须先销毁/解绑 context，再销毁 runtime，或在 runtime teardown 时清空 platform handle。
- 后续加固：
  如果希望 core 对误用容错，再设计 tombstone/ref-hold 模型并加 ASan 回归。

#### FR-002 并发/多次 runtime destroy 存在 `runtime->runtime_loop` 悬挂指针窗口

- 来源：Codex core subagent，当前源码支持；按新 triage 降级。
- 位置：
  - `core/src/ejs_runtime.c:594-603`
  - `core/src/ejs_runtime.c:671-684`
- 问题：
  首个销毁线程会先执行 `ejs_runtime_loop_destroy(runtime->runtime_loop)`，之后才写 `runtime->runtime_loop = NULL`。并发第二个 `ejs_runtime_destroy_with_completion` 可在窗口内读取旧指针并调用 `ejs_runtime_loop_is_owner_thread`。
- 当前处理口径：
  与 `FR-001` 一样，先作为 core ABI 契约和 platform 防护问题处理。platform 必须保证 runtime destroy 单次、串行执行。core 后续可补防御式状态位和 TSan 回归。

#### FR-016 owner thread 内 stop 后 destroy 可能未回收 joinable pthread 资源

- 来源：Codex core subagent，当前源码支持。
- 位置：
  - `core/src/ejs_runtime_loop_libuv.c:554-557`
  - `core/src/ejs_runtime_loop_libuv.c:475-482`
  - `core/src/ejs_runtime_loop_libuv.c:618-622`
- 问题：
  owner thread 调用 `ejs_runtime_loop_stop` 时直接 `uv_stop` 并返回，不 join/detach。线程退出后会把 `thread_started` 置 0；后续 destroy 在 `thread_started == 0 && handles_closed_on_stop != 0` 分支释放 loop，但没有显式 join/detach 该 pthread。
- 影响：
  stopped loop destroy 场景可能泄漏 joinable thread 资源。

#### FR-017 `createContextWithID` 持 runtime lock 执行 core context 创建，放大 teardown 阻塞窗口

- 来源：Codex platform subagent，当前源码确认。
- 位置：
  - `platform/apple/src/EJSApplePlatform.m:1046-1081`
  - `platform/apple/src/EJSApplePlatform.m:1144-1148`
- 问题：
  `createContextWithID` 持有 `runtime.stateLock` 时调用测试 hook 和 `ejs_context_create`。runtime invalidate 也要拿同一把锁。
- 影响：
  context 创建变慢或卡住时，runtime teardown 会被同步拖住。

#### FR-018 `fs.rename` 与 Node/POSIX 覆盖语义不一致

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/fs/platform/apple/src/EJSFileSystemApple.m:1067-1074`
- 问题：
  Apple provider 使用 `moveItemAtPath:toPath:`。目标文件已存在时失败；Node `fs.rename` 在 POSIX 文件场景通常覆盖目标。
- 影响：
  Node-like API 兼容性偏差。
- 期望方向：
  按 Node 行为对齐，并更新现有测试中固化的偏差。

#### FR-019 `fs.exists` 对断链 symlink 返回 true

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/fs/platform/apple/src/EJSFileSystemApple.m:756-769`
- 问题：
  `exists` 使用 `fileExistsAtPath || destinationOfSymbolicLinkAtPath != nil`。断链 symlink 的 `fileExistsAtPath` 为 false，但 `destinationOfSymbolicLinkAtPath` 可返回目标字符串。
- 影响：
  与 Node `existsSync` 断链返回 false 的行为不一致。
- 期望方向：
  按 Node 行为对齐；如另需 `lstat` 语义，应通过独立 API 表达。

#### FR-020 `path.relative` 一绝一相对时语义偏离 Node

- 来源：Codex modules subagent，当前源码确认。
- 位置：
  - `modules/path/js/path.js:141-149`
  - `tests/path/apple/ejs_path_apple_test.m:106`
- 问题：
  一绝一相对时直接返回 `normalize(to)`；Node `path.posix.relative` 会基于 cwd resolve 后再计算。
- 影响：
  Node-like API 兼容性偏差，且测试已固化当前偏差。
- 期望方向：
  按 Node 行为对齐，并修正测试期望。

#### FR-021 fetch redirect 语义未实现

- 来源：Codex WinterTC subagent，当前源码确认。
- 位置：
  - `modules/wintertc/js/fetch.js:520`
  - `modules/wintertc/js/fetch.js:592-598`
  - `modules/wintertc/platform/apple/src/EJSWinterTCApple.m:922-935`
- 问题：
  JS payload 传递 `redirect`，native provider 未读取该字段；start response 也不返回最终 URL/redirected。
- 影响：
  `{ redirect: "error" }` 等策略不生效，`Response.redirected` 和 `Response.url` 不准确。
- 期望方向：
  按 Fetch/Web 行为对齐；如果暂不支持 redirect 策略，需要显式抛错或文档化。

#### FR-023 binary extraction 通过 JS 属性读取 `.buffer/.byteOffset/.byteLength`

- 来源：Gemini，当前源码确认。
- 位置：
  - `core/src/ejs_engine_quickjs_ng.c:700-756`
- 问题：
  `ejs_extract_binary_data` 用 `JS_GetPropertyStr` 获取 `buffer`、`byteOffset`、`byteLength`。这会触发用户自定义 getter，并且接受任意带有 `buffer` 属性的对象作为二进制视图，而不是只接受真正 TypedArray/DataView。
- 影响：
  native bridge 参数提取存在可观察副作用和类型边界放宽。当前有边界校验，未看到直接越界，但建议改用 QuickJS typed-array 内部 API 或显式收窄可接受类型。

#### FR-024 FS/SQLite provider 使用单 provider 串行队列，独立 I/O 互相阻塞

- 来源：Gemini，当前源码确认。
- 位置：
  - `modules/fs/platform/apple/src/EJSFileSystemApple.m:424-478`
  - `modules/sqlite/platform/apple/src/EJSSQLiteApple.m:299-341`
- 问题：
  FS 和 SQLite provider 分别使用一个串行队列处理所有请求。独立路径或不同 SQLite connection 的长操作会阻塞其它无关操作。
- 影响：
  吞吐与尾延迟问题；如果队列内任务等待外部事件，也会放大应用级卡顿。

#### FR-025 KV manifest 全量 JSON 读写是明确扩展性瓶颈

- 来源：Gemini，当前源码确认。
- 位置：
  - `modules/kv/platform/apple/src/EJSKeyValueStoreApple.m:460-501`
  - `modules/kv/platform/apple/src/EJSKeyValueStoreApple.m:562-590`
- 问题：
  KV 每次 get/set/delete/keys/clear 都要读取 manifest；set/delete/clear 还要全量写回 manifest。
- 影响：
  key 数增长后读写复杂度和文件竞争会快速变差。若该模块定位为小型 KV，可作为文档限制；否则需要索引/分片/SQLite 化。

#### FR-026 CLI timeout 未设置上限，超大值乘 `NSEC_PER_SEC` 可能溢出

- 来源：Gemini build 隐患，当前源码确认。
- 位置：
  - `tools/apple/EJSAppleCLISupport.m:449-460`
  - `tools/apple/EJSAppleCLISupport.m:623-625`
- 问题：
  `--timeout` 只检查 `> 0` 和 finite，随后直接 `timeoutSeconds * NSEC_PER_SEC` 转 `int64_t`。
- 影响：
  极大 timeout 可产生溢出，导致等待 deadline 异常。

#### FR-027 README 推荐验证命令遗漏已接线的 Apple 模块测试

- 来源：Codex build/tests/docs subagent，当前源码确认。
- 位置：
  - `README.md:52-57`
  - `tests/CMakeLists.txt:138-216`
- 问题：
  README 只列 `ejs_apple_platform_test`、`ejs_wintertc_apple_test`、`ejs_fs_apple_test`，遗漏 `path/buffer/kv/sqlite` Apple tests。
- 影响：
  开发者按 README 验证会漏跑多个已实现模块。

#### FR-028 `docs/design.md` 与 CMake/testing 现状不一致

- 来源：Codex build/tests/docs subagent，当前源码确认。
- 位置：
  - `docs/design.md:563-565`
  - `CMakeLists.txt:60-62`
  - `docs/design.md:629-630`
- 问题：
  文档写 root CMake always adds `tests`，但实际受 `BUILD_TESTING` 控制。文档还引用 `docs/README.md`，当前该文件不存在。
- 影响：
  文档会误导后续验证和文档入口维护。

#### FR-029 测试中大量 `usleep` 忙等，存在 flakiness 和运行时间膨胀风险

- 来源：Gemini，当前源码确认。
- 位置：
  - `tests/core/ejs_core_test.c:151`
  - `tests/core/ejs_regression_smoke.c:101`
  - `tests/wintertc/apple/ejs_wintertc_apple_test.m:439`
- 问题：
  多处测试依赖固定 `usleep` 等待异步状态，而不是用条件变量、semaphore 或明确事件同步。
- 影响：
  慢机器上可能 flaky，快机器上浪费测试时间。部分 sleep 是本地 HTTP server 行为模拟，可保留；核心生命周期测试应优先改为确定性同步。

#### FR-030 `sample/ejs_sample.c` 用栈上 `SampleHost` 演示 host user_data

- 来源：Gemini，当前源码确认，风险限于 sample/示例误导。
- 位置：
  - `sample/ejs_sample.c:107-116`
- 问题：
  sample 把栈上 `SampleHost` 地址作为 `EJSCoreUserData`。当前示例流程同步完成并在函数返回前 destroy，通常不会直接触发 UAF；但作为示例会误导异步 host operation 也可安全使用栈地址。
- 影响：
  示例代码会诱导错误集成方式。应改为堆分配并展示 release 回调，或明确注释只适用于同步、短生命周期 sample。

## 3. Gemini Findings Disposition

| Gemini 条目 | 最终处理 | 原因 |
| --- | --- | --- |
| 1.1 Core runtime destroy 释放 context 导致 UAF | 降级为 FR-001 | core 是 platform 内部 ABI；先文档化 runtime destroy 会使 context handle 失效，并要求 platform 侧保证销毁顺序 |
| 1.2 Apple retain cycle | 采纳为 FR-005 | Core user_data `CFBridgingRetain(self)` 与 `_coreContext` 形成环 |
| 1.3 TLS error message reentrant UAF | 不纳入最终问题 | 当前异步 completion 已复制 `message/platform_domain`；同步路径即时消费，未看到持久悬挂指针 |
| 1.4 Sample stack user_data | 降级为 FR-030 | 当前 sample 自身通常安全，但示例模式有误导性 |
| 2.1 FS `"wx"` TOCTOU | 提升为 FR-007 / P0 | 当前 `writeFile` 和 `copyFile` 都是先查再写，属于数据覆盖边界问题 |
| 2.2 Apple invalidate deadlock | 采纳为 FR-006 | 与 Codex platform 审查结论一致，platform 层可直接触发 |
| 2.3 FS/SQLite 全局串行队列 | 降级为 FR-024 | 属于吞吐/尾延迟设计问题，不是直接 correctness bug |
| 3.1 KV O(N) manifest | 降级为 FR-025 | 属于扩展性瓶颈，需结合模块定位决定修复强度 |
| 3.2 Data URL emoji/内存抖动 | 暂不纳入最终问题 | 当前实现未证明会崩溃；需要用 `data:,<emoji>`/percent encoding 语义补复现 |
| 3.3 sync empty result 未初始化 | 不纳入最终问题 | 当前 `ejs_context_dispatch_host_invoke_sync` 入口已 `memset(result_out, 0, ...)` |
| 4.1 TypedArray 属性劫持 | 采纳为 FR-023 | 当前确实读取 JS 属性；边界风险存在但未证明越界 |
| 5.1 OCMock/GTest 补测试建议 | 不纳入最终问题 | 属于泛化测试建议，缺少具体回归漏检证据 |
| 5.2 usleep flaky | 采纳为 FR-029 | 当前测试中大量固定 sleep，属于测试可靠性风险 |
| 5.3 CMake engine fallback | 不纳入最终问题 | 根 `CMakeLists.txt` 已校验 `EJS_ENGINE`/`EJS_RUNTIME_LOOP` allowed values |
| 5.3 Apple sample Foundation 显式链接 | 不纳入最终问题 | 当前通过 `ejs_wintertc_apple` 间接满足；未形成具体构建失败证据 |
| 5.3 CLI timeout overflow | 采纳为 FR-026 | 当前 parse 无上限，deadline 乘法存在溢出可能 |

## 4. Suggested Fix Order

1. FR-009、FR-007：先修 KV manifest 路径逃逸和 FS exclusive create TOCTOU。
2. FR-022、FR-008：补 header value 非法字符拒绝，以及 Node-like option 类型语义，避免输入边界继续依赖宽松 coercion。
3. FR-018、FR-019、FR-020、FR-021：集中修 Node/Web 行为对齐，并同步更新测试。
4. FR-006、FR-005、FR-003：修 platform/runtime teardown 的卡死、泄漏和 terminal shutdown 失败路径。
5. FR-004、FR-010、FR-011、FR-012、FR-013、FR-014：修静默数据错误、大结果内存、fetch/stream correctness。
6. FR-001、FR-002：先补 core ABI 接口文档和 platform teardown guard；后续再做 core 防御式 hardening。
7. FR-015、FR-027、FR-028、FR-029：补边界检查、验证命令和测试可靠性。
8. 其余 P2 按性能、扩展性和示例质量排期。

## 5. Verification Notes

本报告是 review 整合产物，未修改业务代码，也未运行完整测试套件。后续每个修复项建议至少包含：

- 一个失败优先的定向 regression test。
- 对应模块测试目标。
- `ejs_platform_boundary_check`，若触及 CMake/platform 边界。
- 涉及 Apple JS bundle 的改动需重建对应 Apple target 后再运行测试。
