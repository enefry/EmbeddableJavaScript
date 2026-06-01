# EJS Worker

`modules/worker` 是可选 add-on。root `platform/apple` 不会自动安装；调用方需要显式
链接 `ejs_worker_apple` 并调用 `EJSWorkerInstallIntoContext(...)` 或
`EJSWorkerInstallIntoContextWithOptions(...)`。

## JavaScript API

父上下文暴露 `Worker` 和只读诊断对象 `EJSWorker`：

```js
const worker = new Worker("echo", {
  root: "app",
  type: "classic",
  name: "echo-worker"
});

worker.onmessage = (event) => {};
worker.onerror = (event) => {};
worker.onmessageerror = (event) => {};
worker.postMessage({ op: "ping" });
worker.postMessage(buffer, [buffer]);
worker.terminate();
```

Worker 子上下文提供 `self === globalThis`，并支持：

- `postMessage(value, transferList)`
- `onmessage` / `onerror` / `onmessageerror`
- `onunhandledrejection` / `onrejectionhandled`
- `addEventListener` / `removeEventListener`
- `close()`

## 配置键

配置键为 `EJSWorkerConfigurationKey` / `"ejs.worker"`。配置包含 root 白名单、脚本白名单、
inline 源码、路径策略和资源限制（`maxWorkers`、`maxQueuedMessages`、
`maxMessageBytes`、`maxSourceBytes` 等）。

## Apple Notes

- 每个 Worker 创建独立 `EJSRuntime + EJSContext`。
- 子上下文 `close()` 会向父上下文发送内部关闭通知，用于释放父端 `Worker`
  状态表；该通知不是公开事件。
- `modules/worker/platform/apple` 不暴露 QuickJS-ng 私有类型，也不直接调用
  `JSRuntime` / `JSContext` / `JSValue` / `JS_WriteObject2` / `JS_ReadObject`。
- `installWorkerContext` 回调用于宿主按需给子上下文安装其它可选模块。

## Verification

```sh
node --check modules/worker/js/worker_parent.js
node --check modules/worker/js/worker_child.js
node tests/js/worker_js_test.js
cmake --build build --target ejs_worker_apple_test
ctest --test-dir build -R "ejs_worker_js_test|ejs_worker_apple_test" --output-on-failure
```
