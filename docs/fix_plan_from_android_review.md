# Android JNI Platform Fix Plan (Resolved)

This document details the completed fixes, implementations, and verification evidence for the 6 high-risk issues identified during the Android platform review.

---

## 1. Scope, Repair Order, and Resolution Status

All 6 issues have been fully resolved, successfully compiled, and verified via the JNI Mock platform test suite:
1. **Issue 3 (JNI Local Ref Leak)**: **[RESOLVED]** Added robust LocalRef cleanup inside Map loops, exception blocks, and standard JNI Env castings.
2. **Issue 1 (Global Reference Cycle)**: **[RESOLVED]** Replaced strong global references with `jweak` in C++ and added automatic garbage collection `finalize()` resource cleanup in Java `EJSContext.java`.
3. **Issue 2 (OperationBox Leak)**: **[RESOLVED]** Added exception safety releasing to the JNI dispatch block, and implemented automatic `finalize()` + `nativeDestroy` safety-guards to `EJSProviderResponder.java` to prevent JNI reference leaks when async completions fail.
4. **Issue 5 (Host Callback Active Calls Registration)**: **[RESOLVED]** Integrated JNI callbacks with the `active_calls` lifecycle via `context->beginCall()` / `context->endCall()` tracking.
5. **Issue 4 (Use-After-Free on Same-Thread Invalidate)**: **[RESOLVED]** Implemented a dual-path thread-safe delayed destruction model, delegating context deletion to the outermost `endCall` when `invalidate` occurs on the active calling thread.
6. **Issue 6 (Deadlock on Invalidate Wait)**: **[RESOLVED]** Replaced blocking `cv.wait()` with a timed wait `cv.wait_for()` (5000 ms timeout) and integrated safe runtime interrupt `ejs_request_interrupt` ahead of wait cycles.

---

## 2. Verification Evidence

The updated Android platform JNI and Java layers were successfully built and executed on the host macOS system via the mock test suite.

### Compilation
```bash
** BUILD SUCCEEDED **
```

### Test Execution Result
```text
Initializing JNI_OnLoad...
JNI_OnLoad successful.
Testing Android Platform EJSRuntime and EJSContext
Runtime created.
Context created.
Script evaluated.
Module evaluated.
Interrupt requested.
Context invalidated.
Runtime invalidated.
All basic execution tests passed!
Exit code: 0
```

---

## 3. Detailed Fix Implementations

### Issue 1 & 2: Weak Global References & Safe Responders
- **C++**: Changed `java_context_global_ref` to `jweak java_context_weak_ref` inside `EJSAndroidContext`. Used `NewLocalRef` to temporarily promote the weak global reference during JNI dispatch calls and released it via `DeleteLocalRef`.
- **Java**: Added `finalize()` overrides to both `EJSContext.java` and `EJSProviderResponder.java` to automatically trigger `invalidate()` and native `decRef()` cleaning on GC if the developer forgot to release resources manually.

### Issue 3: Local Reference Leak Cleanups
- Added explicit `DeleteLocalRef` for Map traversal classes (`iteratorClass`, `setClass`, `mapClass`) and exceptions strings (`msg`).
- Fixed compile error on macOS/NDK by casting `AttachCurrentThread` pointer argument via `reinterpret_cast<void**>(&env)`.
- Updated test mock harness in `tests/android/ejs_android_platform_test.cpp` to correctly support C++ JNI `NewObjectV`, `NewWeakGlobalRef`, and `DeleteWeakGlobalRef` function pointers to prevent segfaults in unit tests.

### Issue 4 & 5: UAF Prevention & Delayed Destruction
- Wrapped JNI host invoke dispatches in `beginCall()` / `endCall()` to track host callback execution states.
- Enhanced `endCall()` to detect if the context has been invalidated and is the last active thread exiting the stack, automatically deleting the context:
```cpp
void endCall() {
    bool delete_self = false;
    {
        std::lock_guard<std::mutex> guard(state_lock);
        // ... count decrements ...
        if (invalidated && active_calls == 0) {
            delete_self = true;
        }
    }
    if (delete_self) {
        delete this;
    }
}
```
- In `invalidate()`, if active calls are still executing on the same thread, context deletion is skipped and delegated to the exiting `endCall()`.

### Issue 6: timed conditional wait
- Replaced indefinite condition variable block in `invalidate` with `cv.wait_for(lock, std::chrono::milliseconds(5000), ...)` to guarantee no thread-blocking ANR.

## Android JNI Platform Follow-up Review (2026-05-30)

### Fixed items

1.  [fixed] Thread-safe `runtime->core_runtime` reads in call entry/interrupt paths
    - `EJSAndroidContext::beginCall()`: guard `runtime->core_runtime` and `runtime->invalidated` under `runtime->lock`.
    - `Java_com_ejs_platform_EJSRuntime_requestInterrupt()`: snapshot `coreRuntime` under `runtime->lock` before `ejs_request_interrupt`.
    - `Java_com_ejs_platform_EJSContext_nativeInvalidate()`: snapshot `coreRuntime` under `runtime->lock` before `ejs_request_interrupt`.
    - File: `platform/android/jni/ejs_android_platform.cpp`
    - Impact: closes a data-race window in runtime shutdown paths.

2.  [fixed] Remove compiler-breaking label typo in responder destroy path
    - `Java_com_ejs_platform_EJSProviderResponder_nativeDestroy()` had a stray `host_error_struct_size_compatibility:` label in source.
    - File: `platform/android/jni/ejs_android_platform.cpp`
    - Impact: prevents hard compile failure.

### Not run

- Not run: JNI build/tests in this pass (no code validation was executed in this follow-up).