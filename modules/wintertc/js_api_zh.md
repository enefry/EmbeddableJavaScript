# JS 接口使用文档

本文面向在 EJS 中编写 JavaScript 的调用方，描述当前 `WinterTC` 包安装后可用的
JS 接口。这里记录的是当前源码中的已实现能力，不等同于完整 Web 或 WinterTC 规范。

## 1. 安装前提

`WinterTC` 是可选包，不会随 `platform/apple` 自动安装。宿主应用必须显式链接
`ejs_wintertc_apple`，并对目标 `EJSContext` 调用安装函数：

```objc
#import "EJSWinterTCApple.h"

NSError *error = nil;
if (!EJSWinterTCInstallIntoContext(context, &error)) {
  // 处理安装失败
}
```

如果需要默认 Apple provider，例如 `fetch`、`crypto`、`performance` 和 `console`
背后的原生能力，需要启用 `installDefaultProviders`：

```objc
EJSWinterTCInstallOptions *options = [[EJSWinterTCInstallOptions alloc] init];
options.installDefaultProviders = YES;
BOOL ok = EJSWinterTCInstallIntoContextWithOptions(context, options, &error);
```

未安装 provider 时，相关 JS API 可能因为找不到 `wintertc.*` provider 而抛错或
返回 rejected Promise。

面向 IDE 的 TypeScript declaration 文件属于全仓库 JS-facing SDK 工作，统一记录在
`../docs/design.md` 的 JS-facing type declarations TODO 中。

## 2. 元信息

安装后会写入：

```js
WinterTC.loaded === true;
WinterTC.version === "1.0.0";
WinterTC.apis;
```

`WinterTC.apis` 当前包含 timers、url、events、encoding、blob、streams、fetch、
request、crypto、performance、console。

## 3. 定时器和微任务

可用全局函数：

```js
const id = setTimeout(() => {
  // ...
}, 100);
clearTimeout(id);

const interval = setInterval(() => {
  // ...
}, 1000);
clearInterval(interval);

queueMicrotask(() => {
  // ...
});
```

`setTimeout` 和 `setInterval` 要求 callback 是函数。delay 会转成数字；非法或负数
按 0 处理。`setInterval` 的重复间隔最小为 1ms。

## 4. URL 和 URLSearchParams

可用全局类：

```js
const url = new URL("/items?a=1", "https://example.test/base/");
url.searchParams.set("a", "2");
url.searchParams.append("tag", "ejs");

String(url); // "https://example.test/items?a=2&tag=ejs"
```

`URLSearchParams` 支持 string、二维数组、对象和另一个 `URLSearchParams` 作为初始值。
已实现 `append`、`delete`、`get`、`getAll`、`has`、`set`、`toString`、`forEach`、
`entries`、`keys`、`values` 和迭代器。

当前 URL 实现是轻量解析器，适合已覆盖场景；不要假定它已经完整覆盖浏览器 URL 标准
的所有边界行为。

## 5. 事件和 Abort

可用全局类和函数：

```js
const target = new EventTarget();
target.addEventListener("ready", (event) => {
  // ...
});
target.dispatchEvent(new Event("ready"));

const controller = new AbortController();
controller.abort(new Error("cancelled"));

addEventListener("error", (event) => {
  // event.message / event.error
});

reportError(new Error("boom"));
```

当前实现包括 `Event`、`CustomEvent`、`ErrorEvent`、`PromiseRejectionEvent`、
`EventTarget`、`AbortSignal`、`AbortController`、`addEventListener`、
`removeEventListener`、`dispatchEvent`、`reportError`，以及 `onerror`、
`onunhandledrejection`、`onrejectionhandled` 全局 handler。

如果 core 提供 `__ejs_native__.events`，WinterTC 会把 Promise rejection 和未捕获
异常转成对应事件。

## 6. 编码

可用全局类：

```js
const bytes = new TextEncoder().encode("hello");
const text = new TextDecoder("utf-8").decode(bytes);
```

当前只支持 UTF-8。`TextDecoder` 的 label 可以是 `"utf-8"` 或 `"utf8"`；其他编码会
抛出 `RangeError`。

## 7. Blob 和 File

可用全局类：

```js
const blob = new Blob(["hello"], { type: "text/plain" });
const text = await blob.text();
const bytes = await blob.arrayBuffer();
const stream = blob.stream();

const file = new File([blob], "hello.txt", { type: "text/plain" });
```

当前实现支持 `size`、`type`、`text()`、`arrayBuffer()`、`slice()`，以及 `File.name`。
`Blob.stream()` 返回一个最小 `ReadableStream`。`File` 还包含 `lastModified`。

## 8. ReadableStream

可用全局类：

```js
const stream = new ReadableStream({
  start(controller) {
    controller.enqueue(new Uint8Array([1, 2, 3]));
    controller.close();
  }
});

const reader = stream.getReader();
const first = await reader.read();
const done = await reader.read();
reader.releaseLock();

await stream.cancel("done");
```

当前实现是最小流模型，供 fetch body 等场景使用；不要把它当作完整 WHATWG Streams
实现。已实现 `locked`、`getReader()`、reader 的 `read()`/`releaseLock()`，
以及 stream 的 `cancel()`。

## 9. Fetch、Request、Response、Headers

可用全局对象：

```js
const headers = new Headers({ accept: "application/json" });
headers.set("x-client", "ejs");

const response = await fetch("data:text/plain,hello", { headers });
const text = await response.text();
```

`fetch` 会通过 `__ejs_native__.invoke("wintertc.fetch", ...)` 调用原生 provider。
默认 Apple provider 启用后支持：

- `data:` URL。
- `http:` URL。
- `https:` URL。

Request body 当前支持 string、ArrayBuffer、ArrayBufferView、Blob、URLSearchParams
和 ReadableStream。GET/HEAD 不能带 body。

`Headers` 当前支持 `append`、`delete`、`get`、`has`、`set`、`forEach`、`entries`、
`keys`、`values` 和迭代器。

`Request` 和 `Response` 当前支持 `arrayBuffer()`、`text()`、`json()`、`blob()`、
`clone()`。`Response` 还支持 `Response.json()`、`Response.redirect()` 和
`Response.error()`。

默认 Apple provider 会先缓冲响应体，再通过 pull-based body stream 暴露给 JS。
因此它适合当前测试和基础接入，不应被当作流式网络栈的最终形态。

## 10. Crypto

可用全局对象：

```js
const bytes = new Uint8Array(16);
crypto.getRandomValues(bytes);

const id = crypto.randomUUID();

const digest = await crypto.subtle.digest(
  "SHA-256",
  new TextEncoder().encode("hello")
);
```

`crypto.getRandomValues` 支持整数 TypedArray，最大 `byteLength` 是 65536。
`crypto.randomUUID()` 基于 `getRandomValues` 生成 UUID v4。

`crypto.subtle.digest` 当前支持 `SHA-256`、`SHA-384` 和 `SHA-512`，输入支持
ArrayBuffer 和 TypedArray。`encrypt` 和 `decrypt` 当前未实现。

## 11. Performance

可用全局对象：

```js
const origin = performance.timeOrigin;
const now = performance.now();
```

该 API 依赖 `wintertc.clock` 同步 provider。默认 Apple provider 使用系统单调时钟
返回 `timeOriginEpochMs` 和 `nowMs`。

## 12. Console

可用全局对象：

```js
console.debug("debug");
console.info("info");
console.log("log");
console.warn("warn");
console.error(new Error("failed"));
```

当前 `console` 会把参数转换成字符串数组，通过 `wintertc.console/write` 异步发给
原生 provider。默认 Apple provider 使用 `NSLog` 输出，并忽略写入失败。

## 13. 当前未实现或受限范围

当前源码没有实现完整浏览器环境。以下能力不要按已完成能力依赖：

- DOM、Document、Window 和渲染相关 API。
- 完整 WHATWG Streams。
- 完整 URL 规范边界行为。
- Fetch 的真正流式网络读写、缓存、cookie、CORS、redirect 策略完整语义。
- WebCrypto 的 encrypt/decrypt/key import/export 等能力。
- Compression、storage、permissions 等 provider family。

## 14. 与 EJSFS 的关系

文件系统 API 不属于 WinterTC。当前文件系统能力在 `modules/fs` 中，通过
`EJSFS.promises.readFile` 和 `EJSFS.promises.writeFile` 暴露，需要宿主另外安装
`EJSFileSystemInstallIntoContext(...)`。

## 15. 本地验证

```sh
node --check modules/wintertc/js/timers.js
node --check modules/wintertc/js/events.js
node --check modules/wintertc/js/url.js
node --check modules/wintertc/js/encoding.js
node --check modules/wintertc/js/blob.js
node --check modules/wintertc/js/streams.js
node --check modules/wintertc/js/fetch.js
node --check modules/wintertc/js/crypto.js
node --check modules/wintertc/js/performance.js
node --check modules/wintertc/js/console.js
node --check modules/wintertc/js/bootstrap.js

cmake --build build --target ejs_wintertc_apple_test
./build/tests/ejs_wintertc_apple_test
```
