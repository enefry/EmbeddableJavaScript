# Android Lane A integration notes

Lane A added Android module-local Java installers and generated JS bundle targets for:

- `modules/path`
- `modules/buffer`
- `modules/stdlib/hashing`
- `modules/stdlib/uuid`
- `modules/stdlib/ipaddr`

No root `platform/android` provider bridge changes are required. The existing `com.ejs.platform.EJSContext.registerProvider(...)` and `evaluateScript(...)` APIs are sufficient.

## Mainline integration patch

The module directories now expose these CMake custom targets when `ANDROID` and `ejs_android_platform` are available:

- `ejs_path_android_java`
- `ejs_buffer_android_java`
- `ejs_hashing_android_java`
- `ejs_uuid_android_java`
- `ejs_ipaddr_android_java`

Each module also exposes an INTERFACE metadata target with absolute Java roots and source files:

- `ejs_path_android_java_metadata`
- `ejs_buffer_android_java_metadata`
- `ejs_hashing_android_java_metadata`
- `ejs_uuid_android_java_metadata`
- `ejs_ipaddr_android_java_metadata`

Consumers can read `INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS` and `INTERFACE_EJS_ANDROID_JAVA_SOURCES` from those metadata targets. The custom targets still generate the bundle classes; the metadata only makes the module-local roots easier for a root Android/AAR packaging layer to consume.

The Android app/library build should depend on those targets before Java compilation and include both source and generated Java roots.

Suggested source roots:

```cmake
${CMAKE_SOURCE_DIR}/modules/path/platform/android/java
${CMAKE_BINARY_DIR}/modules/path/generated/android/java
${CMAKE_SOURCE_DIR}/modules/buffer/platform/android/java
${CMAKE_BINARY_DIR}/modules/buffer/generated/android/java
${CMAKE_SOURCE_DIR}/modules/stdlib/hashing/platform/android/java
${CMAKE_BINARY_DIR}/modules/stdlib/hashing/generated/android/java
${CMAKE_SOURCE_DIR}/modules/stdlib/uuid/platform/android/java
${CMAKE_BINARY_DIR}/modules/stdlib/uuid/generated/android/java
${CMAKE_SOURCE_DIR}/modules/stdlib/ipaddr/platform/android/java
${CMAKE_BINARY_DIR}/modules/stdlib/ipaddr/generated/android/java
```

Suggested dependency wiring for the Android Java packaging target:

```cmake
add_dependencies(<android_java_packaging_target>
  ejs_path_android_java
  ejs_buffer_android_java
  ejs_hashing_android_java
  ejs_uuid_android_java
  ejs_ipaddr_android_java
)
```

If the canonical Android build is Gradle-only, mirror the same roots in the Android source set and invoke the CMake targets before `compileJava`/`compile<Variant>JavaWithJavac`.

Lane A does not complete root AAR packaging. A root Android/AAR or Gradle consumer still needs to wire these metadata targets or equivalent source sets into the published artifact and make Java compilation depend on the generated bundle targets.

## Runtime install calls

Runtime installation requires a real JS engine backend, such as `quickjs-ng`, because the installers call `evaluateScript(...)` to load the generated JS wrappers. The default stub engine is compile-only for this lane: it can build the Android Java module sources, but it cannot install the JS bundles at runtime.

The app-facing integration can install modules explicitly:

```java
com.ejs.modules.path.EJSPath.installIntoContext(context);
com.ejs.modules.buffer.EJSBuffer.installIntoContext(context);
com.ejs.modules.stdlib.hashing.EJSHashing.installIntoContext(context);
com.ejs.modules.stdlib.uuid.EJSUUID.installIntoContext(context);
com.ejs.modules.stdlib.ipaddr.EJSIPAddr.installIntoContext(context);
```

`hashing` and `uuid` evaluate their wrappers before registering Java providers. The wrappers only capture provider IDs and invoke native methods lazily, so installing this way keeps repeated install attempts from unregistering an existing usable provider when wrapper evaluation fails.

## Provider IDs and method IDs

- `modules/stdlib/hashing/js/hashing.js` invokes `moduleID = "ejs.hashing"`, `methodID = "digest"`.
- `modules/stdlib/uuid/js/uuid.js` invokes `moduleID = "ejs.uuid"`, `methodID = "v4"`.

The Android Java providers match those IDs.
