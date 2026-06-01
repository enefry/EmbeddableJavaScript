# Android Review Fix Plan 2026-05-30

Source review: `docs/android_review_2026-05-30.md`

This file records the `review-and-fix` pass for the Android review findings. The historical resolved plan at `docs/fix_plan_from_android_review.md` was intentionally left unchanged.

## Outcome

| ID | Status | Result |
| --- | --- | --- |
| ANDROID-001 | fixed | Runtime invalidation now marks runtime invalidated first, interrupts, invalidates live contexts, and defers runtime destruction until contexts are gone. |
| ANDROID-002 | fixed | Context invalidation now checks the wait predicate and delegates active context destruction to the last exiting call instead of destroying after timeout. |
| ANDROID-003 | fixed | Async provider operations now complete the core operation exactly once on success, error, cancel, responder destroy, provider-not-found, Java exception, and null-operation paths. Cancel reports `EJS_ERROR_ABORTED`. |
| ANDROID-004 | fixed | Android `EJSContext` operations now marshal to a runtime owner executor, and worker parent-to-child dispatch no longer calls child JS while holding `instance` monitor. |
| ANDROID-005 | fixed | Android callback-thread `evaluateScript` calls are now marshalled through the runtime owner executor instead of running JS directly on callback threads. |
| ANDROID-006 | fixed | Android FS/KV/SQLite providers now return promptly and run file/database work on provider-owned daemon executors. |
| ANDROID-007 | fixed | Android WebSocket handshake validates `Sec-WebSocket-Accept`. |
| ANDROID-008 | fixed | Android WebSocket frame parsing rejects invalid and oversized payload lengths before allocation. |
| ANDROID-009 | fixed | Android worker native inbox enqueue enforces `maxQueuedMessages`. |

## Key Changes

- `platform/android/java/com/ejs/platform/EJSRuntime.java`
  - Added a single runtime owner executor and owner-thread helpers.
  - Marshals runtime creation, context creation, and runtime invalidation onto the owner.
  - Requests interrupt before queued invalidation work and uses a daemon owner thread.
- `platform/android/java/com/ejs/platform/EJSContext.java`
  - Wraps public JS/context operations through the runtime owner executor.
  - Renamed native entry points to `native*` methods so public APIs can enforce ownership.
  - Requests runtime interrupt before context invalidation.
- `platform/android/jni/ejs_android_platform.cpp`
  - Added delegated context/runtime destruction for invalidation while calls are active.
  - Added one-shot core operation completion to `OperationBox`.
  - Fixed JNI `AttachCurrentThread` compatibility for both host JDK headers and Android NDK headers.
- `modules/worker/platform/android/java/com/ejs/worker/EJSWorkerAndroid.java`
  - Enforces native inbox queue limits.
  - Avoids holding the worker instance monitor while dispatching JS into the child context.
- `modules/fs/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java`
- `modules/kv/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java`
- `modules/sqlite/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java`
  - Moved async provider work to executor-backed operations.
- `modules/ws/platform/android/java/com/ejs/modules/ws/EJSWebSocketProvider.java`
  - Added handshake accept validation and frame size bounds.
- `tests/CMakeLists.txt`
- `tests/android/ejs_android_platform_test.cpp`
  - Enabled CXX for Android test targets.
  - Updated the JNI mock test for the stub engine's expected evaluation failure path.

## Verification

Passed:

```sh
cmake -S . -B /private/tmp/ejs-android-review-test-build-2 -DANDROID=ON -DBUILD_TESTING=ON -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub "-DCMAKE_CXX_FLAGS=-I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include -I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include/darwin"
cmake --build /private/tmp/ejs-android-review-test-build-2 --target ejs_android_platform_test
ctest --test-dir /private/tmp/ejs-android-review-test-build-2 -R ejs_android_platform_test --output-on-failure
ctest --test-dir /private/tmp/ejs-android-review-test-build-2 -R "ejs_worker_js_test|ejs_phase1_modules_js_test" --output-on-failure
```

Passed:

```sh
cmake -S . -B /private/tmp/ejs-android-review-export-build -DANDROID=ON -DBUILD_TESTING=OFF -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub -DEJS_ANDROID_MODULES_EXPORT_DIR=/private/tmp/ejs-android-review-export
cmake --build /private/tmp/ejs-android-review-export-build --target ejs_android_modules_export
javac --release 8 -cp /Users/chenrenwei/Library/Android/sdk/platforms/android-36/android.jar -d /private/tmp/ejs-android-javac-out $(rg --files -g '*.java' platform/android/java) $(cat /private/tmp/ejs-android-review-export/java_sources.txt)
```

Passed outside the sandbox because Gradle native services could not load in the sandbox:

```sh
ANDROID_HOME=/Users/chenrenwei/Library/Android/sdk gradle -p platform/android/gradle/ejs-android tasks --all
ANDROID_HOME=/Users/chenrenwei/Library/Android/sdk gradle -p platform/android/gradle/ejs-android :ejs-android:compileReleaseJavaWithJavac -PejsAndroidEngine=stub -PejsAndroidRuntimeLoop=stub
```

Additional isolated worktree verification passed in `/private/tmp/ejs-android-verify-20260531`:

```sh
cmake -S . -B /private/tmp/ejs-android-verify-20260531-test-build -DANDROID=ON -DBUILD_TESTING=ON -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub "-DCMAKE_CXX_FLAGS=-I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include -I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include/darwin"
cmake --build /private/tmp/ejs-android-verify-20260531-test-build --target ejs_android_platform_test
ctest --test-dir /private/tmp/ejs-android-verify-20260531-test-build -R ejs_android_platform_test --output-on-failure
ctest --test-dir /private/tmp/ejs-android-verify-20260531-test-build -R "ejs_worker_js_test|ejs_phase1_modules_js_test" --output-on-failure
cmake -S . -B /private/tmp/ejs-android-verify-20260531-export-build -DANDROID=ON -DBUILD_TESTING=OFF -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub -DEJS_ANDROID_MODULES_EXPORT_DIR=/private/tmp/ejs-android-verify-20260531-export
cmake --build /private/tmp/ejs-android-verify-20260531-export-build --target ejs_android_modules_export
javac --release 8 -cp /Users/chenrenwei/Library/Android/sdk/platforms/android-36/android.jar -d /private/tmp/ejs-android-verify-20260531-javac-out $(rg --files -g '*.java' platform/android/java) $(cat /private/tmp/ejs-android-verify-20260531-export/java_sources.txt)
ANDROID_HOME=/Users/chenrenwei/Library/Android/sdk gradle -p platform/android/gradle/ejs-android :ejs-android:compileReleaseJavaWithJavac -PejsAndroidEngine=stub -PejsAndroidRuntimeLoop=stub
ANDROID_HOME=/Users/chenrenwei/Library/Android/sdk gradle -p platform/android/gradle/ejs-android :ejs-android:assembleRelease -PejsAndroidEngine=stub -PejsAndroidRuntimeLoop=stub
git diff --check
```

The first isolated `assembleRelease` attempt exposed an Android NDK compile failure in `AttachCurrentThread` caused by using the host-JDK `void**` signature unconditionally. The fix now branches on `__ANDROID__`; the subsequent stub `assembleRelease` passed for `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64`.

## Residual Risk

- Full Android native/AAR build with non-stub `quickjs-ng` + `libuv` was attempted in `/private/tmp/ejs-android-verify-20260531` and is blocked by empty third-party checkouts. CMake stops at `EJS_RUNTIME_LOOP=libuv requires EJS_LIBUV_SOURCE_DIR to point to a libuv checkout`, expecting `third_party/libuv/CMakeLists.txt`.
- The FS/KV/SQLite executor providers use daemon single-thread executors and do not yet expose an explicit provider shutdown hook.
