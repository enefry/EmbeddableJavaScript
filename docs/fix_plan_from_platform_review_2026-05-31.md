# Android/iOS Platform Review Follow-up Fix Plan 2026-05-31

Source review:

- User-requested Android/iOS platform review from the current thread.
- Historical Android queue: `docs/android_review_2026-05-30.md`.
- Historical Android runtime/JNI repair record: `docs/fix_plan_from_android_review_2026-05-30.md`.

## Verification Against Current Source

| ID | Platform | Status | Current-source result |
| --- | --- | --- | --- |
| PLATFORM-001 | Android | already fixed | Runtime/context invalidation, owner-thread marshalling, async operation completion, WebSocket handshake validation, WebSocket frame bounds, and worker native inbox limits are already present at `HEAD d59ce49`. |
| PLATFORM-002 | Android | fixed | `ejs.fs` Android now accepts only `copyFile.flag` values `"w"` and `"wx"` and rejects symlink targets that are empty, absolute, or contain parent traversal. |
| PLATFORM-003 | Android | fixed | Android provider unregister/context teardown now calls `EJSProvider.close()`, and executor-backed fs/kv/sqlite providers let already queued operations complete with a deterministic error after close instead of dropping responders. |
| PLATFORM-004 | iOS/Apple | fixed | Apple WebSocket send/receive paths enforce a native message-size cap before message construction or JSON/event expansion, with Apple-side message-limit self-test coverage. |
| PLATFORM-005 | iOS/Apple | fixed | Apple Worker child close now reserves/bypasses normal parent inbox capacity for the terminal close notification so native cleanup is not orphaned when the message queue is full. |
| PLATFORM-006 | Android | fixed | `EJSRuntime` now rejects a `nativeCreate()` return value of `0` and shuts down the owner executor on that path. |
| PLATFORM-007 | Android | fixed | Android Worker dispatch is owner-thread marshalled and now removes native inbox entries if context dispatch cannot run or `nativeEvaluateScript` reports an invalidated context. |
| PLATFORM-008 | iOS/Apple | fixed | Apple net operation cancellation wakes blocking `select` waits for connect, accept, read, write, and recv through a per-operation cancellation pipe. |
| PLATFORM-009 | iOS/Apple | fixed | Apple fswatch dispatches events through a provider-owned serial event queue. |

## Repair Plan

1. Align Android FS with the existing Apple and JS contract:
   - accept only `copyFile.flag` values `"w"` and `"wx"`;
   - reject symlink targets that are empty, absolute, or contain parent traversal.
2. Add a default Android `EJSProvider.close()` lifecycle hook and call it on provider replacement, unregister, unregister-all, and context destruction.
3. Override the lifecycle hook in Android providers that own executors, open handles, sockets, watchers, or database connections.
4. Add Apple WebSocket send/receive size checks before Objective-C/JSON expansion or `NSURLSessionWebSocketMessage` creation.
5. Treat Apple Worker child close as a terminal control notification that may reserve/bypass normal parent inbox capacity.
6. Reject Android runtime construction when `nativeCreate()` returns `0`, shutting down the owner executor on that path.
7. Add asynchronous Android context dispatch with failure cleanup for worker native inbox entries.
8. Wake Apple net blocking waits, including pending `tcpConnect`, through a per-operation cancellation pipe.
9. Move Apple fswatch event delivery onto a provider-owned serial event queue.
10. Validate with Android export/javac, targeted Apple tests, `git diff --check`, and independent follow-up review agents.

## Expected Verification

```sh
cmake -S . -B /private/tmp/ejs-platform-review-fix-build -DANDROID=ON -DBUILD_TESTING=ON -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub "-DCMAKE_CXX_FLAGS=-I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include -I/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/include/darwin"
cmake --build /private/tmp/ejs-platform-review-fix-build --target ejs_android_platform_test
ctest --test-dir /private/tmp/ejs-platform-review-fix-build -R ejs_android_platform_test --output-on-failure
cmake -S . -B /private/tmp/ejs-platform-review-fix-export -DANDROID=ON -DBUILD_TESTING=OFF -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub -DEJS_ANDROID_MODULES_EXPORT_DIR=/private/tmp/ejs-platform-review-fix-exported
cmake --build /private/tmp/ejs-platform-review-fix-export --target ejs_android_modules_export
javac --release 8 -cp /Users/chenrenwei/Library/Android/sdk/platforms/android-36/android.jar -d /private/tmp/ejs-platform-review-fix-javac-out $(rg --files -g '*.java' platform/android/java) $(cat /private/tmp/ejs-platform-review-fix-exported/java_sources.txt)
cmake --build build --target ejs_ws_apple_test ejs_worker_apple_test
ctest --test-dir build -R "ejs_ws_apple_test|ejs_worker_apple_test" --output-on-failure
git diff --check
```

## Verification Result

Passed:

```sh
git diff --check
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
```

Notes:

- `ejs_net_apple_test` required an outside-sandbox rerun because the sandbox denied local listen/bind during the cancellation coverage.
- Gradle also required an outside-sandbox rerun because Gradle native services could not load inside the sandbox.
