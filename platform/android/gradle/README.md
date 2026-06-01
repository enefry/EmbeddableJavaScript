# Android Gradle packaging

This Gradle project packages the root Android platform bridge and optional
Android module Java/resources into an Android library AAR.

Build from the repository root:

```sh
gradle :ejs-android:assembleRelease
```

The checked-in build uses Android Gradle Plugin 8.10.1, which supports API 36
and requires Gradle 8.11.1 or newer plus JDK 17 according to the Android Gradle
Plugin 8.10 release notes.

Set `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or a local `local.properties` `sdk.dir`
when the SDK is not discoverable by Android Gradle Plugin.

Publish to a local Maven repository under the module build directory:

```sh
gradle :ejs-android:publishReleasePublicationToEjsLocalRepository
```

The library build runs the CMake `ejs_android_modules_export` target before
Java compilation. That target generates Java bundle classes and metadata under
`platform/android/gradle/ejs-android/build/generated/ejs/cmake`, then Gradle
copies the exported Java files, Java resources, and manifest permissions into
its generated source set.

Useful properties:

- `ejsAndroidCompileSdk`: overrides the detected highest installed Android SDK.
- `ejsAndroidMinSdk`: defaults to `28`; the native libuv build requires Android
  API declarations for `posix_spawn`.
- `ejsAndroidEngine`: defaults to `quickjs-ng`; use `stub` only for compile-only
  native validation.
- `ejsAndroidRuntimeLoop`: defaults to `libuv`; use `stub` only for compile-only
  native validation.
- `ejsQuickJsNgSourceDir`: overrides `third_party/quickjs-ng`.
- `ejsLibuvSourceDir`: overrides `third_party/libuv`.
- `ejsCmakeExecutable`: overrides the `cmake` executable used by the metadata
  export task.

Runtime module installation requires a non-stub engine because the Android
installers evaluate generated JavaScript bundles.
