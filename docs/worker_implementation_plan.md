# EJS Worker 实施计划

更新时间：2026-05-28
状态：阶段2规划，未开始
来源：[module_alignment_roadmap.md](module_alignment_roadmap.md)

本文是 `modules/worker` 的独立实施 source-of-truth。总 roadmap 只保留阶段状态和
TODO 看板；Worker 的 API、边界、Apple 实现拆分、测试门禁以本文为准。

## 1. 阶段目标

阶段2 Worker 完成门禁：

- `new Worker(specifier, options)` 可用，入口解析规则清晰且受宿主配置约束。
- `postMessage/onmessage` 双向消息可用，错误路径可诊断。
- `terminate()` 幂等，启动失败、启动中终止、父 context invalidate、子 `close()` 都能可靠释放资源。
- `ArrayBuffer` transfer 有首版支持和回归测试。
- `modules/worker` 不把 QuickJS-ng 私有类型暴露到 module/provider 边界。
- 完成test case全路径覆盖，代码覆盖率95%+

首版目标是浏览器 Web Worker 形态的嵌入式子集，不做 Node.js
`worker_threads` 兼容层。

## 2. 边界与非目标

`modules/worker` 是可选 add-on：

- `core` 不暴露 Web Worker 策略，也不导出 QuickJS-ng 的 `qjs:os.Worker`。
- root `platform/*` 不自动安装 Worker，也不承载 Worker 私有配置。
- 每个 Worker 拥有独立 `EJSRuntime` + `EJSContext`，共享进程但不共享 JS 对象。
- 消息通过结构化克隆子集传递；首版由 JS wrapper 打包 envelope + sidecar bytes。
- Worker 入口加载必须受 `EJSWorkerConfigurationKey` / `"ejs.worker"` 配置约束，不能绕过文件/内联源码白名单读取任意路径。

首版明确不支持：

- nested worker
- `importScripts()`
- `blob:` / `data:` / `http:` worker URL
- `SharedArrayBuffer`
- 通用静态 `import` / `import()` 解析
- Node.js `worker_threads`
- 在 `modules/worker/platform/apple` 直接调用 QuickJS-ng clone API

这些能力等阶段5 loader 策略或 engine-neutral structured-clone capability 明确后再扩展。

## 3. QuickJS-ng 复用边界

当前 `modules/*` 抽象不直接依赖 QuickJS-ng，Worker 也必须保持同一边界：

- `modules/worker` 的 JS wrapper、类型声明、README 和 provider 协议只能依赖
  `__ejs_native__`、`EJSRuntime`、`EJSContext`、`EJSProvider` 等 EJS 稳定抽象。
- `modules/worker/platform/apple` 不包含 `quickjs.h`，不出现 `JSRuntime`、
  `JSContext`、`JSValue`，也不调用 `JS_WriteObject2` / `JS_ReadObject`。
- qjs 代码参考实现
- 不直接暴露 `qjs:os.Worker`、`qjs:std`、`qjs:os`、`js_std_add_helpers`
  或 qjs CLI module loader，避免绕过 EJS 模块开关、路径策略和宿主安装流程。

可复用的是 qjs Worker 的实现经验，而不是 module API：

- 独立 runtime/context 的启动模型。
- 端口 close/terminate 的生命周期顺序。
- 消息队列、唤醒和关闭后丢弃消息的处理方式。
- structured clone 若要复用 `JS_WriteObject2` / `JS_ReadObject`，先落到
  QuickJS 后端私有 helper，再通过 EJS capability 被 Worker provider 选择性使用。

如果该 capability 尚未完成，首版使用 JS wrapper 的 JSON envelope + sidecar
buffer。这是边界正确的保守实现，不应为了复用 qjs 直接把 QuickJS 类型传入 module。

## 4. JavaScript API

父上下文安装后提供标准名 `Worker`，并提供只读诊断对象 `EJSWorker`：

```js
const worker = new Worker("echo", {
  root: "app",
  type: "classic",
  name: "echo-worker"
});

worker.postMessage({ op: "ping" });
worker.postMessage(buffer, [buffer]);
worker.onmessage = (event) => {};
worker.onerror = (event) => {};
worker.onmessageerror = (event) => {};
worker.addEventListener("message", handler);
worker.removeEventListener("message", handler);
worker.terminate();
```

Worker 子上下文提供最小 worker global scope：

```js
self === globalThis;
postMessage(value, transferList);
onmessage = (event) => {};
onerror = (event) => {};
onmessageerror = (event) => {};
addEventListener("message", handler);
removeEventListener("message", handler);
close();
```

事件对象首版采用轻量对象：`{ type, data, target, currentTarget }`。错误事件为
`{ type: "error", message, filename, stack, error }`。

如果安装了 WinterTC 的 `EventTarget`，Worker wrapper 复用它；否则
`modules/worker` 自带最小事件分发器。

`new Worker()` 必须同步返回对象。由于当前 native 通道是 Promise 式异步
`__ejs_native__.invoke`，构造函数内部进入 `starting` 状态：

- 启动完成前的 `postMessage` 先进入有上限的队列。
- 启动成功后 flush 队列。
- 启动失败时派发 `error` 事件并丢弃队列。
- `terminate()` 进入 `terminating/terminated` 后，后续 `postMessage` 抛出可诊断错误。

## 5. 入口加载策略

配置键为 `EJSWorkerConfigurationKey` / `"ejs.worker"`，Apple 首版配置形态：

```json
{
  "version": 1,
  "defaultRoot": "app",
  "roots": {
    "app": {
      "path": "/absolute/app/root",
      "permissions": ["read"]
    }
  },
  "scripts": {
    "echo": {
      "root": "app",
      "path": "workers/echo.js",
      "type": "classic"
    }
  },
  "inlineScripts": {
    "inline-echo": {
      "source": "onmessage = e => postMessage(e.data);",
      "type": "classic"
    }
  },
  "pathPolicy": {
    "allowAbsolutePath": false,
    "allowParentTraversal": false,
    "allowSymlinkEscape": false
  },
  "limits": {
    "maxWorkers": 4,
    "maxQueuedMessages": 64,
    "maxMessageBytes": 1048576,
    "maxSourceBytes": 1048576,
    "startupTimeoutMs": 5000,
    "terminationTimeoutMs": 2000
  }
}
```

解析顺序：

1. `specifier` 必须是非空字符串。
2. 若命中 `scripts[specifier]` 或 `inlineScripts[specifier]`，使用白名单定义。
3. 否则把 `specifier` 当作 `options.root || defaultRoot` 下的相对路径。
4. 默认拒绝绝对路径、`..`、解析后逃逸 root 的 symlink、以及 URL scheme。
5. 读取源码后用稳定虚拟 URL 作为诊断名：`ejs-worker://<root>/<path>` 或
   `ejs-worker:inline/<name>`。
6. `type: "classic"` 用 `evaluateScript` 执行。
7. `type: "module"` 用 `evaluateModule` 执行入口源码，但首版不提供静态
   `import` / `import()` 解析。

如果入口模块含未解析 import，错误必须包含 worker specifier 和失败的 module
specifier。`importScripts()` 首版明确不实现，避免在通用 loader 策略确定前引入第二套脚本解析规则。

## 6. 消息与 Transfer

在不突破 module/engine 边界的前提下，首版 structured-clone 子集由 JS wrapper 打包：

- 支持 `null`、boolean、number、string、Array、普通 Object。
- 支持 `ArrayBuffer`、TypedArray、DataView；二进制内容进入 sidecar buffer。
- `transferList` 只接受 `ArrayBuffer` 或 view 对应的 buffer。
- 重复 transfer、未出现在消息中的 buffer、已 detached buffer 都抛错。
- 函数、symbol、WeakMap、WeakSet、带循环引用对象、DOM 对象、Map/Set/Error/RegExp、
  `SharedArrayBuffer` 首版拒绝并派发或抛出 `messageerror`。

传输格式：

- `payload` 是 JSON envelope，记录值树、二进制片段的 offset/length/type、transfer 标记。
- `transfer_buffer` 是所有二进制片段按顺序拼接后的 ArrayBuffer。
- 发送端完成复制后，对 transfer list 中的 ArrayBuffer 调用 QuickJS-ng 支持的
  `ArrayBuffer.prototype.transfer(0)` 使原 buffer detached。
- 非 QuickJS 后端首版返回 unsupported。
- native provider 只保存和转发 envelope + bytes，不解释 JS 对象语义。
- 目标上下文由 JS wrapper 解包并派发 `message`。

为了避免在 `evaluateScript` 中内嵌大块 base64，native 事件只投递轻量通知：

```js
globalThis.__EJSWorkerDispatch(workerID, messageID);
```

目标 wrapper 收到通知后调用 `ejs.worker/takeMessage` 拉取对应二进制消息，再解包派发。

后续若 core 暴露 engine-neutral structured-clone capability，QuickJS-ng 后端可以在该
capability 内复用 `JS_WriteObject2` / `JS_ReadObject`；`modules/worker` 仍不得直接包含或调用 qjs API。

## 7. Native Provider 协议

Provider module ID：`"ejs.worker"`。

| 方法 | 方向 | 说明 |
| --- | --- | --- |
| `create` | parent -> native | 解析 specifier，创建子 runtime/context，安装 child provider 和 child bootstrap，执行入口 JS，返回 `workerID`。 |
| `postMessage` | parent/child -> native | 接收 envelope + transfer buffer，存入目标 inbox，投递 `__EJSWorkerDispatch`。 |
| `takeMessage` | parent/child -> native | 目标上下文按 `messageID` 拉取 envelope + bytes，拉取后从 inbox 移除。 |
| `terminate` | parent -> native | 幂等终止子 context/runtime，清理 inbox 和队列。 |
| `close` | child -> native | 子上下文主动关闭，语义等价于 worker 自身请求 terminate。 |
| `reportError` | child -> native | 子上下文同步 eval 错误、异步异常和 unhandled rejection 上报到父上下文。 |

错误必须落到稳定分类：

- 参数错误：invalid argument
- 路径或策略违规：security
- 不支持的 `type` / URL / `importScripts` / `SharedArrayBuffer`：unsupported
- 启动和内部状态损坏：internal

错误消息必须包含 `workerID`（若已分配）、`name`（若传入）、`specifier`。

## 8. Apple 实现计划

新增目录与目标：

```text
modules/worker/README.md
modules/worker/types/index.d.ts
modules/worker/js/worker_parent.js
modules/worker/js/worker_child.js
modules/worker/cmake/generate_worker_bundle.cmake
modules/worker/CMakeLists.txt
modules/worker/platform/apple/include/EJSWorkerApple.h
modules/worker/platform/apple/src/EJSWorkerApple.m
tests/worker/apple/ejs_worker_apple_test.m
```

Apple 公开安装接口：

```objc
FOUNDATION_EXPORT NSString * const EJSWorkerConfigurationKey;

@interface EJSWorkerInstallOptions : NSObject <NSCopying>
@property (nonatomic, copy, nullable) BOOL (^installWorkerContext)(EJSContext *workerContext, NSError **error);
@end

FOUNDATION_EXPORT BOOL EJSWorkerInstallIntoContext(EJSContext *context, NSError **error);
FOUNDATION_EXPORT BOOL EJSWorkerInstallIntoContextWithOptions(EJSContext *context,
                                                             EJSWorkerInstallOptions *_Nullable options,
                                                             NSError **error);
```

`installWorkerContext` 让宿主为子上下文显式安装可选模块，例如 WinterTC、fs、kv。默认只安装
`modules/worker` 的 child bootstrap，不继承父上下文已安装的 add-on。这样保持 add-on
边界明确，也避免 `modules/worker` 反向依赖所有其它模块。

核心类职责：

- `EJSWorkerProvider`：注册到父上下文，解析策略，管理 worker 表、全局限制和父侧 inbox。
- `EJSWorkerInstance`：持有 `workerID`、name、状态、子 `EJSRuntime`、子 `EJSContext`、
  子 provider、inbox、生命周期队列。
- `EJSWorkerChildProvider`：注册到子上下文，把 child `postMessage` / `close` /
  `reportError` 转发给父 provider。
- `EJSWorkerSourcePolicy`：解析 `ejs.worker` JSON，执行 root/symlink/大小限制检查。

启动顺序：

1. 父上下文安装时用 `EJSAppleInstallTransaction` 捕获 `Worker`、`EJSWorker`、
   `__EJSWorkerDispatch` 等全局名；注册 `EJSWorkerProvider`；加载 parent JS bundle。
2. `create` 在 provider 生命周期队列中分配 `workerID`，检查 `maxWorkers`。
3. 解析并读取入口源码，创建子 `EJSRuntime` 和子 `EJSContext`。
4. 给子上下文注册 `EJSWorkerChildProvider`。
5. 调用 `installWorkerContext`（如有），再加载 `worker_child.js`。
6. 执行入口 `classic` script 或单文件 module。
7. 成功后返回 `workerID`；失败时 rollback 子上下文/子 runtime，并向父 wrapper 派发 error。

销毁顺序：

1. `terminate()` 或父 context invalidate 先把实例状态改为 terminating，停止接收新消息。
2. 清理父/子 inbox 和未派发消息。
3. invalidate 子 context/runtime；等待完成或按 `terminationTimeoutMs` 记录诊断后继续释放引用。
4. 从 worker 表移除；重复 terminate 直接返回成功。

## 9. 实施拆分

1. **API/文档骨架**：新增 module README、types、CMake、Apple 头文件和空 installer；root
   CMake/test CMake 接入。
2. **边界骨架**：确认 `modules/worker` 和 `modules/worker/platform/apple` 只依赖 EJS
   platform/provider 抽象；qjs 复用点只允许落在 core QuickJS-ng 后端私有 helper。
3. **Parent/child JS wrapper**：实现事件分发、同步构造对象、starting 队列、terminate
   状态、消息 pack/unpack；用 Node mock provider 做 wrapper 测试。
4. **Apple 启动与 classic 入口**：实现 `ejs.worker` 策略、文件/inline source 加载、子
   runtime/context、child bootstrap、echo worker Apple 测试。
5. **双向消息与错误事件**：实现 inbox、`takeMessage`、`reportError`、启动失败、入口
   throw、unhandled rejection 上报。
6. **ArrayBuffer transfer**：先实现 sidecar binary frame、transferList 校验、detached
   行为、大小限制和回归测试；再评估是否通过 engine-neutral capability 接入 qjs native clone。
7. **生命周期硬化**：覆盖启动中 terminate、重复 terminate、父 context invalidate、子
   `close()`、provider dealloc、消息到达已关闭 worker。
8. **文档同步**：补 `modules/worker/README.md`、`types/index.d.ts`、`docs/design.md`，
   并更新 `docs/module_alignment_roadmap.md` 状态。

## 10. 验证门禁

Worker 阶段完成前至少通过：

```sh
node --check modules/worker/js/worker_parent.js
node --check modules/worker/js/worker_child.js
node tests/js/worker_js_test.js
if rg -n "quickjs|JSRuntime|JSContext|JSValue|JS_WriteObject2|JS_ReadObject|qjs:os" modules/worker; then exit 1; fi
cmake --build build --target ejs_worker_apple_test ejs_core_test ejs_apple_platform_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_worker_apple_test|ejs_core_test|ejs_apple_platform_test|ejs_platform_boundary_test" --output-on-failure
git diff --check
```

Apple 测试用例必须覆盖：

- 安装成功、安装失败 rollback、缺失/非法 `ejs.worker` 配置。
- `new Worker()` 同步返回，启动前 `postMessage` 排队，启动后 flush。
- classic echo、worker -> parent、parent -> worker 双向消息。
- 启动入口 throw、异步异常、unhandled rejection 上报到父 `error`。
- `messageerror`：不可 clone 值、非法 transferList、过大消息。
- `ArrayBuffer` transfer 后发送端 detached，接收端字节一致。
- `terminate()` 重复调用、启动中 terminate、子 `close()`、父 context/runtime invalidate 释放子 runtime。

## 11. 完成后同步项

Worker 实现完成时必须同步：

- `modules/worker/README.md`
- `modules/worker/types/index.d.ts`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `tests/js/worker_js_test.js`
- `tests/worker/apple/ejs_worker_apple_test.m`

如果实现过程中需要引入 engine-neutral structured-clone capability，必须先补 core
设计说明和边界测试，再让 `modules/worker` 通过该 capability 使用，不能从 module
层直接依赖 QuickJS-ng API。
