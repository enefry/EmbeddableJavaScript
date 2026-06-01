# Android modules CMake integration notes

This integration layer exposes Android module Java/source/resource metadata for a future root Android, AAR, or Gradle packaging consumer. It does not build or publish an AAR by itself.

## Root aggregation targets

`platform/android/CMakeLists.txt` defines two Android-only aggregation targets:

- `ejs_android_modules_java`: custom target that depends on module Java/resource generation targets.
- `ejs_android_modules_metadata`: interface target that exposes the same packaging metadata as interface properties.
- `ejs_android_modules_export`: custom target that depends on module Java/resource generation targets and emits packaging metadata files under the configured export directory.

Packaging consumers can query these target properties after all module subdirectories are configured:

- `EJS_ANDROID_MODULE_PATHS` on `ejs_android_modules_java`.
- `EJS_ANDROID_JAVA_SOURCE_ROOTS` on `ejs_android_modules_java`.
- `EJS_ANDROID_JAVA_SOURCES` on `ejs_android_modules_java`.
- `EJS_ANDROID_RESOURCE_DIRS` on `ejs_android_modules_java`.
- `EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS` on `ejs_android_modules_java`.
- `EJS_ANDROID_REQUIRED_ENGINE_NOTE` on `ejs_android_modules_java`.
- `INTERFACE_EJS_ANDROID_MODULE_PATHS` on `ejs_android_modules_metadata`.
- `INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS` on `ejs_android_modules_metadata`.
- `INTERFACE_EJS_ANDROID_JAVA_SOURCES` on `ejs_android_modules_metadata`.
- `INTERFACE_EJS_ANDROID_RESOURCE_DIRS` on `ejs_android_modules_metadata`.
- `INTERFACE_EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS` on `ejs_android_modules_metadata`.
- `INTERFACE_EJS_ANDROID_REQUIRED_ENGINE_NOTE` on `ejs_android_modules_metadata`.

The required engine note is intentionally explicit: Android module installation evaluates JavaScript bundles and requires a non-stub JavaScript engine such as `quickjs-ng`. The default stub engine is not sufficient for runtime module installation.

## Packaging metadata export

The `ejs_android_modules_export` target writes metadata to `EJS_ANDROID_MODULES_EXPORT_DIR`, which defaults to `${CMAKE_CURRENT_BINARY_DIR}/android-modules` for `platform/android`.

Generated files:

- `module_paths.txt`
- `java_source_roots.txt`
- `java_sources.txt`
- `resource_dirs.txt`
- `manifest_permissions.txt`
- `AndroidManifest.permissions.xml`
- `engine_requirement.txt`
- `README.md`

`manifest_permissions.txt` contains the de-duplicated aggregated permission list. `AndroidManifest.permissions.xml` is generated from that list by `platform/android/cmake/write_manifest_permissions.cmake`.

## Covered modules

The aggregation layer now collects metadata from:

- `modules/path`
- `modules/buffer`
- `modules/stdlib/hashing`
- `modules/stdlib/uuid`
- `modules/stdlib/ipaddr`
- `modules/fs`
- `modules/kv`
- `modules/sqlite`
- `modules/system`
- `modules/net`
- `modules/xhr`
- `modules/ws`
- `modules/fswatch`
- `modules/worker`
- `modules/wintertc`

## Permissions

The aggregation metadata exposes `android.permission.INTERNET` when network-capable modules are installed: `net`, `xhr`, `ws`, and `wintertc` fetch support. A final Android app or AAR manifest still owns manifest merging and permission declaration.

## Boundary

Provider implementations remain module-local under `modules/*/platform/android`. The root Android platform only exposes aggregate packaging metadata and generation dependencies; it does not absorb optional-module provider implementations or add module-specific provider dispatch.

## Deferred

- Actual Gradle source set wiring is still deferred to the Android/AAR packaging layer.
- AAR generation and publishing are not implemented here.
- Manifest merge implementation is deferred to the final Android packaging consumer.
- Gradle/AAR consumers can use the generated de-duplicated metadata files directly, or read the raw CMake target properties if they need custom packaging behavior.
