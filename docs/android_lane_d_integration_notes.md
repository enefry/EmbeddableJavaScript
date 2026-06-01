# Android Lane D integration notes

This lane intentionally keeps all implementation files inside `modules/worker`
and `modules/wintertc`. Mainline integration still needs the shared Android
build/test glue below.

## Root or Android build integration

- Add `modules/worker/platform/android/java` to the Android Java source set
  when the Worker module is enabled.
- Add `modules/wintertc/platform/android/java` to the Android Java source set
  when the WinterTC module is enabled.
- Keep both additions module-scoped; do not move Worker or WinterTC provider
  code into root `platform/android`.
- The module CMake files now expose `ejs_worker_android_java` and
  `ejs_wintertc_android_java` source targets for IDE/source discovery only.
  A Gradle/AAR packaging patch should wire these Java roots into the actual
  Android artifact.
- This lane intentionally does not change root Android packaging. Java source
  consumption for `modules/worker/platform/android/java` and
  `modules/wintertc/platform/android/java` still needs a root/AAR consumer
  patch before downstream Android apps receive these classes.

## Suggested Android test hook

- Add Android instrumentation/JVM tests under `tests/worker/android` for:
  Worker inline-script startup, parent-to-child message, child-to-parent
  message, synchronous ArrayBuffer transfer detachment from JS, `close()`
  flushing, and `terminate()` during startup.
- Add Android instrumentation/JVM tests under `tests/wintertc/android` for:
  `performance.now()`, `crypto.getRandomValues()`, `crypto.subtle.digest()`,
  console write no-op success, `fetch(data:)`, fetch body pull framing, and
  cancel idempotence.
- If shared `tests/CMakeLists.txt` gains Android target registration, keep it
  conditional on `ANDROID AND TARGET ejs_android_platform`.

## API contract notes

- Worker provider ID remains `ejs.worker`; method IDs are `create`, `start`,
  `postMessage`, `takeMessage`, `terminate` on the parent provider and
  `postMessage`, `takeMessage`, `close`, `reportError` on the child provider.
- WinterTC provider IDs remain `wintertc.clock`, `wintertc.crypto`,
  `wintertc.console`, and `wintertc.fetch`; method IDs match the existing JS
  wrappers.
- Android Worker uses one `EJSRuntime` and one `EJSContext` per worker. Parent
  termination requests call `requestInterrupt()` and signal the worker thread;
  context/runtime invalidation is owned by worker-thread cleanup after exit.
- Retired Android Worker cleanup is deterministic: parent close delivery is
  preserved through the parent inbox, and retired worker removal is retried
  after both parent-drain and worker-thread final `childInbox` cleanup.
- Android `wintertc.fetch` keeps pull-based response bodies native-side only
  until consumption/cancel or a bounded idle TTL cleanup removes the stream.
