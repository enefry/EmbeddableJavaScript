# 平台接入文档

本文面向需要把 EJS 嵌入宿主应用的平台接入方。当前源码中已经实现的平台层是
`platform/apple`，它把 `core` 的 C ABI 包装成 Objective-C API，并通过 provider
机制把 JavaScript 的原生调用分发给宿主能力。

## 1. 模块边界

当前依赖方向是：

```text
Application
  -> optional packages: WinterTC, EJSFS, ...
  -> platform/apple
  -> core
  -> engine / loop backends
```

`platform/*` 是通用平台门面，只负责运行时、上下文、provider 注册、生命周期和
`moduleID/methodID` 分发。它不内置 WinterTC、EJSFS 或业务 API，也不会在创建
runtime/context 时自动安装这些包。

需要标准 Web 风格 API 时，应用显式链接并安装 `WinterTC`。需要文件系统 API 时，
应用显式链接并安装 `modules/fs`。这两个模块都依赖平台层，而不是被平台层反向依赖。

## 2. 当前 Apple 接入面

公共头文件集中在 `platform/apple/include/`：

- `EJSApplePlatform.h`：统一 umbrella header。
- `EJSRuntime.h`：创建 runtime、创建 context、中断和失效。
- `EJSRuntimeConfiguration.h`：runtime 名称、版本、内存/栈限制、context 默认配置。
- `EJSContext.h`：执行脚本/模块、注册 provider、读取配置、失效 context。
- `EJSContextConfiguration.h`：单个 context 的配置覆盖。
- `EJSProvider.h`：异步和可选同步 provider 协议。

对应 CMake target 是 `ejs_apple_platform`。

## 3. 最小接入流程

```objc
#import "EJSApplePlatform.h"

NSError *error = nil;

EJSRuntimeConfiguration *runtimeConfig = [[EJSRuntimeConfiguration alloc] init];
runtimeConfig.runtimeName = @"my_app";
runtimeConfig.runtimeVersion = @"1.0.0";
runtimeConfig.memoryLimitBytes = 16ull * 1024ull * 1024ull;
runtimeConfig.maxStackSize = 256u * 1024u;

EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:runtimeConfig];
EJSContext *context = [runtime createContextWithID:@"app://main" error:&error];
if (context == nil) {
  // 处理 error
}

BOOL ok = [context evaluateScript:@"globalThis.answer = 40 + 2;"
                         filename:@"main.js"
                            error:&error];
if (!ok) {
  // 处理 JS 异常或 runtime 错误
}

[context invalidate];
[runtime invalidate];
```

`contextID` 是平台层的稳定上下文标识。当前实现会阻止同一个 runtime 中重复创建
同 ID 的 in-flight context。

## 4. 配置传递

平台层提供字符串键值配置通道，具体 schema 由 add-on 自己定义。

```objc
EJSRuntimeConfiguration *runtimeConfig = [[EJSRuntimeConfiguration alloc] init];
runtimeConfig.contextDefaults = @{
  @"ejs.example": @"runtime default"
};

EJSContextConfiguration *contextConfig = [[EJSContextConfiguration alloc] init];
contextConfig.values = @{
  @"ejs.example": @"context override"
};

EJSContext *context = [runtime createContextWithID:@"app://main"
                                    configuration:contextConfig
                                            error:&error];
NSString *value = [context configurationValueForKey:@"ejs.example"];
```

合并规则是浅覆盖：`EJSRuntimeConfiguration.contextDefaults` 先作为默认值，
`EJSContextConfiguration.values` 再按 key 覆盖。创建后的 context 持有只读快照。

EJSFS 目前使用这个通道读取 `EJSFileSystemConfigurationKey`，但平台层只保存字符串，
不解析文件系统策略。

## 5. 注册异步 Provider

JavaScript 侧通过 `__ejs_native__.invoke(moduleID, methodID, payload, transferBuffer)`
进入平台层。平台层按 `moduleID` 找到 provider，再把调用转给 Objective-C 对象。

```objc
@interface ReportProvider : NSObject <EJSProvider>
@property (nonatomic, copy, readonly) NSString *moduleID;
@end

@implementation ReportProvider

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _moduleID = @"app.report";
  }
  return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                                responder:(EJSProviderResponder *)responder {
  if (![methodID isEqualToString:@"write"]) {
    [responder finishWithData:nil
                        error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported,
                                                   @"Unsupported method")];
    return [[EJSImmediateOperation alloc] init];
  }

  // payload 和 transferBuffer 都是调用期数据；异步使用时需要自行复制。
  NSData *result = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
  [responder finishWithData:result error:nil];
  return [[EJSImmediateOperation alloc] init];
}

@end
```

注册方式：

```objc
ReportProvider *provider = [[ReportProvider alloc] init];
if (![context registerProvider:provider error:&error]) {
  // 处理注册失败
}
```

对应 JS：

```js
const result = await __ejs_native__.invoke(
  "app.report",
  "write",
  JSON.stringify({ message: "hello" }),
  null
);
```

异步 provider 必须返回一个 operation。立即完成可以返回 `EJSImmediateOperation`；
需要取消逻辑时使用 `EJSBlockOperation`。返回 `nil` 会被平台层视为 provider 错误。

## 6. 注册同步 Provider

同步入口对应 `__ejs_native__.invokeSync`，只适合有明确上限、不会阻塞 owner thread
的能力，例如单调时钟、小块安全随机数或小型编码转换。

```objc
- (nullable NSData *)invokeSyncMethod:(NSString *)methodID
                              payload:(nullable NSData *)payload
                       transferBuffer:(nullable NSData *)transferBuffer
                              context:(EJSContext *)context
                                error:(NSError **)error {
  if (![methodID isEqualToString:@"now"]) {
    if (error != NULL) {
      *error = EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported method");
    }
    return nil;
  }

  return [@"{\"nowMs\":1.0}" dataUsingEncoding:NSUTF8StringEncoding];
}
```

不要在同步 provider 中做网络、文件 I/O、等待异步回调或任何无界阻塞工作。

## 7. 安装可选包

WinterTC 安装：

```objc
#import "EJSWinterTCApple.h"

EJSWinterTCInstallOptions *options = [[EJSWinterTCInstallOptions alloc] init];
options.installDefaultProviders = YES;
if (!EJSWinterTCInstallIntoContextWithOptions(context, options, &error)) {
  // 处理安装失败
}
```

EJSFS 安装：

```objc
#import "EJSFileSystemApple.h"

// 先通过 contextDefaults 或 context configuration 写入 EJSFileSystemConfigurationKey。
if (!EJSFileSystemInstallIntoContext(context, &error)) {
  // 处理安装失败
}
```

这些 add-on 都是显式安装。root `platform/apple` 不 import 它们的头文件，也不默认注册
它们的 provider。

## 8. 生命周期和错误处理

- `EJSRuntime` 持有一个 `EJSCoreRuntime`，`EJSContext` 持有一个 `EJSCoreContext`。
- `invalidate` 会使对象进入不可用状态，并清理 provider 和 core 资源。
- context 失效后，注册 provider、执行脚本和读取已失效 core context 都会失败。
- provider 错误建议使用 `EJSProviderMakeError`，错误会映射为 core 错误并传回 JS。
- 平台层会保留 provider 快照，已经发出的 pending invoke 不会因为后续 unregister
  立刻丢失 provider。
- provider 如果需要异步使用 `payload` 或 `transferBuffer`，必须在回调内复制数据。

## 9. 当前未实现范围

当前源码新增了 iOS 分发产物导出能力（XCFramework/CocoaPods/SwiftPM）：

- 使用 `tools/apple/package_apple_distribution.sh` 生成 `dist/apple` 下的：
  - `${PRODUCT_NAME}.xcframework`（或自定义的 `EJS_APPLE_PRODUCT_NAME`）
  - `${PRODUCT_NAME}.podspec`
  - `Package.swift`

当前源码还未实现：

- Android Kotlin/JNI facade 和 AAR packaging。
- Swift overlay。
- 平台层默认 provider 集合。
- runtime 级默认 provider 注册表。

这些能力不应在接入文档中按已实现能力依赖。

## 10. 本地验证

Apple 平台层：

```sh
cmake --build build --target ejs_apple_platform_test
./build/tests/ejs_apple_platform_test
```

平台边界检查：

```sh
cmake --build build --target ejs_platform_boundary_check
```

可选包验证需要分别运行：

```sh
cmake --build build --target ejs_wintertc_apple_test ejs_fs_apple_test ejs_apple_sample
./build/tests/ejs_wintertc_apple_test
./build/tests/ejs_fs_apple_test
./build/sample/ejs_apple_sample
```
