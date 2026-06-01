# Android/iOS Modules Review Fix Plan 2026-05-31

Source review: ad-hoc Android/iOS module review from two detached worktrees:

- `/private/tmp/ejs-review-android-modules-20260531`
- `/private/tmp/ejs-review-ios-modules-20260531`

## Findings

| ID | Severity | Status | Goal |
| --- | --- | --- | --- |
| AIOS-001 | P0 | fixed | Android Worker delivery now uses asynchronous owner dispatch and cleans queued native inbox entries if dispatch cannot run or the target context is already invalidated. |
| AIOS-002 | P1 | fixed | Apple net operation cancellation now wakes blocking `select` operations, including pending `tcpConnect`, through a per-operation cancellation pipe. |
| AIOS-003 | P1 | fixed | Apple WebSocket send/receive paths now enforce a native message size cap before message construction or JSON/event expansion, with Apple-side limit coverage. |
| AIOS-004 | P2 | fixed | Apple fswatch now dispatches events through a provider-owned serial event queue instead of the main queue. |

## Repair Order

1. `AIOS-001`: add non-blocking Android context dispatch and use it for Worker message delivery.
   - Code: `platform/android/java/com/ejs/platform/EJSRuntime.java`, `platform/android/java/com/ejs/platform/EJSContext.java`, `modules/worker/platform/android/java/com/ejs/worker/EJSWorkerAndroid.java`.
   - Test: add/adjust Android-visible unit coverage where possible; keep JS Worker smoke coverage unchanged.
   - Verification: Android Java compile/export plus focused Worker JS tests.
2. `AIOS-002`: connect Apple net operation cancellation to a per-operation cancellation pipe.
   - Code: `modules/net/platform/apple/src/EJSNetApple.m`.
   - Test: extend Apple net cancel coverage so pending connect/accept/read/recv cancellation completes promptly.
   - Verification: `ejs_net_apple_test` and `ejs_network_js_test`.
3. `AIOS-003`: enforce native Apple WebSocket message limits.
   - Code: `modules/ws/platform/apple/src/EJSWebSocketApple.m`.
   - Test: Apple-side message limit self-test plus WebSocket provider smoke coverage.
   - Verification: `ejs_ws_apple_test` and `ejs_network_js_test`.
4. `AIOS-004`: provide an explicit fswatch event dispatch queue instead of assuming main queue.
   - Code: `modules/fswatch/platform/apple/src/EJSFSWatchApple.m`.
   - Test: provider-level dispatch hook or queue-directed event delivery test.
   - Verification: `ejs_fswatch_apple_test`.

## Evidence

Passed:

```sh
cmake --build build --target ejs_worker_apple_test ejs_net_apple_test ejs_ws_apple_test ejs_fswatch_apple_test
ctest --test-dir build -R "ejs_worker_apple_test|ejs_ws_apple_test|ejs_fswatch_apple_test|ejs_network_js_test|ejs_worker_js_test" --output-on-failure
ctest --test-dir build -R ejs_net_apple_test --output-on-failure
cmake -S . -B /private/tmp/ejs-platform-review-fix-build -DANDROID=ON -DBUILD_TESTING=ON -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub "-DCMAKE_CXX_FLAGS=-I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include -I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include/darwin"
cmake --build /private/tmp/ejs-platform-review-fix-build --target ejs_android_platform_test
ctest --test-dir /private/tmp/ejs-platform-review-fix-build -R ejs_android_platform_test --output-on-failure
cmake -S . -B /private/tmp/ejs-platform-review-fix-export -DANDROID=ON -DBUILD_TESTING=OFF -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub -DEJS_ANDROID_MODULES_EXPORT_DIR=/private/tmp/ejs-platform-review-fix-exported
cmake --build /private/tmp/ejs-platform-review-fix-export --target ejs_android_modules_export
javac --release 8 -cp /Users/chenrenwei/Library/Android/sdk/platforms/android-36/android.jar -d /private/tmp/ejs-platform-review-fix-javac-out $(rg --files -g '*.java' platform/android/java) $(cat /private/tmp/ejs-platform-review-fix-exported/java_sources.txt)
ANDROID_HOME=/Users/chenrenwei/Library/Android/sdk gradle -p platform/android/gradle/ejs-android :ejs-android:compileReleaseJavaWithJavac -PejsAndroidEngine=stub -PejsAndroidRuntimeLoop=stub
git diff --check
```

`ejs_net_apple_test` and Gradle were rerun outside the sandbox: the former needs local listen/bind permissions, and the latter needs Gradle native services.
