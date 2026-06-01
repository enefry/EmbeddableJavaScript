# Gemini Worker Implementation Review

在审查当前的 Worker 实现（包括 `worker_parent.js`、`worker_child.js` 和 `EJSWorkerApple.m`）后，发现了以下几个主要问题：

## 1. 内存泄漏：Worker 子线程主动 `close()` 导致父端对象泄漏
在 `worker_child.js` 中调用 `close()` 时，原生层 (`EJSWorkerApple.m`) 会调用 `terminateWorkerWithRequest:` 销毁 Worker 实例并从 `_workers` 字典中移除。但它**没有向父环境发送任何通知**。
导致在 `worker_parent.js` 中，`Worker` 实例的状态永远保持为 `"running"`，并且被一直强引用在全局的 `workerTable` `Map` 中，造成该 Worker 的 JS 对象及其挂载的事件监听器永远无法被垃圾回收。

## 2. 消息队列无上限 (OOM 风险)
系统策略中定义了 `maxQueuedMessages`，但该限制仅在 `worker_parent.js` 初始化阶段 (`state === "starting"`) 被用来限制 `_pendingOutgoing` 数组。
当 Worker 处于运行状态时，原生层的 `postMessageWithRequest:` 和 `enqueueMessageFromChildForInstance:` 会将消息无条件追加到 `instance.childInbox` 和 `instance.parentInbox` 中，**完全没有检查队列上限**。如果接收方处理缓慢或被阻塞，将导致消息队列无限增长，最终引发 OOM。

## 3. 结构化克隆算法实现存在严重缺陷 (`ArrayBuffer` 处理)
`worker_parent.js` 和 `worker_child.js` 中的 `serializeForMessage` 函数在处理 `ArrayBuffer` 和 `ArrayBufferView` 时存在破坏共享和内存状态的问题：
- **丢失底层 Buffer 共享与重复拷贝**：每当遇到 `ArrayBuffer` 或 `ArrayBufferView` 时，都会通过 `appendChunk` 创建全新的内存拷贝。由于未通过 `seenObjects` 追踪并复用 Buffer，如果多处引用同一个 `ArrayBuffer`，它会被序列化并复制多次。反序列化后它们将不再共享同一块内存。
- **丢失 `byteOffset` 和原始容量**：对 `ArrayBufferView` 序列化时，只拷贝了该 View 所在的切片 `new Uint8Array(innerValue.buffer, innerValue.byteOffset, innerValue.byteLength)`。反序列化时，会以这个小切片为基础创建一个全新的 View，导致原有的底层大 Buffer 容量丢失，且新 View 的 `byteOffset` 强制变成了 0。

## 4. 潜在的同步阻塞/线程模型缺陷
通过 `dispatchMessageToContext` 分发消息时，直接调用了 `[targetContext evaluateScript:...]`。如果 `EJSContext` 的 `evaluateScript:` 方法在调用者所在的同一线程中同步执行，那么 `postMessage` 实际上是同步阻塞执行的，子线程的计算将会阻塞父线程（反之亦然），这彻底违背了 Web Worker 异步并发的设计初衷。即便是跨线程调用，也需要确认 `EJSContext` 内部是否有安全的异步派发机制。

## 5. 缺失未捕获 Promise 拒绝 (Unhandled Promise Rejection) 监听
在 `worker_child.js` 中，虽然提供了 `reportError` 函数并将其绑定到了 `globalThis.onerror`，但并**没有监听 `unhandledrejection` 事件**。这意味着在 Worker 内未被 `.catch()` 的 Promise 错误会被静默吞掉，永远无法冒泡触发父端的 `onerror` 事件。

## 6. `takeMessageForParentWithRequest` 中可能向 nil 发送消息
在原生层的 `takeMessageForParentWithRequest:` 中：
```objc
    EJSWorkerInstance *instance = [self workerForID:workerID];
    NSString *name = instance.name;
```
如果 `workerForID:` 找不到对应的实例返回 `nil`，则 `instance.name` 和 `instance.parentInbox` 调用均向 `nil` 发送消息。尽管在 Objective-C 中向 `nil` 发送消息不会崩溃并返回 0/nil，但这属于不良的代码习惯，应该提早判断 `instance == nil` 再提取属性。
