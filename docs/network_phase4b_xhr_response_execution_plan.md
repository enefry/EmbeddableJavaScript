# Network Phase 4B XHR Response Execution Plan

更新时间：2026-05-29
状态：`completed`

源计划：

- `docs/network_implementation_plan.md` Phase 4：`modules/xhr`
- `docs/module_alignment_roadmap.md`：`modules/xhr` TODO `responseType` 非文本模式、完整 readyState/事件兼容与进度事件（Phase 4B）
- 接力状态：`docs/network_phase4b_xhr_response_types_execution_plan.md` 已记录 4B 代码与主要测试落地，但 `modules/xhr` README/types 仍停留在 Phase 4A 表述，且需要重新按本轮命令记录验证结果。

## Scope

Phase 4B 收口 `modules/xhr` 的非文本响应与事件兼容层：

- `responseType` 支持 `""`、`"text"`、`"arraybuffer"`、`"json"`。
- `"arraybuffer"` 模式下 `response` 返回 `ArrayBuffer`，`responseText` 保持空字符串。
- `"json"` 模式下 JS wrapper 解析 UTF-8 JSON 文本，invalid JSON 走 `error` + `loadend`，不从事件派发同步抛出。
- 补齐 `loadstart`、`progress`、`load`、`error`、`abort`、`timeout`、`loadend` 事件集合与 `on*` handler/types。
- `progress` 事件提供 bounded `loaded`、`total`、`lengthComputable` 字段。
- 保持 Phase 4A 的 `open/send/abort/headers`、policy、timeout、body/header limit 行为不回退。

明确不处理：

- 不重复或修改 Phase 5A `modules/ws` 实现。
- 不引入同步 XHR、XML/document response、upload progress target、streaming delegate progress、CORS/cookie 语义。
- 不修改 root `platform/*` 或其他网络模块，除非 4B 验证暴露必须修复的问题。

## Current State Check

- `docs/network_implementation_plan.md` 已把 Phase 4B 描述为已完成，并将 streaming/early abort 留给 Phase 4C。
- `docs/module_alignment_roadmap.md` 起始时将 Phase 4B 标为 `[~]`：代码与 fixture 用例已完成，但本地 socket gate 待非 sandbox 复核。
- `modules/xhr/js/xhr.js` 已含 `arraybuffer`、`json`、`loadstart`、`progress` 与 bounded progress payload。
- `tests/js/network_js_test.js` 已含 XHR response type、invalid JSON、progress/order 回归。
- `tests/xhr/apple/ejs_xhr_apple_test.m` 已含 `/binary`、`/json`、`/invalid-json` 本地 fixture 路径。
- 起始收口缺口：`modules/xhr/README.md` 和 `modules/xhr/types/index.d.ts` 仍描述 Phase 4A 的 responseType/event surface。

## Owned Write Scope

- `docs/network_phase4b_xhr_response_execution_plan.md`
- `modules/xhr/README.md`
- `modules/xhr/types/index.d.ts`
- 只在验证证明必要时修改：
  - `modules/xhr/js/xhr.js`
  - `tests/js/network_js_test.js`
  - `tests/xhr/apple/ejs_xhr_apple_test.m`
  - `tests/CMakeLists.txt`
  - `docs/network_implementation_plan.md`
  - `docs/module_alignment_roadmap.md`

禁止主动修改：

- `modules/ws/` 与 `docs/network_phase5a_ws_basic_execution_plan.md`
- `modules/net/`、`modules/stdlib/ipaddr/`
- root `platform/*`、`core/*`

## Implementation Lanes

1. Plan/baseline lane：保存本执行计划并运行最小 baseline，记录当前红绿状态。
2. XHR documentation/types lane：同步 README 和 `.d.ts` 到 Phase 4B 已实现的 API surface。
3. Regression lane：如 baseline 或 review 发现 4B 代码/测试缺口，只补 `modules/xhr` 与相关 XHR 测试。
4. Review closure lane：两个独立复核子代理只审查当前 4B 收口，不改代码。

## Regression Tests

JS wrapper：

- `responseType="arraybuffer"` 的 `response` 为 `ArrayBuffer`，`responseText` 为空。
- `responseType="json"` 解析成功响应。
- invalid JSON 派发 `error + loadend`。
- success 顺序包含 `loadstart -> progress -> load -> loadend`。
- `progress.loaded/total/lengthComputable` 稳定。

Apple/native：

- 本地 HTTP fixture 的 `/binary` 路径覆盖 arraybuffer。
- `/json` 和 `/invalid-json` 路径覆盖 JSON 成功/失败。
- policy/body-limit/timeout 既有回归保持通过。

## Verification Matrix

```sh
node --check modules/xhr/js/xhr.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m tests/CMakeLists.txt docs/network_phase4b_xhr_response_execution_plan.md docs/network_implementation_plan.md docs/module_alignment_roadmap.md
```

本地 HTTP fixture 可能因 sandbox 禁止 localhost bind 而需要 escalated rerun；若发生，记录 sandbox failure 与非 sandbox 结果。

## Evidence Log

- Baseline `node --check modules/xhr/js/xhr.js`: pass.
- Baseline `node --check tests/js/network_js_test.js`: pass.
- Baseline `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Baseline `cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check`: pass.
- Baseline `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (sandboxed): failed because `ejs_xhr_apple_test` local fixture could not bind localhost (`Operation not permitted`).
- Baseline `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (escalated): pass, 3/3 tests.
- Implementation subagent (`gpt-5.3-codex`) updated `modules/xhr/README.md` and `modules/xhr/types/index.d.ts` to Phase 4B surface; main integration fixed one stale README Phase 4A wording.
- Review subagent A (`gpt-5.3-codex`) finding fixed: `progress` was dispatched after `DONE`; moved progress dispatch to `LOADING` and added JS/Apple readyState assertions.
- Review subagent A/B (`gpt-5.3-codex`) finding fixed: `abort()` ended at `DONE`; changed abort terminal state to `UNSENT` and added JS/Apple active/opened abort assertions.
- Review subagent B (`gpt-5.3-codex`) finding fixed: invalid JSON skipped `HEADERS_RECEIVED/LOADING`; split response metadata/state transitions from body finalization and added JS/Apple readyState sequence assertions.
- Synchronized `docs/design.md`, `docs/network_implementation_plan.md`, `docs/module_alignment_roadmap.md`, and closed the earlier `docs/network_phase4b_xhr_response_types_execution_plan.md`.
- Final `node --check modules/xhr/js/xhr.js`: pass.
- Final `node --check tests/js/network_js_test.js`: pass.
- Final `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Final `cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check`: pass.
- Final `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (escalated): pass, 3/3 tests.
- `git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m tests/CMakeLists.txt docs/network_phase4b_xhr_response_execution_plan.md docs/network_phase4b_xhr_response_types_execution_plan.md docs/network_implementation_plan.md docs/module_alignment_roadmap.md docs/design.md`: pass.
