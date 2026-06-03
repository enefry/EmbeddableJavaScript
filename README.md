# embeddable JavaScript

EJS is an embeddable JavaScript runtime workspace. The current codebase is split
into a small C runtime core, a generic platform facade layer, and optional
packages such as WinterTC and EJSFS.

The source of truth for architecture is [docs/design.md](docs/design.md). Other
README files describe their local directories only; planning, review, and
upgrade notes are intentionally not kept as durable project documentation.

Module alignment roadmap (embedded-first):
[docs/module_alignment_roadmap.md](docs/module_alignment_roadmap.md).

## Current Modules

| Module | Current state |
| --- | --- |
| `core/` | Implemented C runtime kernel with public ABI, QuickJS-ng or stub engine backends, libuv or stub loop backends, context lifecycle, script/module evaluation, native async/sync invoke, timers, error objects, and tests. |
| `platform/` | Generic platform facade area. Implemented platforms are `platform/apple` and `platform/android`: Apple exposes Objective-C `EJSRuntime`, `EJSContext`, and provider APIs; Android exposes Java/JNI runtime, context, provider, and Gradle AAR packaging surfaces. |
| `modules/wintertc/` | Optional WinterTC JS-facing module installed explicitly by the consumer. It provides a generated JS bundle plus Apple default providers for clock, crypto, console, and fetch when requested through install options. It is not linked into root `platform/apple`. |
| `modules/fs/` | Optional file-system package installed explicitly by the consumer. It provides `EJSFS.promises` read/write/stat/exists/access/list/mkdir/copy/rename/delete operations, an Apple installer/provider, and sandbox policy loaded from context configuration. |
| `modules/system/` | Optional host-system package exposing async process, environment, cwd, host, CPU, network-interface, and user metadata helpers through `EJSSystem`. |
| `modules/fswatch/` | Optional file-watch package exposing `EJSFSWatch.watch(...)` with direct file/directory watch support and explicit recursive-watch rejection on current Apple builds. |
| `modules/buffer/` | Optional pure-JS binary helper package. It provides `EJSBinary` string, Base64, and Hex encoding/decoding, concatenation, comparison, and equality helpers. |
| `modules/kv/` | Optional persistent key-value and storage package. It provides `EJSKV` async key-value operations, JSON helpers, namespaced stores, `EJSStorage` facade helpers, and a SQLite-backed Apple provider. |
| `modules/sqlite/` | Optional SQLite package installed explicitly by the consumer. It provides `EJSSQLite.open`, async execute/query/transaction/close helpers, and an Apple provider backed by system SQLite and context policy. |
| `modules/path/` | Optional pure-JS POSIX path utility package. It provides `EJSPath.posix` normalize, join, dirname, basename, extname, isAbsolute, relative, resolve, parse, and format operations without accessing the file system. |
| `modules/worker/` | Optional Web Worker-style package that installs parent/child wrappers and creates isolated worker runtime/context pairs through platform providers. |
| `modules/net/` | Optional raw network package exposing `EJSNet.lookup`, TCP client/server sockets, UDP sockets, and policy-shaped `EJSNetworkError` diagnostics. |
| `modules/xhr/` | Optional embedded `XMLHttpRequest` subset with async request/response, events, headers, text/arraybuffer/json response types, and network policy gating. |
| `modules/ws/` | Optional embedded WebSocket client subset with state constants, event handlers/listeners, text/binary send, close validation, and network policy gating. |
| `modules/stdlib/` | Optional utility packages for hashing (`EJSHashing`), UUID (`EJSUUID`), and IP/CIDR parsing (`EJSIPAddr`). |
| `modules/package/` | Optional package installer that registers audited `.ejspkg` module source tables with a context. |
| `tools/ejs-pkg-convert/` | Offline npm-to-`.ejspkg` converter used by developer/CI workflows. |
| `sample/` | C and Apple samples. The Apple sample links optional add-ons explicitly. |
| `tests/` | Core tests, Apple platform/add-on tests, JS wrapper tests, network helper tests, package converter tests, and platform-boundary checks. |
| `third_party/` | Vendored `quickjs-ng` and `libuv` sources used by the full backend configuration. |

## Build

Minimal stub build:

```sh
cmake -S . -B build -DEJS_ENGINE=stub -DEJS_RUNTIME_LOOP=stub
cmake --build build --target ejs_core ejs_sample
```

Full core backend:

```sh
git submodule update --init --recursive
cmake -S . -B build -DEJS_ENGINE=quickjs-ng -DEJS_RUNTIME_LOOP=libuv -DEJS_TEST=ON
cmake --build build --target ejs_core_test ejs_regression_smoke
./build/tests/ejs_core_test
./build/tests/ejs_regression_smoke
```

Apple facade, WinterTC add-on, and EJSFS add-on targets are available on Apple
hosts:

```sh
cmake --build build --target ejs_apple_platform_test ejs_wintertc_apple_test ejs_fs_apple_test ejs_system_apple_test ejs_fswatch_apple_test ejs_net_apple_test ejs_stdlib_apple_test ejs_buffer_apple_test ejs_kv_apple_test ejs_sqlite_apple_test ejs_path_apple_test ejs_worker_apple_test ejs_xhr_apple_test ejs_ws_apple_test ejs_apple_sample
./build/tests/ejs_apple_platform_test
./build/tests/ejs_wintertc_apple_test
./build/tests/ejs_fs_apple_test
./build/tests/ejs_system_apple_test
./build/tests/ejs_fswatch_apple_test
./build/tests/ejs_net_apple_test
./build/tests/ejs_stdlib_apple_test
./build/tests/ejs_path_apple_test
./build/tests/ejs_buffer_apple_test
./build/tests/ejs_kv_apple_test
./build/tests/ejs_sqlite_apple_test
./build/tests/ejs_worker_apple_test
./build/tests/ejs_xhr_apple_test
./build/tests/ejs_ws_apple_test
./build/sample/ejs_apple_sample
```

Android AAR packaging is available through Gradle when an Android SDK and JDK 17
are configured:

```sh
gradle :ejs-android:assembleRelease
```

The Android library build packages the root Java/JNI platform bridge plus
optional module Java/resources exported by the CMake
`ejs_android_modules_export` target. Runtime module installation requires a
non-stub JavaScript engine such as quickjs-ng.

### Apple Distribution Artifacts

If you need an integration package for other iOS projects, generate XCFramework +
CocoaPods/SwiftPM artifacts:

```sh
./tools/apple/package_apple_distribution.sh
```

By default this creates:

- `dist/apple/EJS.xcframework`
- `dist/apple/EJS.podspec`
- `dist/apple/Package.swift`

Set `EJS_APPLE_PODSPEC_SOURCE_URL`, `EJS_APPLE_PODSPEC_HOMEPAGE`,
`EJS_APPLE_PODSPEC_AUTHOR`, and `EJS_APPLE_PODSPEC_AUTHOR_EMAIL` before publishing
to a remote Git repo.

## Core API Boundary

`core/include/ejs_runtime.h` exposes the runtime ABI:

- `EJSCoreRuntime`, `EJSCoreContext`, and `EJSCoreError` are opaque handles.
- public structs use `abi_version` and `struct_size` validation.
- runtime/context create and destroy, script/module evaluation, interrupt, host
  API registration, and error accessors are the public surface.

`core/include/ejs_native_api.h` exposes the native bridge ABI:

- `EJSCoreHostAPI` is registered per context.
- `__ejs_native__.invoke(...)` maps to `EJSCoreHostInvokeAPI.invoke`.
- `__ejs_native__.invokeSync(...)` maps to optional bounded synchronous
  `EJSCoreHostSyncInvokeAPI.invoke_sync`.
- `EJSCoreHostOperation`, `EJSCoreByteView`, `EJSCoreByteBuffer`, and
  `EJSCoreUserData` define operation, binary data, and host lifetime contracts.

The core does not implement WinterTC or Web API semantics and does not expose
QuickJS-ng, libuv, Objective-C, Android, or Apple SDK types in its public ABI.

Runtime/context lifecycle contract:

- starting runtime destroy invalidates all context handles owned by that runtime.
- after `ejs_runtime_destroy(...)` or `ejs_runtime_destroy_with_completion(...)`
  starts, hosts must not call `ejs_context_destroy(...)` or any other context API
  on those handles.
- hosts must serialize destroy operations per runtime in platform code; do not
  rely on concurrent destroy calls as supported behavior.

## Platform Boundary

Root `platform/*` is generic. It owns platform runtime/context wrappers,
provider registration, lifecycle, and module dispatch. Standard packages such
as WinterTC and host-capability packages such as EJSFS are add-ons that depend
on the platform facade; the root platform must not import or auto-install them.

Current Apple public names are intentionally short:

- `EJSRuntime`
- `EJSContext`
- `EJSProvider`
- `EJSRuntimeConfiguration`

The longer `EJSCore*` names remain the C ABI and bridge-internal layer.

## EJSFS Boundary

EJSFS is enabled explicitly:

```objc
#import "EJSFileSystemApple.h"

NSError *error = nil;
if (!EJSFileSystemInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The Apple installer reads the namespaced `EJSFileSystemConfigurationKey`
configuration value from the context, parses it once, registers the `ejs.fs`
provider, and installs the `globalThis.EJSFS.promises` wrapper. File, directory,
and path operations stay async through `__ejs_native__.invoke`; there are no
sync fs APIs.

## WinterTC Boundary

WinterTC is enabled explicitly:

```objc
#import "EJSWinterTCApple.h"

NSError *error = nil;
if (!EJSWinterTCInstallIntoContext(context, &error)) {
  // handle install failure
}
```

Default Apple providers are optional:

```objc
EJSWinterTCInstallOptions *options = [[EJSWinterTCInstallOptions alloc] init];
options.installDefaultProviders = YES;
EJSWinterTCInstallIntoContextWithOptions(context, options, &error);
```

The current JS bundle installs timers, events, URL, encoding, Blob/File,
ReadableStream, Headers/Request/Response/fetch, crypto digest/random helpers,
performance, console, and `globalThis.WinterTC` metadata. When default Apple
providers are enabled, `wintertc.fetch` supports `data:`, `http:`, and `https:`
requests via the WinterTC add-on.

## Buffer Boundary

Buffer is enabled explicitly:

```objc
#import "EJSBufferApple.h"

NSError *error = nil;
if (!EJSBufferInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The Apple installer evaluates the bundled JavaScript wrapper and registers `globalThis.EJSBinary`. It is a pure-JS package with no native provider.

## KV Boundary

KV is enabled explicitly:

```objc
#import "EJSKeyValueStoreApple.h"

NSError *error = nil;
if (!EJSKeyValueStoreInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The Apple installer reads `EJSKeyValueStoreConfigurationKey` ("ejs.kv") from the context configuration, parses it, registers the `ejs.kv` provider, and installs both `globalThis.EJSKV` and `globalThis.EJSStorage`. Values are stored in `<store.path>/kv.sqlite3` with SQLite WAL mode.

The `EJSStorage` facade is pure JavaScript in the KV bundle. It delegates to
`EJSKV`, so it has no separate native provider, install entrypoint, or build
target.

## SQLite Boundary

SQLite is enabled explicitly:

```objc
#import "EJSSQLiteApple.h"

NSError *error = nil;
if (!EJSSQLiteInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The Apple installer reads `EJSSQLiteConfigurationKey` ("ejs.sqlite") from the context configuration, parses named database policy, registers the `ejs.sqlite` provider, and installs `globalThis.EJSSQLite`. JavaScript opens databases by configured name only; file paths stay in host policy.

## Path Boundary

Path is enabled explicitly:

```objc
#import "EJSPathApple.h"

NSError *error = nil;
if (!EJSPathInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The Apple installer evaluates the bundled JavaScript wrapper and registers `globalThis.EJSPath`. It is a pure-JS POSIX utility package.

## Documentation Policy

Keep current architecture in [docs/design.md](docs/design.md). Keep local usage
notes in README files. Do not add new root-level plans, review transcripts,
agent coordination notes, or upgrade logs unless they are explicitly requested
as temporary artifacts.
