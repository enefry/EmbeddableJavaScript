# EJS npm Package Conversion Plan

更新时间：2026-05-30
状态：Phase 1 离线转换器 MVP + Phase 2 core source-table loader MVP + Phase 3 Apple package installer MVP 已实施；CLI module mode 待实施
范围：阶段5 `import/loader` 与 npm 纯 JavaScript 包接入

本文规划 EJS 如何支持 npm 生态中的纯 JavaScript 包。核心原则是：

- npm 生态理解、依赖解析、转换和审核发生在离线工具链。
- EJS runtime 不执行 `npm install`，不运行 npm lifecycle scripts，不在 `import`
  过程中联网。
- runtime 只加载经过转换、校验、审核或签名的 `.ejspkg`。
- `core` 只承载通用 ES module loader 机制，不承载 npm、Node.js、
  package manager 或网络/文件策略。
- 下载能力可以存在，但必须只下载已审核版本，并在加载前完成完整校验。

## 1. 背景与目标

当前 EJS 已有多种可选 add-on，包括纯 JS 包、provider-backed 包和网络包。
阶段5 roadmap 中仍待明确：

- 嵌入式模块安装/加载边界。
- `ejs_eval_module` 与 loader 对接。
- 相对路径归一化、模块缓存、循环依赖。
- `import.meta.url` 与 `import()`。
- 未解析模块或语法错误的诊断。

npm 包支持应落在这个阶段内，但不能把 EJS 变成 Node runtime 或 npm runtime。

目标：

1. 提供离线转换器，把 npm 包转换为 EJS 可加载包格式。
2. 定义稳定 `.ejspkg` manifest、模块图、hash、capability 和审核报告。
3. 为 runtime 增加通用、受控、可审计的 module loader。
4. 允许宿主在审核后下载已批准 `.ejspkg` 或已批准 npm tarball。
5. 保持 Apple/App Store 生产路径可解释：下载的是已批准代码包，加载前有签名或
   allowlist 校验。

非目标：

- 不实现通用 `npm install`。
- 不运行 `preinstall`、`install`、`postinstall`、`prepare` 等 lifecycle scripts。
- 不支持 native addon、`node-gyp`、`.node` binary、FFI 自动绑定。
- 不承诺完整 Node.js `require`、`node_modules`、builtin 模块或条件导出兼容。
- 不在 QuickJS loader 回调里进行文件 I/O、网络 I/O 或异步 provider 调用。
- 不自动把 EJSFS、EJSNet、WinterTC 等能力暴露给第三方包。

## 2. 术语

| 名称 | 含义 |
| --- | --- |
| npm package | npm registry 中发布的原始包，通常是 tarball。 |
| conversion input | lockfile、tarball、本地 package 目录或已下载依赖缓存。 |
| converter | 离线命令行工具，建议命名为 `ejs-pkg-convert`。 |
| `.ejspkg` | EJS 包格式，包含 manifest、模块源码、资源、license 和转换报告。 |
| audit report | 转换器输出的安全、兼容性、license、capability 报告。 |
| approval manifest | 宿主维护的审核通过清单，可按 manifest hash 或签名授权加载。 |
| package store | 宿主控制的本地 `.ejspkg` 缓存目录。 |
| loader | EJS runtime 中的通用 ES module source resolver/loader。 |

## 3. 总体架构

```text
npm registry / local package / lockfile
  -> ejs-pkg-convert
  -> .ejspkg + audit report
  -> human or CI audit
  -> signature / approval manifest
  -> optional download cache
  -> EJS generic module loader
  -> ejs_eval_module(...)
```

职责边界：

| 层 | 职责 | 不负责 |
| --- | --- | --- |
| converter | 解析 npm 包、构建依赖图、转换 CJS/ESM、生成 `.ejspkg`。 | 运行未审核代码、决定宿主权限。 |
| audit/approval | 评审产物、记录 hash、签名、capability、license。 | 修改 runtime loader 语义。 |
| downloader | 只下载已批准包并校验完整性。 | 解析任意 npm 依赖、隐式安装新版本。 |
| loader | 从已安装 `.ejspkg` 的内存模块表加载源码。 | 网络下载、文件扫描、npm 解析、权限提升。 |
| optional modules | 提供 EJSFS/EJSNet/etc. 能力。 | 自动授予第三方 npm 包权限。 |

## 4. `.ejspkg` 包格式

首版建议同时支持两种形态：

- unpacked directory：便于开发、测试、审核。
- archive file：便于分发，扩展名 `.ejspkg`。archive 必须确定性生成。

目录结构：

```text
foo-1.2.3.ejspkg/
  ejs-package.json
  modules/
    index.js
    deps/bar.js
  assets/
  licenses/
    foo-LICENSE.txt
  report.json
```

### 4.1 `ejs-package.json`

示例：

```json
{
  "format": 1,
  "name": "foo",
  "version": "1.2.3",
  "packageId": "npm:foo@1.2.3",
  "entry": "ejs-pkg://npm/foo@1.2.3/modules/index.js",
  "source": {
    "type": "npm",
    "registry": "https://registry.npmjs.org/",
    "tarball": "https://registry.npmjs.org/foo/-/foo-1.2.3.tgz",
    "integrity": "sha512-...",
    "resolvedBy": "package-lock.json"
  },
  "converter": {
    "name": "ejs-pkg-convert",
    "version": "0.1.0",
    "optionsHash": "sha256-..."
  },
  "conditions": ["ejs", "import", "default"],
  "modules": {
    "ejs-pkg://npm/foo@1.2.3/modules/index.js": {
      "path": "modules/index.js",
      "sha256": "...",
      "format": "esm",
      "sourceMap": null
    },
    "ejs-pkg://npm/foo@1.2.3/modules/deps/bar.js": {
      "path": "modules/deps/bar.js",
      "sha256": "...",
      "format": "esm",
      "sourceMap": null
    }
  },
  "imports": {
    ".": "ejs-pkg://npm/foo@1.2.3/modules/index.js"
  },
  "dependencies": {
    "bar": {
      "packageId": "npm:bar@2.0.0",
      "manifestSha256": "..."
    }
  },
  "capabilities": {
    "filesystem": "none",
    "network": "none",
    "process": "none",
    "native": "none",
    "dynamicCode": "none"
  },
  "policy": {
    "requiresApproval": true,
    "allowDynamicImport": false,
    "allowEval": false
  },
  "packageSha256": "...",
  "signature": null
}
```

### 4.2 `report.json`

`report.json` 是审核入口，必须面向人和 CI 都可读。

建议字段：

```json
{
  "summary": {
    "status": "converted",
    "warnings": 0,
    "unsupportedFeatures": 0
  },
  "sourcePackage": {
    "name": "foo",
    "version": "1.2.3",
    "license": "MIT",
    "integrityVerified": true
  },
  "security": {
    "lifecycleScripts": [],
    "nativeFiles": [],
    "dynamicRequire": [],
    "evalLikeUsage": [],
    "networkLiteralUsage": [],
    "filesystemLiteralUsage": []
  },
  "compatibility": {
    "moduleFormat": "esm",
    "commonJSWrappedModules": [],
    "externalizedImports": [],
    "unsupportedNodeBuiltins": []
  },
  "licenses": [
    {
      "package": "foo@1.2.3",
      "license": "MIT",
      "file": "licenses/foo-LICENSE.txt"
    }
  ]
}
```

## 5. 转换器设计

工具建议命名：

```sh
ejs-pkg-convert --lock package-lock.json --package foo \
  --out dist/foo-1.2.3.ejspkg \
  --conditions ejs,import,default \
  --deny-lifecycle-scripts \
  --deny-native \
  --deny-dynamic-require
```

支持输入：

| 输入 | 首版支持 | 说明 |
| --- | --- | --- |
| `package-lock.json` | 必须 | 固定版本、tarball URL、integrity。 |
| npm tarball | 必须 | 已下载并可离线验证。 |
| 本地 package 目录 | 必须 | 便于开发和 fixture 测试。 |
| npm registry 在线解析 | 可选 | 只能用于转换器环境，不进入 runtime。 |
| workspace/monorepo | 后续 | 需要额外 package boundary 规则。 |

### 5.1 转换流水线

1. 读取输入。
   - 要求 exact version。
   - lockfile 中必须有 integrity。
   - 未锁定依赖默认失败。

2. 下载或读取 tarball。
   - 离线模式只读本地 tarball/cache。
   - 在线模式仅在开发/CI 工具中允许。
   - 校验 npm integrity 和 sha256。

3. 安全预检。
   - 拒绝 lifecycle scripts，除非显式 `--allow-scripts-for-audit-only` 且不执行。
   - 拒绝 `.node`、`binding.gyp`、`node-pre-gyp`、`prebuilds/` 等 native 迹象。
   - 拒绝 archive path traversal、absolute path、symlink escape。
   - 限制包大小、文件数量、单文件大小、源码总大小。

4. 解析 package entry。
   - 优先 `exports`。
   - 支持 `import`、`default`、自定义 `ejs` condition。
   - `browser` condition 可配置，默认关闭。
   - `node` condition 默认关闭。
   - `main` 作为 legacy fallback。

5. 构建模块图。
   - 支持 ESM 静态 `import/export`。
   - 支持有限 CommonJS：静态 `require("literal")`。
   - 拒绝非 literal dynamic require，或标记为 externalized import。
   - 解析相对路径、package exports、dependency package。
   - 记录循环依赖。

6. 转换输出。
   - 输出标准 ESM module sources。
   - CommonJS 用 wrapper 转为 ESM default/named export 近似语义。
   - 保留 sourcemap 或至少保留 `sourceURL` 映射。
   - 删除 shebang，保留 license banner。
   - 输出确定性排序和稳定 hash。

7. capability 分析。
   - 检测 `fs`、`net`、`http`、`https`、`child_process`、`worker_threads`、
     `process`、`Buffer`、`crypto`、`eval`、`Function`、dynamic import。
   - 未映射 Node builtin 默认失败。
   - 若配置了 shim，必须写入 `capabilities` 和 `compatibility` 报告。

8. 生成 `.ejspkg`。
   - 写 `ejs-package.json`。
   - 写转换后的 `modules/`。
   - 写 `report.json` 和 license 文件。
   - 计算 `packageSha256`。
   - 可选签名。

9. 自检。
   - 重新读取 `.ejspkg`。
   - 校验所有 module hash。
   - 用 EJS loader fixture 或 Node VM harness 做 smoke test。
   - 确保同一输入重复转换产物 hash 一致。

### 5.2 CommonJS 支持边界

首版只支持静态 CommonJS：

```js
const dep = require("dep");
module.exports = function value() {};
exports.name = "value";
```

拒绝或标记为 unsupported：

```js
require(name);
require("./" + name);
module.exports = require(process.env.TARGET);
```

转换策略：

- 每个 CJS 文件包成函数作用域，提供 `exports`、`module`、`require`。
- `require` 只能访问转换器已解析的 module id。
- CJS module 缓存由转换后 runtime shim 管理，不走 EJS native provider。
- 对 named export 的支持以静态分析为准；无法确定时只提供 default export。

### 5.3 Node builtin 与 EJS shim

首版默认所有 Node builtin 都不支持。原因是 EJS 当前模块并不等价于 Node API；
如果命名 Node-like 但行为漂移，会制造更难排查的兼容性问题。

后续可以按 shim allowlist 开启：

| Node import | 可能映射 | 默认 |
| --- | --- | --- |
| `assert` / `node:assert` | 未来 `modules/stdlib/assert` | reject |
| `path` / `node:path` | 仅在明确 POSIX 子集时映射 `EJSPath` | reject |
| `buffer` / `node:buffer` | 未来 Node-compatible Buffer shim | reject |
| `crypto` / `node:crypto` | 未来受限 shim 或 WinterTC crypto | reject |
| `fs` / `node:fs` | 不自动映射 EJSFS | reject |
| `http` / `https` / `net` | 不自动映射网络 add-on | reject |
| `process` | 未来受限 `modules/process` | reject |

任何 shim 开启都必须写入 `.ejspkg` manifest 的 `capabilities`，并由宿主审核。

## 6. 审核与签名

审核对象是 `.ejspkg`，不是 npm 原包。

审核清单：

- npm source integrity 已验证。
- `.ejspkg` 所有模块 hash 已验证。
- 无 lifecycle scripts 执行需求。
- 无 native addon。
- 无未授权 Node builtin。
- 无未授权 dynamic require/import。
- 无 `eval`/`Function`，或已明确记录并拒绝加载。
- license 可接受。
- capabilities 与宿主策略匹配。
- 转换器版本可信，转换结果确定性可复现。

批准记录建议是一个宿主侧文件：

```json
{
  "format": 1,
  "approvedPackages": [
    {
      "packageId": "npm:foo@1.2.3",
      "manifestSha256": "...",
      "packageSha256": "...",
      "signature": "base64...",
      "approvedAt": "2026-05-30T00:00:00Z",
      "approvedBy": "ci-or-human-review"
    }
  ]
}
```

runtime 加载时必须至少满足一种授权：

- `.ejspkg` 自带签名通过宿主信任根校验。
- `manifestSha256` 或 `packageSha256` 命中宿主 approval manifest。

未授权包的错误必须包含：

- package id。
- manifest hash。
- 失败原因。
- 不包含源码内容或敏感路径。

## 7. 下载策略

下载是可选能力，必须在审核之后发生。

推荐两种模式：

### 7.1 下载已转换 `.ejspkg`

```text
approved manifest
  -> download .ejspkg by URL
  -> verify packageSha256/signature
  -> install to package store
  -> loader reads approved package
```

优点：

- runtime 不需要 npm 解析。
- 不需要在终端设备上运行转换器。
- 审核对象与运行对象一致。

### 7.2 下载已审核 npm tarball 后本地转换

```text
approved npm tarball integrity
  -> download tarball
  -> verify integrity
  -> run deterministic converter in host-managed environment
  -> compare output hash with approval record
  -> install .ejspkg
```

这个模式更重，适合 CI、桌面或开发工具，不建议作为移动端首版。

### 7.3 不允许的下载行为

- `import "foo"` 时自动访问 npm registry。
- 下载未锁版本，例如 `^1.2.0`、`latest`。
- 下载后直接执行 tarball 内源码。
- 下载后运行 npm scripts。
- 下载后因包声明申请更大 EJS capability。

## 8. Runtime Loader 设计

### 8.1 MVP loader 形态

首版 loader 只从内存 source table 读源码：

```text
EJSPackageInstallIntoContext(context, package)
  -> verify manifest/hash/approval
  -> register normalized specifier -> source
  -> context.evaluateModule(entrySource, entrySpecifier, sourceURL)
  -> QuickJS module loader resolves static imports from source table
```

关键点：

- loader callback 必须是同步、bounded、no I/O。
- 包读取、hash 校验、approval 校验发生在安装阶段，不发生在 QuickJS loader 回调。
- source table 按 context 隔离。
- 同一个 runtime 的不同 context 不共享可变 package state。
- source URL 使用 `ejs-pkg://...`，便于 stack trace 和 `import.meta.url`。

### 8.2 Core ABI 扩展候选

候选 API：

```c
typedef struct {
    const char *specifier;
    const char *source_url;
    const char *source;
    size_t source_len;
} EJSCoreModuleSource;

EJSCoreResult ejs_context_register_module_sources(
    EJSCoreContext *context,
    const EJSCoreModuleSource *sources,
    size_t source_count
);
```

或者更通用：

```c
typedef struct {
    int (*normalize)(void *user_data,
                     const char *base_url,
                     const char *specifier,
                     char **normalized_out);
    int (*load)(void *user_data,
                const char *normalized,
                EJSCoreByteBuffer *source_out,
                char **source_url_out);
    void (*release)(void *user_data);
    void *user_data;
} EJSCoreModuleLoaderAPI;
```

MVP 推荐先做 source table API，原因：

- 更容易保证 loader callback 不做 I/O。
- 更容易做 hash 校验和 context 隔离。
- 不需要在 core ABI 暴露复杂 host callback 生命周期。
- 已足够支持 `.ejspkg` 静态模块图。

后续如果需要大型 package store 或 streaming source，再评估 loader callback API。

### 8.3 Apple facade

Apple 层提供通用安装入口，不包含 npm 语义：

```objc
BOOL EJSPackageInstallIntoContext(EJSContext *context,
                                  NSURL *packageURL,
                                  EJSPackageInstallOptions *options,
                                  NSError **error);
```

`EJSPackageInstallOptions` 建议包含：

- approval manifest URL 或 approval verifier block。
- expected package hash。
- allowed capabilities。
- install namespace。
- 是否允许 dynamic import。

Apple provider 不应在 root `platform/apple` 自动安装该能力。建议放在
`modules/package` 或 `modules/loader` 这类 optional add-on 中。

### 8.4 CLI 支持

当前 CLI 用户脚本是 wrapped script，不适合作为静态 import 入口。阶段5 需要新增
module mode：

```sh
ejs_apple_cli --package dist/foo-1.2.3.ejspkg --module npm:foo
ejs_apple_cli --package dist/foo-1.2.3.ejspkg --module ejs-pkg://npm/foo@1.2.3/modules/index.js
```

要求：

- `--module` 下不包 async function wrapper。
- 支持 top-level await。
- 错误输出包含 package id、entry specifier、unresolved specifier。
- `process.argv` 保持可用，但不自动授予 npm 包 process capability。

## 9. 安全模型

### 9.1 Supply Chain

风险：

- 依赖被替换。
- registry 返回不同 tarball。
- lockfile 被污染。
- 转换器版本变化导致产物变化。

控制：

- 必须校验 npm integrity。
- `.ejspkg` manifest 必须记录 converter version 和 options hash。
- 产物必须 deterministic，CI 可复现 hash。
- 审核以 `.ejspkg` hash 为准。

### 9.2 Archive Extraction

风险：

- path traversal。
- absolute path。
- symlink escape。
- 过大文件或过多文件导致资源耗尽。

控制：

- 解包时拒绝 `..`、absolute path、drive prefix、NUL byte。
- symlink 默认拒绝。
- 限制文件数、总大小、单文件大小。
- 只允许 UTF-8 JS source 和明确允许的 asset 类型。

### 9.3 Runtime Capability

风险：

- 第三方包访问文件、网络、进程、worker。
- shim 隐式扩大权限。

控制：

- `.ejspkg` 默认 `filesystem/network/process/native = none`。
- shim 必须显式配置并由 approval manifest 授权。
- runtime loader 只负责源码加载，不注册 provider。
- EJSFS/EJSNet 等 add-on 的策略仍由宿主 context configuration 控制。

### 9.4 Dynamic Code

风险：

- `eval`、`Function`、dynamic import、dynamic require 绕过静态审核。

控制：

- converter 默认拒绝 dynamic require。
- `eval`/`Function` 默认标为 unsupported。
- dynamic import 首版默认关闭。
- 后续若支持 dynamic import，只允许导入同 `.ejspkg` manifest 中声明的模块。

## 10. 实施阶段

### Phase 0: Format and Fixtures

产出：

- `docs/npm_ejspkg_conversion_plan.md`。
- `.ejspkg` manifest JSON schema 草案。
- fixture npm packages：
  - simple ESM。
  - simple CJS。
  - package `exports`。
  - dependency package。
  - circular dependency。
  - denied lifecycle script。
  - denied native addon。
  - denied dynamic require。
  - denied Node builtin。

验收：

- schema examples 能被 JSON parser 验证。
- fixture 预期通过/失败原因明确。

### Phase 1: Offline Converter MVP

产出：

- `[x]` `tools/ejs-pkg-convert/`。
- `[x]` 支持本地 package directory 和 tarball。
- `[x]` 支持 lockfile integrity 校验。
- `[x]` 输出 unpacked `.ejspkg` directory。
- `[x]` 输出 `report.json`。

当前实现说明：

- CLI 入口：`tools/ejs-pkg-convert/bin/ejs-pkg-convert.js`。
- 默认拒绝 lifecycle scripts、native addon 迹象、dynamic require、
  dynamic import、`eval`/`Function` 和 Node builtin。
- CommonJS 首版只支持静态 literal `require(...)`，并包装为 ESM default
  export + 静态识别的 named exports。
- fixture 和回归测试位于 `tests/fixtures/npm/` 与
  `tests/ejspkg/converter_test.js`。
- 该阶段只实现离线转换器，不改变 `core` loader、Apple package installer
  或 `ejs_apple_cli` module mode。

验收：

```sh
node tools/ejs-pkg-convert/bin/ejs-pkg-convert.js \
  --input tests/fixtures/npm/simple-esm \
  --out /tmp/ejs-simple-esm.ejspkg \
  --force

node tests/ejspkg/converter_test.js
```

测试覆盖：

- deterministic output。
- hash mismatch fails。
- lifecycle script fails。
- native addon fails。
- dynamic require fails。
- package exports resolution。

### Phase 2: Generic Module Loader MVP

产出：

- `[x]` core source table module loader。
- `[x]` QuickJS-ng `JS_SetModuleLoaderFunc` 对接。
- `[x]` `ejs_context_register_module_sources`。
- `[x]` core tests covering import graph。

当前实现说明：

- Public ABI 新增 `EJSCoreModuleSource` 与
  `ejs_context_register_module_sources(...)`。
- 注册接口深拷贝已审核源码表，表按 context 隔离；重复 specifier 替换旧源码。
- QuickJS loader callback 只从内存表同步读取源码，不触发文件、网络或 provider I/O。
- `ejs_eval_module` 改为 compile-only + `JS_EvalFunction` 路径，设置
  `import.meta.url` / `import.meta.main` 后再执行。
- 回归覆盖位于 `tests/core/ejs_core_test.c::test_eval_module`。

验收：

- `[x]` static import works。
- `[x]` relative import normalize works。
- `[x]` module cache works。
- `[x]` circular dependency works。
- `[x]` unresolved specifier error includes base and requested specifier。
- `[x]` syntax error stack includes `ejs-pkg://` source URL。
- `[x]` loader callback path does not invoke provider, fs, or network。

### Phase 3: Apple Package Installer

状态：已完成。Apple optional add-on `modules/package` 提供
`EJSPackageInstallIntoContext(...)`，安装 unpacked `.ejspkg` 前完成 approval、
package hash、模块 hash、capability 和路径边界校验，并注册 source table 到
`EJSContext`。

产出：

- `[x]` optional add-on target `modules/package`.
- `[x]` `EJSPackageInstallIntoContext(...)`。
- `[x]` approval manifest verifier。
- `[x]` package hash verification。
- `[x]` package source table registration into context。
- `[x]` Apple tests.

验收：

```sh
cmake --build build --target ejs_package_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_package_apple_test|ejs_platform_boundary_test" --output-on-failure
```

测试覆盖：

- valid package installs and imports。
- missing approval rejected。
- hash mismatch rejected。
- unsupported capability rejected。
- malformed manifest rejected。
- path traversal package rejected。

### Phase 4: CLI Module Mode

产出：

- `ejs_apple_cli --package ... --module ...`。
- top-level await module execution。
- package install before module eval。
- diagnostic output.

验收：

```sh
cmake --build build --target ejs_apple_cli_test
./build/tools/apple/ejs_apple_cli --package /tmp/ejs-simple-esm.ejspkg --module npm:simple-esm
```

测试覆盖：

- module mode does not wrap script。
- unresolved import reports package id。
- existing script mode unaffected。

### Phase 5: Audited Download Add-On

产出：

- optional downloader, tentatively `modules/package_fetch` or host tool only。
- allowlist-only download。
- signature/hash verification。
- package store install.

验收：

- unapproved URL rejected。
- approved package downloaded and hash verified。
- corrupted package rejected。
- download never triggers module evaluation。
- loader only sees installed and approved package.

## 11. Open Decisions

| 决策 | 推荐默认 | 备注 |
| --- | --- | --- |
| 包格式 archive 类型 | directory first, archive later | 先降低实现风险。 |
| converter 实现语言 | Node.js CLI | npm/package exports 解析生态更成熟，runtime 不受影响。 |
| bundler/parser | esbuild/Rollup parser plus custom validation | 不手写 JS parser。 |
| loader ABI | source table first | 避免 sync callback 生命周期复杂度。 |
| CJS support | limited static CJS | 覆盖常见包，但拒绝动态 require。 |
| Node builtin | default reject | 避免 Node-like 行为漂移。 |
| dynamic import | default reject | 后续仅允许 manifest 内模块。 |
| runtime download | download `.ejspkg` only | 移动端首版更稳。 |

## 12. Documentation Updates When Implemented

每个阶段完成时需要同步：

- `docs/design.md`：记录 loader、package add-on、边界。
- `docs/module_alignment_roadmap.md`：更新阶段5 TODO 状态和验证命令。
- 新模块 README：如果落地 `modules/package` 或 downloader。
- `platform/integration_zh.md`：Apple 集成示例。
- CLI README：新增 `--module` / `--package` 使用说明。

## 13. Final DoD

阶段5 npm-to-ejspkg 能力完成时必须满足：

- 能把至少 3 类 npm fixture 转换为 `.ejspkg` 并离线加载：
  - pure ESM。
  - static CJS。
  - package exports + dependency。
- 转换器拒绝 lifecycle/native/dynamic require/unsupported builtin。
- `.ejspkg` manifest 和 report 可复现、可审核。
- EJS loader 支持静态 import、relative import、缓存、循环依赖和诊断。
- Apple optional installer 能验证 hash/approval 并注册包。
- CLI module mode 可运行 `.ejspkg` entry。
- 下载路径只允许已审核包，且加载前完成 hash/signature 校验。
- `core` 不包含 npm 语义，root `platform/*` 不包含 package 私有策略。
