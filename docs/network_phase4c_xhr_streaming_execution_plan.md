# Network Phase 4C XHR Streaming Execution Plan

更新时间：2026-05-29
状态：`completed`

源计划：

- `docs/network_implementation_plan.md` Phase 4C：`streaming/early body-limit abort、更细粒度 timeout 语义和诊断细节`
- `docs/module_alignment_roadmap.md` 阶段3网络模块：`modules/xhr` Phase 4B 已完成，阶段3仍需网络错误可诊断与收口验证
- 接力状态：Phase 4B 已在 `docs/network_phase4b_xhr_response_execution_plan.md` 收口；本切片不重复 WS 5A

## Scope

Phase 4C 只完善 `modules/xhr` 的 Apple provider 响应接收路径与诊断：

- 将 Apple XHR 从 `NSURLSessionDataTask` completion-handler response buffering 切到 module-owned delegate buffering。
- 在 `NSURLSessionDataDelegate` 接收 chunk 时累计响应 body，超过 `limits.maxBodyBytes` 时立即 cancel task 并返回 `EPERM`/Security 风格错误，避免等完整 body 下载完成后才拒绝。
- 保持 Phase 4B JS surface 不变：`responseType`、readyState、`progress`、`abort`、invalid JSON 行为不回退。
- 保持 bounded provider JSON payload：text 使用 `bodyText`，`arraybuffer` 使用 `bodyBase64`，不扩展 public provider ABI。
- 改善 native error diagnostics：超限、timeout、cancel、TLS/network 错误保留稳定 provider code 和可读 message；不泄露 request body 或敏感 header 值。
- 保持 root `platform/*` 通用，不把 XHR/network policy 解析移入 root platform。

明确不处理：

- 不实现 incremental JS progress events；本切片只是 native 早停与 bounded buffering，JS 仍接收 single bounded progress payload。
- 不做 upload progress target、XML/document response、CORS/cookie 语义。
- 不修改 `modules/ws/`、`modules/net/`、`modules/stdlib/ipaddr/`。
- 不引入 C++、libuv、第三方 HTTP parser。

## Owned Write Scope

允许修改：

- `docs/network_phase4c_xhr_streaming_execution_plan.md`
- `modules/xhr/platform/apple/src/EJSXHRApple.m`
- `tests/xhr/apple/ejs_xhr_apple_test.m`
- `tests/js/network_js_test.js`（仅当 JS mock 需要覆盖 provider-visible error semantics）
- `modules/xhr/README.md`
- `docs/network_implementation_plan.md`
- `docs/module_alignment_roadmap.md`
- `docs/design.md`

禁止主动修改：

- `modules/ws/`
- `modules/net/`
- `modules/stdlib/ipaddr/`
- root `platform/*`
- `core/*`

## Implementation Lanes

1. Baseline lane：记录当前 XHR JS/Apple/CTest 状态，区分 sandbox localhost bind failure 与真实回归。
2. Apple delegate lane：新增 provider-owned task state 与 `NSURLSessionDataDelegate` 接收路径；完成后从 state 生成与 4B 一致的 response payload。
3. Early-limit lane：chunk 接收时执行 `maxBodyBytes` 早停，保证 responder 只完成一次，并清理 task state。
4. Regression lane：扩展 Apple fixture，构造超过 body limit 的响应并验证错误发生且 fixture 连接被提前关闭；保留 4B arraybuffer/json/progress/abort 回归。
5. Review closure lane：两个独立 `gpt-5.3-codex` 子代理复核后修复 P0/P1/P2。

## Regression Tests

Apple/native：

- `maxBodyBytes` 小于响应 body 时，provider 在接收超过限制后 cancel task，并返回 `EPERM`。
- 早停路径 responder 只完成一次，后续 task completion/cancel 不重复派发。
- 既有 `/binary`、`/json`、`/invalid-json`、timeout、abort、policy tests 保持通过。

JS wrapper：

- 既有 XHR wrapper tests 保持通过；除非 native error shape 需要 JS mock 补充，否则不扩大 JS surface。

## Verification Matrix

```sh
node --check modules/xhr/js/xhr.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m docs/network_phase4c_xhr_streaming_execution_plan.md docs/network_implementation_plan.md docs/module_alignment_roadmap.md docs/design.md
```

本地 HTTP fixture 可能因 sandbox 禁止 localhost bind 而需要 escalated rerun；记录 sandbox failure 与非 sandbox 结果。

## Evidence Log

- 实现：`modules/xhr/platform/apple/src/EJSXHRApple.m` 已改为 module-owned `NSURLSession` delegate buffering（`didReceiveResponse`/`didReceiveData`/`didCompleteWithError`），`didReceiveData` 超过 `maxBodyBytes` 时立即 cancel + `EPERM`，并通过 task-state 映射保证 responder 单次 finish 与 success/error/cancel/early-limit 路径统一清理。
- 回归：`tests/xhr/apple/ejs_xhr_apple_test.m` 新增 `/stream-large` 流式响应 fixture 和 `xhr_body_limit_streaming.js` 用例；验证超限 `EPERM`，并检查服务端观测到 early close 或至少未完整写完即已返回。
- `node --check modules/xhr/js/xhr.js`: pass.
- `node --check tests/js/network_js_test.js`: pass.
- `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- `cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check`: pass.
- `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure`（sandboxed）: failed，`ejs_xhr_apple_test` 本地 fixture bind localhost 被 sandbox 拒绝（`Operation not permitted`）。
- `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure`（escalated）: pass，3/3 tests。
- `git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m docs/network_phase4c_xhr_streaming_execution_plan.md docs/network_implementation_plan.md docs/module_alignment_roadmap.md docs/design.md`: pass.
- Review subagent A (`gpt-5.3-codex`) finding fixed: streaming early-abort fixture assertion could pass during a timing window before either terminal server state was observed; replaced fixed sleep with bounded wait for `earlyClose || finishedWriting`, then require `earlyClose`.
- Review subagent A (`gpt-5.3-codex`) P3 fixed: JS unsupported `responseType` error no longer hardcodes a phase number.
- Review subagent B (`gpt-5.3-codex`) finding fixed: cancel between `consumeCancelledRequestID` and task/state registration could return a no-state task and leave the send responder unfinished; `cancelImmediately` now cancels and returns `nil + ECANCELLED`, and `ejs_xhr_apple_test` has an `EJS_TEST`-only deterministic `/cancel-before-register` regression.
- Production/test separation for the `EJS_TEST` hook:
  - `cmake -S . -B build_phase4c_prod -DEJS_ENGINE=quickjs-ng -DEJS_RUNTIME_LOOP=libuv -DEJS_TEST=OFF`: pass.
  - `cmake --build build_phase4c_prod --target ejs_xhr_apple`: pass.
  - `nm -g build_phase4c_prod/modules/xhr/libejs_xhr_apple.a`: no public `EJSXHRTestShouldCancelBeforeTaskRegistration` symbol.
  - `rg -a -n "cancel-before-register|EJSXHRTestShouldCancelBeforeTaskRegistration" build_phase4c_prod/modules/xhr/libejs_xhr_apple.a`: no matches.
