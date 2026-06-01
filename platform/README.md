# Platform

`platform` hosts generic platform facades. These facades wrap the C runtime and
provide provider registries, but they do not own standard API packages.

Chinese integration guide: [integration_zh.md](integration_zh.md).

WinterTC (`modules/wintertc`), EJSFS (`modules/fs`), application-specific APIs,
and future standard packages are optional modules that register through the
platform provider API. Root `platform/*` must not import or auto-install them.

## Current Implementation

`platform/apple` is implemented.

Public headers:

- `EJSApplePlatform.h`
- `EJSContextConfiguration.h`
- `EJSRuntime.h`
- `EJSRuntimeConfiguration.h`
- `EJSContext.h`
- `EJSProvider.h`

`EJSRuntime` owns an `EJSCoreRuntime` and creates `EJSContext` objects with
stable context IDs. `EJSContext` owns an `EJSCoreContext`, registers a single
`EJSCoreHostAPI`, and dispatches `module_id` to Objective-C providers.

Context configuration is generic and string-keyed:

- `EJSRuntimeConfiguration.contextDefaults` provides runtime-level defaults.
- `EJSContextConfiguration.values` provides per-context overrides.
- `createContextWithID:configuration:error:` shallowly merges those dictionaries
  and freezes the result into the created context.
- `configurationValueForKey:` exposes read-only lookup to add-ons.

The platform facade stores and snapshots configuration values only. Add-ons such
as EJSFS own their namespaced schema and parsing.

Provider shape:

- `moduleID` identifies the provider.
- `invokeMethod:payload:transferBuffer:context:responder:` handles async
  `__ejs_native__.invoke`.
- optional `invokeSyncMethod:payload:transferBuffer:context:error:` handles
  bounded `__ejs_native__.invokeSync`.
- `EJSProviderResponder` completes async operations.
- `EJSImmediateOperation` and `EJSBlockOperation` cover simple operation
  handles.

Implemented behavior includes provider registration/replacement/unregister,
provider snapshots for pending invokes, sync and async dispatch, error mapping,
context invalidation, runtime invalidation, duplicate context ID protection, and
active core-call accounting during teardown. The Apple tests also cover context
configuration inheritance, override, immutability, and invalidated-context
lookup behavior.

## TODO

- Add a runtime-level provider registry or default-provider installer for
  providers that are safe to share across contexts. The runtime-level API should
  reduce repeated setup, but dispatch should still use context-level provider
  snapshots so per-context sandboxing, tenant isolation, invalidation, and
  pending invoke behavior stay explicit.

## Not Implemented

- Android Kotlin/JNI facade and AAR packaging.
- Swift overlay.
- Default Apple platform providers outside explicit add-on packages.
- Packaged consumer fixtures and cross-platform conformance reports.

## Apple Packaging

- iOS XCFramework packaging is available via `tools/apple/package_apple_distribution.sh`.
- The script emits:
  - `dist/apple/EJS.xcframework` (or custom `EJS_APPLE_PRODUCT_NAME`)
  - `dist/apple/EJS.podspec`
  - `dist/apple/Package.swift`

## Local Verification Targets

```sh
cmake --build build --target ejs_apple_platform_test
./build/tests/ejs_apple_platform_test
```

WinterTC add-on verification is intentionally separate:

```sh
cmake --build build --target ejs_wintertc_apple_test ejs_apple_sample
./build/tests/ejs_wintertc_apple_test
./build/sample/ejs_apple_sample
```

EJSFS add-on verification is also separate:

```sh
cmake --build build --target ejs_fs_apple_test
./build/tests/ejs_fs_apple_test
```
