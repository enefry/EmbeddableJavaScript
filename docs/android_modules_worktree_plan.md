# Android modules worktree plan

## Goal

Bring the optional `modules/` packages to Android parity with the current Apple module surface without expanding root `platform/*` responsibilities.

The main worktree is planning-only. Implementation and review must happen in child worktrees with disjoint module ownership.

## Current baseline

- Android currently has the generic `platform/android` JNI/Java provider bridge.
- Module packages currently expose Apple-specific installer/provider targets under `modules/*/platform/apple`.
- Android module work should add Android module integration beside the existing Apple implementation, not replace Apple paths.
- Pure JS modules should avoid inventing Android providers when the JS bundle can be installed directly.
- Provider-backed modules should reuse Android's existing `EJSProvider` bridge and keep platform policy in the module package.

## Shared Android module pattern

Each module worktree should use the same structure unless a module has a documented reason to differ:

- Add `modules/<module>/platform/android/include` and `modules/<module>/platform/android/src` for native Android installer/provider glue.
- Extend the module `CMakeLists.txt` with an `ANDROID AND TARGET ejs_android_platform` branch.
- Generate a JS bundle header from the module's existing `js/*.js` using the existing module bundle generator.
- Link Android module targets to `ejs_android_platform` and any module-specific system libraries.
- Keep JS API and TypeScript declarations unchanged unless Android parity exposes a bug in the cross-platform surface.
- Add Android tests under `tests/<module>/android` only inside the module worktree.
- Do not move code into root `platform/android` unless the generic bridge itself is missing a platform-neutral primitive.

## Worktree lanes

Active implementation worktrees:

- Lane A: `/private/tmp/ejs-android-lane-a-20260530`, branch `codex-android-lane-a-20260530`, checkpoint commit `c48f6a9`
- Lane B: `/private/tmp/ejs-android-lane-b-20260530`, branch `codex-android-lane-b-20260530`, checkpoint commit `7dc6658`
- Lane C: `/private/tmp/ejs-android-lane-c-20260530`, branch `codex-android-lane-c-20260530`, checkpoint commit `b4616d7`
- Lane D: `/private/tmp/ejs-android-lane-d-20260530`, branch `codex-android-lane-d-20260530`, checkpoint commit `844ddac`
- Integration: `/private/tmp/ejs-android-integration-20260530`, branch `codex-android-integration-20260530`, checkpoint commit `e85dd1b`
- Gradle/AAR packaging: `/private/tmp/ejs-android-gradle-aar-20260530`, branch `codex-android-gradle-aar-20260530`, checkpoint commit `ff10eac`

Current status:

- Lane A: implemented, fixed, and focused-reviewed with no blocking findings.
- Lane B: implemented, fixed, and focused-reviewed with no blocking findings.
- Lane C: implemented, fixed, and focused-reviewed with no blocking findings.
- Lane D: implemented, fixed, cleaned of out-of-scope Apple/global-doc edits, and focused-reviewed with no blocking findings.
- Integration: A/B/C/D lane outputs were merged into an integration worktree. It adds `ejs_android_modules_java`, `ejs_android_modules_metadata`, and `ejs_android_modules_export` as Android module aggregation/export targets. The export now de-duplicates generated metadata lists and writes a manifest permission XML snippet from the exported permission list. Focused review found no blocking findings after fixing target dependency ordering.
- Gradle/AAR packaging: implemented in a separate worktree on top of the integration checkpoint. It adds a root Gradle project, Android library module `:ejs-android`, metadata export consumption, generated Java/resource/manifest source-set wiring, and Maven local publishing setup. Packaging smoke validation fixed Android Java compile blockers in `net`, `system`, `worker`, and generated `worker`/`wintertc` script classes.

Deferred cross-lane items:

- The Gradle/AAR lane now consumes the exported module metadata files. Final merge back to main is still deferred until Android build prerequisites are available and the packaging branch is reviewed as a whole.
- Android module runtime installation requires a real JS engine such as `quickjs-ng`; the default `stub` engine is compile-only for these JS bundle installers.
- `ejs_android_modules_export` emits de-duplicated packaging metadata files under the platform Android build directory. The Gradle packaging lane copies these files into generated source/resource/manifest inputs for the Android library build.
- Real AAR generation/publishing still needs local Gradle, Android NDK/CMake integration, and initialized `third_party/quickjs-ng` plus `third_party/libuv` sources. The packaging lane could not run `gradle :ejs-android:assembleRelease` on the current machine because `gradle` is not installed and the Android SDK has no NDK.
- Tests and Android build verification were not run from this planning worktree.
- Lane B's filesystem quota is currently conservative per-file enforcement, not full root aggregate quota.
- Lane C documents residual `fswatch` runtime owner-thread risk until Android exposes a module-level owner-thread dispatch primitive.

### Lane A: pure JS installers

Modules:

- `modules/path`
- `modules/buffer`
- `modules/stdlib/hashing`
- `modules/stdlib/uuid`
- `modules/stdlib/ipaddr`

Expected scope:

- Android bundle generation and install entrypoints.
- CMake target parity with Apple.
- Android tests that confirm the installed JS surface is visible and basic APIs work.

### Lane B: local device providers

Modules:

- `modules/fs`
- `modules/kv`
- `modules/sqlite`
- `modules/system`

Expected scope:

- Android provider implementations mapped to existing JS method IDs.
- Android configuration parsing and sandbox/path policy matching the Apple semantics where applicable.
- Static review for lifecycle, path boundary, quota, and SQLite resource cleanup risks.

### Lane C: network/event providers

Modules:

- `modules/net`
- `modules/xhr`
- `modules/ws`
- `modules/fswatch`

Expected scope:

- Android provider implementations using Android/Java facilities where native-only implementation would be unnecessarily brittle.
- Preserve async completion/cancel semantics through `EJSProviderResponder` and `EJSProviderOperation`.
- Static review for callback threading, cancellation, timeout, and resource ownership.

### Lane D: runtime/concurrency modules

Modules:

- `modules/worker`
- `modules/wintertc`

Expected scope:

- Android installer/provider parity for Worker and WinterTC bootstrap APIs.
- Reuse existing Android interrupt/invalidate lifecycle instead of adding module-owned runtime lifecycle.
- Static review for teardown, nested calls, and thread ownership.

## Merge order

1. Lane A first, because it should establish the shared Android bundle/install pattern with minimal provider complexity.
2. Lane B next, because local resource providers define Android policy/config conventions.
3. Lane C next, because async network-style providers depend on the responder/cancel conventions.
4. Lane D last, because runtime/concurrency modules are most sensitive to teardown and nested call behavior.

## Review checklist

- No Android module implementation depends on Apple headers or Foundation types.
- No module broadens root `platform/android` beyond generic provider/runtime primitives.
- Provider IDs and method IDs match the existing JS wrapper expectations.
- Async providers finish exactly once and release responder/native resources on cancellation.
- File/database providers enforce configured roots and reject traversal outside the allowed path.
- CMake keeps Apple and Android branches independent.
- Tests and examples live with the module lane, not in unrelated platform folders.

## Validation status

No validation is run from this main worktree.

Current validation evidence from child worktrees:

- Integration checkpoint `e85dd1b`: static focused reviews passed; Android build/test not run.
- Gradle/AAR checkpoint `ff10eac`: `cmake -DANDROID=ON` metadata export passed; Android Java surface passed a `javac --release 8` smoke compile against Android 36 `android.jar`; real Gradle/NDK AAR build was not run because required local tools are missing.
- Lane checkpoints `c48f6a9`, `7dc6658`, `b4616d7`, and `844ddac`: original lane worktrees are now clean and preserve each lane's implementation output for later comparison or cherry-pick.
