# Gemini Worker Review v2

经过对修改后的代码进行再次审查，发现之前提到的一些核心问题（如 OOM 风险、`ArrayBuffer` 的克隆问题、未捕获的 Promise 错误处理）**已经被修复**。

但是，当前的实现中引入或暴露出了新的严重缺陷，特别是涉及到**并发执行**和**启动时序**方面：

### 1. 彻底丧失了 Worker 的并行执行能力 (Concurrency Loss)
* **位置**：`EJSWorkerApple.m` (`_dispatchQueue`)
* **分析**：原生层为了保证线程安全，创建了一个单例的串行队列 `DISPATCH_QUEUE_SERIAL`：
  ```objc
  _dispatchQueue = dispatch_queue_create("dev.ejs.worker.dispatch", DISPATCH_QUEUE_SERIAL);
  ```
  在 `dispatchMessageToContext:` 方法中，**所有**的 Worker（不论多少个）以及发往父环境的消息派发（`evaluateScript:`）全部在这个单一的串行队列中排队执行。这使得所有 Web Worker 的消息处理变成了**完全的串行化**，彻底违背了 Worker 用于后台并行计算的初衷。

### 2. 初始化时会导致父线程同步阻塞 (Synchronous Execution Block)
* **位置**：`EJSWorkerApple.m` (`createWorkerWithRequest:`)
* **分析**：在创建 Worker 时，直接在当前调用线程（通常是父 JS 环境所在线程）**同步**调用了：
  ```objc
  didEvaluate = [childContext evaluateScript:source filename:filename error:error];
  ```
  这意味着如果子 Worker 的顶层初始化代码包含耗时任务（或巨大的循环），父线程将会被一直**阻塞挂起**，直到该脚本在子上下文中运行完毕。这会引发严重的 UI 卡顿或主线程冻结。

### 3. 启动初期的消息丢失与报错 (Race Condition & Message Loss on Startup)
* **位置**：`worker_child.js` / `EJSWorkerApple.m` (`enqueueMessageFromChildForInstance:`) / `worker_parent.js`
* **分析**：这是一个典型的时序竞争 Bug，分为两个层面：
  1. **被原生层拦截**：如果子 Worker 在顶层脚本中立即调用 `postMessage()`（基于 Promise 微任务实现），由于 `evaluateScript:` 可能在排空微任务后才返回，此时在 `EJSWorkerApple.m` 中 `instance.state` 仍是 `Starting`。原生代码会直接拦截并报错 `"Worker is not running"`。
  2. **被父环境丢弃**：即使消息投递成功并触发了父环境的 `__EJSWorkerDispatch`，如果父环境的 `new Worker()` 微任务（负责将实例放入 `workerTable`）还没来得及执行，父环境查不到 `workerID` 会直接 `return` 丢弃消息。由于没有调用 `takeMessage`，该消息还会死锁在原生层的 `parentInbox` 队列中。

### 4. `close()` 时的强制上下文销毁风险 (Premature Context Invalidation)
* **位置**：`EJSWorkerApple.m` (`closeFromChildForInstance:`)
* **分析**：当子 Worker 主动调用 `close()` 时，原生层准备了一个 `terminationNotification` 并**异步**派发给父环境，但紧接着**同步**调用了：
  ```objc
  [instance.context invalidate];
  [instance.runtime invalidate];
  ```
  如果在 JS 引擎层面上，上下文中还有未处理的事件（例如 `childInbox` 里还没被 take 的消息），或者直接强杀 context 可能会导致引擎抛出异常，这种时序是不安全的。正确的做法应该是等待清理工作完成后再销毁底层 Runtime。

### 5. `Worker.terminate()` 的冗余调用
* **位置**：`worker_parent.js` (`Worker.prototype.terminate`)
* **分析**：在极端情况下（比如还在 `starting` 状态就调用 `terminate`），通过 `.finally(() => this._terminateNow())` 会导致 `_terminateNow()` 被执行两次，尽管原生层兼容了这种重复调用，但在 JS 侧的逻辑流转略显冗余和不严谨。
