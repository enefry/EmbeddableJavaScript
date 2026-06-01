# Android Review 2026-05-30

This review was produced from three detached worktrees at `HEAD f42eccd`:

- `/private/tmp/ejs-android-review-platform-20260530`: JNI/runtime/context lifecycle.
- `/private/tmp/ejs-android-review-gradle-20260530`: Gradle/AAR/CMake packaging.
- `/private/tmp/ejs-android-review-modules-20260530`: Android module providers.

The main checkout was not modified during the review. This document is the input
queue for the repo-local `skills/review-and-fix` workflow. The post-fix status
and verification evidence are tracked in
`docs/fix_plan_from_android_review_2026-05-30.md`.

## Findings

### ANDROID-001: Runtime invalidate destroys the core runtime while contexts may still be active

- Severity: P0
- Status: pending verification
- File: `platform/android/jni/ejs_android_platform.cpp`
- Evidence:
  - `Java_com_ejs_platform_EJSRuntime_nativeInvalidate` sets
    `runtime->core_runtime = nullptr` and calls `ejs_runtime_destroy(coreRuntime)`.
  - It snapshots `runtime->contexts` but does not wait for any context
    `active_calls` before destroying the shared runtime.
- Expected behavior: runtime invalidation must request interruption and prevent
  new calls, then coordinate with active contexts before destroying the core
  runtime or its contexts.
- Risk: concurrent `evaluateScript`, `evaluateModule`, provider dispatch, or
  completion callbacks can keep using core objects after runtime destruction.

### ANDROID-002: Context invalidate ignores wait timeout and destroys an active core context

- Severity: P0
- Status: pending verification
- File: `platform/android/jni/ejs_android_platform.cpp`
- Evidence:
  - `Java_com_ejs_platform_EJSContext_nativeInvalidate` calls `cv.wait_for(...)`
    but does not check whether the predicate became true.
  - The function still calls `ejs_context_destroy(context->core_context)` after
    the wait block.
- Expected behavior: timeout must not be treated as proof that all active calls
  exited. It should either keep the core context alive until the last `endCall`
  or move destruction to a safe owner-thread/lifecycle path.
- Risk: use-after-free when another thread is still executing inside the same
  context after the timeout.

### ANDROID-003: Async provider completion never completes the core host operation

- Severity: P1
- Status: pending verification
- File: `platform/android/jni/ejs_android_platform.cpp`
- Evidence:
  - `Java_com_ejs_platform_EJSProviderResponder_nativeFinishWithData` calls the
    saved `EJSCoreInvokeCompletion`, then calls `state->decRef()`.
  - It does not call `ejs_native_operation_complete(coreOperation)`, unlike the
    Apple provider bridge.
  - `EJSCoreHostOperation` starts with caller and completion references; release
    alone cannot release the completion-side reference.
- Expected behavior: successful or failed async completion must complete the core
  host operation exactly once.
- Risk: leaked `EJSCoreHostOperation` / `OperationBox` state for async providers
  such as net, XHR, WebSocket, and fetch.

### ANDROID-004: Worker dispatch crosses EJSContext thread boundaries

- Severity: P0
- Status: pending verification
- File: `modules/worker/platform/android/java/com/ejs/worker/EJSWorkerAndroid.java`
- Evidence:
  - Parent-side `postMessage` can call `child.evaluateScript(...)` from the
    parent/provider call thread.
  - Child-side provider methods call `parentContext.evaluateScript(...)` from
    the worker thread.
- Expected behavior: all JS evaluation and dispatch into a context must run on
  that context/runtime owner thread or through an explicit safe dispatch API.
- Risk: QuickJS/EJS context reentrancy violations, deadlock, or crashes during
  cross-thread worker message dispatch.

### ANDROID-005: fswatch callbacks evaluate JS from a FileObserver executor thread

- Severity: P0/P1
- Status: pending verification
- File: `modules/fswatch/platform/android/java/com/ejs/modules/fswatch/EJSFSWatchProvider.java`
- Evidence:
  - `FileObserver.onEvent` schedules a daemon executor task.
  - That task directly calls `context.evaluateScript(...)`.
- Expected behavior: fswatch events should be marshalled to a context-safe owner
  dispatch path before touching JS.
- Risk: same thread-affinity failure class as worker dispatch, triggered by
  filesystem events.

### ANDROID-006: FS/KV/SQLite providers perform blocking I/O synchronously inside async invoke

- Severity: P1
- Status: pending verification
- Files:
  - `modules/fs/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java`
  - `modules/kv/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java`
  - `modules/sqlite/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java`
- Evidence:
  - Each provider computes the full result before returning an
    `ImmediateOperation`.
  - Operations include filesystem reads/writes, SQLite open/query/statement
    execution, and recursive deletion.
- Expected behavior: async native invoke providers must not block the JS owner
  thread for unbounded file or database I/O.
- Risk: JS runtime stalls, ANR-prone behavior, and amplified invalidation races.

### ANDROID-007: WebSocket handshake does not validate Sec-WebSocket-Accept

- Severity: P1
- Status: pending verification
- File: `modules/ws/platform/android/java/com/ejs/modules/ws/EJSWebSocketProvider.java`
- Evidence:
  - The provider accepts any `HTTP/1.1 101` or `HTTP/1.0 101` response.
  - It does not compute or compare the expected `Sec-WebSocket-Accept` header.
- Expected behavior: the server accept value must match
  `base64(sha1(clientKey + websocketGuid))`.
- Risk: a non-WebSocket endpoint or malicious intermediary can be accepted as a
  valid WebSocket peer.

### ANDROID-008: WebSocket frame length can trigger unsafe allocation

- Severity: P1
- Status: pending verification
- File: `modules/ws/platform/android/java/com/ejs/modules/ws/EJSWebSocketProvider.java`
- Evidence:
  - `readFrame` parses 64-bit payload length, casts it to `int`, and allocates
    `new byte[(int) len]`.
  - There is no configured maximum frame/message size.
- Expected behavior: frame payload length must be bounded before allocation and
  rejected with a provider error when it exceeds policy.
- Risk: OOM, negative array size, or denial of service from a hostile peer.

### ANDROID-009: Worker native inbox does not enforce maxQueuedMessages

- Severity: P2
- Status: pending verification
- File: `modules/worker/platform/android/java/com/ejs/worker/EJSWorkerAndroid.java`
- Evidence:
  - The provider parses and returns `maxQueuedMessages`.
  - Native `enqueue(...)` only inserts into the inbox map and never checks queue
    size.
- Expected behavior: native queue insertion should enforce the same
  `maxQueuedMessages` limit as the JS wrapper.
- Risk: native inbox growth can bypass JS-side queue checks during direct calls
  or abnormal dispatch paths.

## Verification notes

- `cmake --build /private/tmp/ejs-android-review-gradle-20260530-cmake --target ejs_android_modules_export` passed.
- `gradle -q :ejs-android:tasks --all` did not configure because the temporary
  worktree had no Android SDK location (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, or
  `local.properties`).
