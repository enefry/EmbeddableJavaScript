# Android Lane B Integration Notes

Worktree: `/private/tmp/ejs-android-lane-b-20260530`
Branch: `codex-android-lane-b-20260530`

## Module-local changes

Lane B keeps Android module policy and provider behavior under each optional module:

- `modules/fs/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java`
- `modules/kv/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java`
- `modules/sqlite/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java`
- `modules/system/platform/android/java/com/ejs/modules/system/EJSSystem.java`

Each installer registers its own `EJSProvider` through the existing generic Android bridge and then evaluates the module JS bundle from module-local Android resources. No module-specific behavior is added to root `platform/android`.

## Mainline integration patch needed

This lane intentionally did not edit shared root CMake or test registration files. Mainline should wire these module-local Android targets into whatever Android packaging/AAR build target owns Java source/resource collection.

Suggested integration shape:

```cmake
if(ANDROID)
  add_subdirectory(modules/fs)
  add_subdirectory(modules/kv)
  add_subdirectory(modules/sqlite)
  add_subdirectory(modules/system)

  # The package/AAR target should consume Java and resource paths from:
  #   ejs_fs_android
  #   ejs_kv_android
  #   ejs_sqlite_android
  #   ejs_system_android
endif()
```

If the Android packaging target cannot consume `INTERFACE` Java/resource sources, convert the four module-local `target_sources(... INTERFACE ...)` lists into the packaging system's expected source/resource collection without moving the files into root `platform/android`.

This fix pass still intentionally leaves root files unchanged. The module-local Android `INTERFACE` targets remain only declarations; a root or AAR packaging consumer must still collect their Java sources and resources for shipping builds.

## Fix pass notes

- `ejs.kv` Android `get` now returns an explicit JSON envelope from the provider and the Android resource wrapper decodes `{ found, value }`, so a missing key is not represented as a nullable `byte[]`.
- `ejs.fs` Android now derives root permission checks from open flags, preserves read-only roots for reads and write-only roots for writes, uses no-follow path handling for delete/lstat/readLink, returns `readLink().target`, and applies conservative per-file `limitBytes` checks on write/truncate/copy paths.
- `ejs.sqlite` Android now records `readOnly` on each connection and rejects write execution or transactions on read-only connections.

## Test integration deferred

No shared `tests/CMakeLists.txt` changes were made. If Android module tests are added later, place module-specific fixtures under `tests/<module>/android` and wire them in a separate mainline integration patch.
