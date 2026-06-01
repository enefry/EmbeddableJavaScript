# 全工程代码审查报告汇总 (EJS JS-Runtime)

经过多个子Agent对项目全工程的并发审查，以下是针对 `core`、`platform` 和 `modules` 三大模块发现的问题列表及修复建议：

> **验证状态说明**：以下所有问题项均已通过独立验证子 Agent 在最新代码库中完成真实性核对与确认。

## 一、核心层 (Core 模块)

### 1. 同步万能通道参数校验遗漏导致静默错误 (Bug)
*   **状态**：✅ **已验证** (确实遗漏了 else 分支)
*   **文件路径**：`core/src/ejs_engine_quickjs_ng.c`
*   **行数范围**：`1684-1707` (`ejs_native_invoke_sync` 函数)
*   **问题描述**：在解析 `payload` 和 `transfer_buffer` 时，如果传入无法解析为二进制 Buffer 的非法对象（例如普通 `{}`），`ptr` 将返回 `NULL`。代码缺少 `else` 错误处理分支，导致 `payload.data` 保持为初始的 `NULL`，不会向 JS 层抛出 `TypeError`，而是静默将空数据传递给了宿主。
*   **修复建议**：为提取逻辑增加 `else` 分支并抛出异常（如 `JS_ThrowTypeError`）。

### 2. Top-Level Await 模块加载失败成“黑洞” (API 设计与架构缺陷)
*   **状态**：✅ **已验证** (JS_Eval 返回 Promise 时未正确处理)
*   **文件路径**：`core/src/ejs_engine_quickjs_ng.c`
*   **行数范围**：`2678-2709` (`ejs_engine_eval_module` 函数及 `ejs_result_from_eval`)
*   **问题描述**：当模块使用了 Top-Level Await 时，`JS_Eval` 会返回 Promise。代码仅判断返回值非 `JS_EXCEPTION` 后便直接释放 (`JS_FreeValue`) 并返回 `EJS_STATUS_OK`。这导致调用方完全无法感知模块异步加载的失败状态。
*   **修复建议**：检查 `JS_Eval` 返回值，若是 Promise 则挂载 then/catch 处理器或将其封装到异步回调机制中告知宿主。

### 3. 内存管理与并发设计评估 (优良，需完善注释)
*   **状态**：✅ **已验证** (机制稳健，建议补充解绑/释放相关注释)
*   **文件路径**：`core/src/ejs_engine_quickjs_ng.c` (`EJSInvokeState` 和 `EJSTimerState`)
*   **审查结论**：核心内存管理与并发机制表现优异，巧妙利用原子操作正确规避了 JS GC、宿主回调和主线程退出时的三方冲突，无明显内存泄漏。
*   **改进建议**：针对 `EJSInvokeState` 的所有权转移，补充架构级别注释。特别是强调 `ctx` 的 GC/上下文销毁解耦，以及 `host_ref_released` 的防御性释放逻辑，明确不同生命周期阶段的引用计数设计。

---

## 二、平台层 (Platform 模块)

### 1. `dealloc` 中重新强引用自身引发循环/递归 Crash 隐患 (Critical)
*   **状态**：✅ **已验证** (ARC 下重新 retain self)
*   **文件路径**：`platform/apple/src/EJSApplePlatform.m`
*   **行号**：`L1089-L1091` / `L1233-L1265`
*   **问题描述**：在 `-[EJSRuntime dealloc]` 调用的 `invalidate` 中，若有未清理的上下文会执行 `_selfRetainForPendingTeardown = self;`。ARC 机制下对象在 `dealloc` 时引用计数已为 0，重新强引用自身会导致应用崩溃或无限递归。
*   **修复建议**：引入 `_isDeallocating` 标志，在 `dealloc` 内跳过异步保活等待，强制同步释放。

### 2. 异步 Invoke 同步失败时返回操作句柄导致 Use-After-Free / 重入 (Critical)
*   **状态**：✅ **已验证** (提前 finish 后仍返回 coreOperation)
*   **文件路径**：`platform/apple/src/EJSApplePlatform.m`
*   **行号**：`L621-L627`, `L669-L678` 
*   **问题描述**：在 `ejs_context_dispatch_host_invoke` 中，若校验失败调用 `completeWithData` 后会触发销毁操作，但函数最后仍返回了被销毁的 `coreOperation` 句柄，导致 Core 引擎发生 Use-After-Free。
*   **修复建议**：内部释放完毕后应返回 `NULL`，或将 `completeWithData` 推迟到异步队列执行。

### 3. 热点路径上的高频对象分配与锁竞争 (Performance)
*   **状态**：✅ **已验证** (频繁分配 NSNumber 与锁竞争)
*   **文件路径**：`platform/apple/src/EJSApplePlatform.m`
*   **行号**：`L1622-L1624`, `L1639-L1641`, `L1662-L1669`
*   **问题描述**：使用全局锁 (`self.stateCondition`) 和频繁的 `NSNumber` 对象分配 (`@(threadID)`, `@(threadDepth)`) 来追踪 `EJSContext` 线程调用深度，造成极大性能负担。
*   **修复建议**：使用线程局部存储变量（如 `_Thread_local`）实现无锁化与零分配。

### 4. 同步 Invoke 存在不必要的内存深拷贝 (Performance)
*   **状态**：✅ **已验证** (使用了 dataWithBytes:length:)
*   **文件路径**：`platform/apple/src/EJSApplePlatform.m`
*   **行号**：`L385-L395` / `L718-L719`
*   **问题描述**：`ejs_context_dispatch_host_invoke_sync` 底层使用 `[NSData dataWithBytes:length:]` 引发内存深拷贝。
*   **修复建议**：使用 `[NSData dataWithBytesNoCopy:length:freeWhenDone:NO]` 避免深拷贝。

### 5. 返回空结果时缺失结构体显式初始化 (Warning)
*   **状态**：✅ **已验证** (完全依赖 memset)
*   **文件路径**：`platform/apple/src/EJSApplePlatform.m`
*   **行号**：`L696-L698`, `L769-L786`
*   **问题描述**：同步调用若结果长度为 0，没有调用 `ejs_byte_buffer_init` 初始化 `result_out`，依靠 `memset` 并不完全符合严格的 C API 规范。
*   **修复建议**：增加显式初始化分支 `ejs_byte_buffer_init(...)`。

---

## 三、模块层 (Modules 模块)

### 1. I/O 并发与线程安全瓶颈 (Thread Safety & Concurrency)
*   **状态**：✅ **已验证** (fs/sqlite 使用 Serial，kv 存在全局锁)
*   **文件**：`fs`, `sqlite`, `kv` 模块内的 Apple 平台实现文件
*   **问题描述**：强制使用单一串行队列（如 `DISPATCH_QUEUE_SERIAL`）处理所有异步请求（如 fs 和 sqlite），或在并发队列中使用 `NSLock` 锁定单一 store (如 kv)，导致 I/O 任务串行执行，丧失异步 I/O 优势。
*   **修复建议**：替换为并发队列（`DISPATCH_QUEUE_CONCURRENT`），并利用 `NSLock`、读写锁等进行局部状态同步，同时优化现有锁的粒度。

### 2. 文件写入存在死循环风险 (Infinite Loop Risk in I/O)
*   **状态**：✅ **已验证** (未处理 write 返回 0)
*   **文件**：`modules/fs/platform/apple/src/EJSFileSystemApple.m`
*   **问题描述**：写入文件循环仅通过 `written < 0` 判断错误，若 POSIX `write()` 返回 0，将导致 `remaining` 不变，陷入死循环和 CPU 满载。
*   **修复建议**：将错误判断条件修改为 `if (written <= 0)`。

### 3. SQLite 数据库连接关闭时资源泄漏 (Resource Leak)
*   **状态**：✅ **已验证** (存在未检查返回值的 sqlite3_close 调用)
*   **文件**：`modules/sqlite/platform/apple/src/EJSSQLiteApple.m`
*   **问题描述**：直接调用 `sqlite3_close()` 关闭存在未完成语句的数据库会返回 `SQLITE_BUSY` 且不关闭，导致资源泄漏。
*   **修复建议**：推荐使用 `sqlite3_close_v2()` 允许自动延迟安全销毁。

### 4. JS 层 SQLite 事务的竞态条件 (Race Condition in Transactions)
*   **状态**：✅ **已验证** (使用实例共享的 _activeTx)
*   **文件**：`modules/sqlite/js/sqlite.js`
*   **问题描述**：事务 ID 保存在共享实例 `_activeTx` 上。在异步期间并发的普通查询会被错误纳入事务中，破坏事务隔离性。
*   **修复建议**：`transaction` 回调应向用户暴露一个专用的 `TransactionClient` 对象以避免共享状态被污染。

### 5. 纯 JS 编解码实现的性能与冗余问题 (Code Duplication & Performance)
*   **状态**：✅ **已验证** (5 个独立文件冗余实现了 UTF-8 编解码)
*   **文件**：`modules/buffer/js/buffer.js`, `modules/fs/js/fs.js`, `modules/kv/js/kv.js`, `modules/sqlite/js/sqlite.js`, `modules/wintertc/js/encoding.js`
*   **问题描述**：各模块复制了纯 JS 实现的 UTF-8 编解码函数，执行效率低且增加代码冗余。
*   **修复建议**：将编解码逻辑沉淀至 Native 层（如 C++ 转换机制），在 JS 模块中统一复用。
