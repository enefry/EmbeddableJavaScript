# Network Phase 4B XHR Response Types Execution Plan

更新时间：2026-05-29
状态：`completed`

源计划：

- `docs/network_implementation_plan.md` Phase 4：`modules/xhr`
- `docs/module_alignment_roadmap.md`：`modules/xhr` TODO `responseType 非文本模式、完整 readyState/事件兼容与进度事件（Phase 4B）`

## Scope

Phase 4B lands the next conservative XHR compatibility slice:

- Extend `responseType` beyond Phase 4A `""`/`"text"` to include:
  - `"arraybuffer"` returning an `ArrayBuffer` in `response`,
  - `"json"` parsing UTF-8 JSON response text into `response`.
- Keep `responseText` available only for `""`/`"text"`/`"json"` response modes; accessing it in `"arraybuffer"` mode should match browser-style failure semantics or return `""` consistently as documented by this module.
- Add basic event support for `loadstart`, `progress`, and existing `loadend`.
- Dispatch one bounded download progress event when the native provider has the completed body, including `loaded`, `total`, and `lengthComputable` when available.
- Preserve Phase 4A behavior for `open/send/abort/headers`, timeout, and error paths.
- Keep request and response body size enforcement through `limits.maxBodyBytes`.

Phase 4B intentionally does not land the full browser XHR surface:

- No synchronous XHR.
- No XML/document response parsing.
- No upload progress event target.
- No incremental streaming progress from `NSURLSessionDataDelegate` yet.
- No browser CORS/cookie semantics.
- No public native ABI growth.

## Platform And Policy Boundary

- Root `platform/*` stays generic and must not parse XHR/network policy.
- `modules/xhr` owns policy parsing, request shaping, response decoding, and event mapping.
- Apple continues using `NSURLSessionDataTask` completion handler in this slice; native returns bounded response metadata/body in JSON.
- For `"arraybuffer"`, Apple may return response bytes as base64 in the JSON payload rather than extending provider responder ABI.
- For `"json"`, native should return UTF-8 text; JS performs JSON parse so wrapper semantics are testable with mocks.
- Streaming/early body-limit abort remains a later slice that can switch Apple to a delegate-based task if needed.

## Likely Files

- `modules/xhr/js/xhr.js`
- `modules/xhr/platform/apple/src/EJSXHRApple.m`
- `modules/xhr/types/index.d.ts`
- `modules/xhr/README.md`
- `tests/js/network_js_test.js`
- `tests/xhr/apple/ejs_xhr_apple_test.m`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`
- `docs/network_implementation_plan.md`

## Implementation Lane

- Single implementation lane:
  - keep edits scoped to XHR JS/provider/tests/docs,
  - reuse the existing Phase 4A provider and policy shape,
  - do not modify root `platform/*`, `core/*`, `modules/net`, or `modules/ws`,
  - keep native payload bounded by existing policy limits.

## Regression Tests

JS wrapper tests:

- `responseType = "arraybuffer"` accepts binary response payload and sets `response` to `ArrayBuffer`.
- `responseType = "json"` parses JSON response text and sets `response` to the parsed value.
- invalid JSON in `"json"` mode drives `error` + `loadend` without throwing from event dispatch.
- `loadstart`, `progress`, `load`, and `loadend` order is stable for success.
- `progress` event exposes `loaded`, `total`, and `lengthComputable`.
- existing abort/open-cancel/error tests still pass.

Apple tests:

- local HTTP fixture returns a binary route that can be consumed as `"arraybuffer"`.
- local HTTP fixture returns a JSON route that can be consumed as `"json"`.
- local HTTP fixture covers invalid JSON behavior if feasible through JS execution.
- body limit and timeout regressions remain green.

## Verification Matrix

```sh
node --check modules/xhr/js/xhr.js
node --check tests/js/network_js_test.js
node tests/js/network_js_test.js
cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure
git diff --check -- modules/xhr tests/js/network_js_test.js tests/xhr/apple/ejs_xhr_apple_test.m docs/design.md docs/module_alignment_roadmap.md docs/network_implementation_plan.md docs/network_phase4b_xhr_response_types_execution_plan.md
```

Local HTTP fixture tests may require sandbox escalation.

## Evidence Log

- Baseline `node --check modules/xhr/js/xhr.js`: pass.
- Baseline `node --check tests/js/network_js_test.js`: pass.
- Baseline `node tests/js/network_js_test.js`: pass (`network_js_test PASS`).
- Baseline `cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check`: pass.
- Baseline `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (sandboxed): failed because the local HTTP fixture socket bind was blocked (`Operation not permitted`).
- Baseline `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (escalated): pass, 3/3 tests.

Phase 4B implementation verification (this change set):

- `node --check modules/xhr/js/xhr.js`: pass.
- `node --check tests/js/network_js_test.js`: pass.
- `node tests/js/network_js_test.js`: pass.
- `cmake --build build --target ejs_xhr_apple_test ejs_platform_boundary_check`: pass.
- `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure` (sandboxed): failed at `ejs_xhr_apple_test` fixture startup (`Operation not permitted`, localhost bind blocked by sandbox).
- Follow-up closeout in `docs/network_phase4b_xhr_response_execution_plan.md`: fixed review findings for progress timing, abort terminal state, invalid JSON readyState transitions, synchronized README/types/design/roadmap, and reran non-sandbox `ctest --test-dir build -R "ejs_network_js_test|ejs_xhr_apple_test|ejs_platform_boundary_test" --output-on-failure`: pass, 3/3 tests.
