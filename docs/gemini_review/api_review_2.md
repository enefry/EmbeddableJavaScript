# EJS 核心模块 api.d.ts 与 index.d.ts 对校与合并可行性评估报告

本报告对项目中的 13 个核心模块的根目录 `api.d.ts` 与其子目录 `types/index.d.ts` 进行了语义级与字符级的全量校对，旨在厘清两者是否存在重复，并评估逻辑合并的可行性与具体演进路线。

---

## 1. 每个模块是否都有 `index.d.ts` 校验结果

| 模块名称 | 根目录下 `api.d.ts` | `types/index.d.ts` 存在状态 | 语义/内容是否一致？ | 差异危害度 |
| :--- | :---: | :--- | :---: | :---: |
| **buffer** | **有** | 有 (`buffer/types/index.d.ts`) | **基本一致**（仅注释有细微字词差异） | Low |
| **fs** | **有** | 有 (`fs/types/index.d.ts`) | **基本一致**（注释存在简化） | Low |
| **fswatch** | **有** | 有 (`fswatch/types/index.d.ts`) | **基本一致** | Low |
| **kv** | **有** | 有 (`kv/types/index.d.ts`) | **基本一致** | Low |
| **net** | **有** | 有 (`net/types/index.d.ts`) | **基本一致** | Low |
| **path** | **有** | 有 (`path/types/index.d.ts`) | **基本一致** | Low |
| **sqlite** | **有** | 有 (`sqlite/types/index.d.ts`) | **不一致**（部分类型缩写与注释不同） | Low |
| **stdlib** | **有** | **无**（根目录无，拆分在 3 个子模块的 `types/` 目录下） | **完全分叉** | **High** |
| **system** | **有** | 有 (`system/types/index.d.ts`) | **不一致**（`index.d.ts` 删除了大量 JSDoc 属性注释） | Medium |
| **wintertc** | **有** | **完全无 index.d.ts 文件** | **完全缺失** | **Critical** |
| **worker** | **有** | 有 (`worker/types/index.d.ts`) | **严重不一致**（`index.d.ts` 发生了致命声明阉割） | **Critical** |
| **ws** | **有** | 有 (`ws/types/index.d.ts`) | **不一致**（`index.d.ts` 删除了大段诊断与错误注释） | Medium |
| **xhr** | **有** | 有 (`xhr/types/index.d.ts`) | **不一致**（`index.d.ts` 严重简化了事件与生命周期注释） | Medium |

---

## 2. `api.d.ts` 与 `index.d.ts` 的核心差异深度剖析

通过对两套声明文件做逐行的 `diff -w`（忽略空白）对比，我们发现了以下几个极其致命的差异类型：

### 2.1 `worker` 模块：`index.d.ts` 存在致命的全局 API 阉割 (Critical)
在 `worker` 模块根目录的 `api.d.ts` 中，对 Web Worker 线程内部全局作用域的代码提示做好了极其完美的定义（例如 `self` 全局变量，`onmessage`, `onerror`, `postMessage`, `close` 等方法）：
```typescript
  /** Child/global worker message handler. */
  var onmessage: EJSWorkerEventHandler | null;
  /** Child/global worker error handler. */
  var onerror: EJSWorkerEventHandler | null;
  /** Send a message from child/global scope to parent scope. */
  function postMessage(value: unknown, ...): void;
```
但在 `worker/types/index.d.ts` 中，**以上所有子线程全局变量和关键通信方法的定义被全部粗暴地删减掉了**！
*   **后果**：如果业务开发人员在使用 TypeScript 编写 Worker 线程内部脚本时，直接引入 `index.d.ts`，会导致 `postMessage` 或 `onmessage` 发生编译期红线报警（找不到名称），迫使开发者不得不写 `(self as any).postMessage` 等类型断言。

### 2.2 `wintertc` 模块：完全缺失 `index.d.ts` (Critical)
*   作为极其重要的 Web 核心标准，整个 `wintertc` 模块（涉及 `Fetch`、`Stream`、`URL` 等标准 API）下**完全没有定义任何 `index.d.ts`**，只有根目录下的 `api.d.ts`。
*   **后果**：外部 TypeScript 工程无法以标准包结构导入 `wintertc` 类型，完全打破了应用层对 Web 标准 API 的类型约束。

### 2.3 大量核心模块：`index.d.ts` 存在严重的“JSDoc 注释大缩水” (Medium)
在许多模块（如 `system`, `ws`, `xhr`, `sqlite` 等）中，根目录下的 `api.d.ts` 具有极具技术含量、条理清晰的属性与字段描述：
```typescript
  /** CPU metadata returned by `EJSSystem.cpuInfo()`. */
  /** Network interface entry returned by `EJSSystem.networkInterfaces()`. */
```
而在对应的 `types/index.d.ts` 中，这些极富价值的 JSDoc 描述被大范围裁剪，变成了机械化模板生成的空洞行（如：`* Type interface used by the system API.`）。
*   **后果**：开发者在 VSCode 中悬停鼠标时，原本能看到清晰的“该网络接口是干什么的”详细业务解释，更新后却只能看到空洞的“这是一个系统API”，大大降低了开发和代码维护效率。

### 2.4 `stdlib` 模块：包结构完全错乱 (High)
*   `stdlib` 是一个聚合模块。它的 `api.d.ts` 将其作为统一的全局接口导出。
*   但在 `types/` 层面，它被强行拆解成了 `stdlib/ipaddr/types/index.d.ts`、`stdlib/hashing/types/index.d.ts` 和 `stdlib/uuid/types/index.d.ts` 三个互不相干的独立文件，且缺少在 stdlib 根级 index 下的聚合重导出，造成包层级的类型导入极其不一致。

---

## 3. 架构演进与合并重构方案

这两套文件的分叉是典型的“多头维护”负面产物，强烈建议我们进行以下**两步走**的架构重构：

1.  **“取长补短”进行合并**：
    *   以 `api.d.ts` 中**极其详尽的 JSDoc 注释**和**最完整的全局 API 声明**（如 `worker` 的全局方法）为基准，将其完全覆盖合并写入到各模块的 `types/index.d.ts` 中，使 `types/index.d.ts` 升级为**终极版应用层类型文件**。
    *   为没有 `index.d.ts` 的 `wintertc` 补齐它。
2.  **根治未来隐患（逻辑链接）**：
    *   将核心模块根目录下的 `api.d.ts` 的内容彻底清空，改为只包含一行三斜线引用指令：
        ```typescript
        /// <reference path="./types/index.d.ts" />
        ```
    *   这样，底座构建 CMake 无论如何扫描，均能自动获取最完整的类型；同时应用层在 IDE 中也只有唯一的、且体验最完美的类型定义真源！
