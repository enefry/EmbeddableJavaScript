# EJS Current Design

This document describes the current source tree. It is the durable design
handoff for future work; historical plans, reviews, and upgrade notes should not
be treated as project documentation.

Execution roadmap for module alignment (embedded-first staged rollout):
[module_alignment_roadmap.md](module_alignment_roadmap.md).

## 1. Architecture Goal

EJS separates three concerns:

- `core` is the minimal embeddable runtime kernel. It owns the C ABI, JS engine
  abstraction, runtime loop abstraction, Runtime/Context lifecycle,
  script/module evaluation, errors, timers, and native invoke channels.
- `platform` is the generic host-language facade layer. It turns core handles
  into platform objects and dispatches native calls to providers by module ID.
- `modules/wintertc` is an optional WinterTC standard API module. It installs
  JS globals and registers package-owned providers through the generic platform
  API when the consumer asks for it.
- `modules/fs` is an optional file-system package. It installs the
  `EJSFS.promises` JavaScript wrapper and an Apple provider backed by
  context-owned sandbox configuration.
- `modules/buffer` is an optional pure-JavaScript binary helper package that
  exposes `EJSBinary` for encoding, decoding, and comparing raw bytes.
- `modules/kv` is an optional persistent key-value and storage package. It
  installs `EJSKV`, installs the pure-JavaScript `EJSStorage` facade, and
  registers a SQLite-backed native provider configured by context-owned policy.
- `modules/sqlite` is an optional SQLite package. It installs `EJSSQLite` and
  registers a native provider configured by named database policy.
- `modules/path` is an optional pure-JavaScript POSIX path helper package that
  exposes `EJSPath` without accessing the file system.
- `modules/worker` is an optional Web Worker-style package. It installs the
  parent/child JavaScript wrappers, registers a native provider with
  context-owned source policy (`ejs.worker`), and creates one isolated
  `EJSRuntime + EJSContext` per worker instance.
- `modules/stdlib/ipaddr` is an optional pure-JavaScript IP/CIDR helper package
  for network policy and application address parsing.
- `modules/net` is a stage 3 raw network add-on. Current source implements
  Apple DNS lookup through `EJSNet.lookup`, TCP client sockets through
  `EJSNet.tcp.connect`, TCP server listener sockets through
  `EJSNet.tcp.listen/accept/close`, and UDP sockets through
  `EJSNet.udp.bind/send/recv/close`.
- `modules/xhr` is a stage 3 network add-on. Current source implements the
  Phase 4C embedded `XMLHttpRequest` subset on Apple with async `open/send/abort`,
  request/response headers, readyState transitions, `loadstart/progress/load/loadend`,
  `responseType` support for `""`/`"text"`/`"arraybuffer"`/`"json"`, and JSON parse
  error routing through `error + loadend`, backed by a module-owned `NSURLSession`
  delegate buffering provider with early `maxBodyBytes` abort.
- `modules/ws` is a stage 3 network add-on. Current source implements the
  Phase 5A embedded WebSocket client subset on Apple with async
  `CONNECTING/OPEN/CLOSING/CLOSED` state transitions, `onopen/onmessage/onerror/onclose`,
  `addEventListener/removeEventListener`, `send(string|ArrayBuffer|ArrayBufferView)`,
  `close(code?, reason?)`, and `binaryType` limited to `"arraybuffer"`.

The dependency direction is:

```text
Application
  -> optional packages: WinterTC, EJSFS, Buffer, KV, SQLite, Path, IPAddr, ...
  -> generic platform facade
  -> core runtime
  -> engine / loop backends
```

Root `platform/*` must stay independent from optional packages such as WinterTC
and EJSFS. Stage 3 additionally keeps network-specific names such as `EJSNet`,
`EJSNetwork`, `XMLHttpRequest`, and `WebSocket` out of root `platform/*`.
`core` must stay independent from platform SDKs, WinterTC or Web API semantics,
and file-system or network policy.

## 2. Source Map

```text
core/include/ejs_runtime.h              Public runtime ABI
core/include/ejs_native_api.h           Public native host ABI
core/src/ejs_runtime.c                  Public API routing and lifecycle
core/src/ejs_native_api.c               Host API validation, operations, buffers
core/src/ejs_error.c                    Error object implementation
core/src/ejs_abi.c                      Runtime/eval ABI validation
core/src/ejs_engine.h                   Engine backend interface
core/src/ejs_engine_quickjs_ng.c        QuickJS-ng backend and JS bindings
core/src/ejs_engine_stub.c              Stub engine backend
core/src/ejs_runtime_loop.h             Runtime loop backend interface
core/src/ejs_runtime_loop_libuv.c       libuv owner-thread loop backend
core/src/ejs_runtime_loop_stub.c        Stub loop backend
platform/apple/include/*.h              Apple Objective-C facade headers
platform/apple/src/EJSApplePlatform.m   Apple runtime/context/provider bridge
platform/integration_zh.md              Chinese Apple platform integration guide
modules/wintertc/js/*.js                Generated-bundle input scripts
modules/wintertc/platform/apple/*       WinterTC Apple add-on installer/providers
modules/wintertc/js_api_zh.md           Chinese WinterTC JavaScript API guide
modules/fs/js/*.js                      EJSFS generated-bundle input scripts
modules/fs/platform/apple/*             EJSFS Apple add-on installer/provider
modules/system/js/*.js                  EJSSystem generated-bundle input scripts
modules/system/platform/apple/*         EJSSystem Apple add-on installer/provider
modules/fswatch/js/*.js                 EJSFSWatch generated-bundle input scripts
modules/fswatch/platform/apple/*        EJSFSWatch Apple add-on installer/provider
modules/stdlib/hashing/js/*.js          EJSHashing generated-bundle input scripts
modules/stdlib/hashing/platform/apple/* EJSHashing Apple add-on installer/provider
modules/stdlib/uuid/js/*.js             EJSUUID generated-bundle input scripts
modules/stdlib/uuid/platform/apple/*    EJSUUID Apple add-on installer/provider
modules/stdlib/ipaddr/js/*.js           EJSIPAddr generated-bundle input scripts
modules/stdlib/ipaddr/platform/apple/*  EJSIPAddr Apple add-on installer
modules/net/js/*.js                     EJSNet generated-bundle input scripts
modules/net/platform/apple/*            EJSNet Apple add-on installer/provider
modules/xhr/js/*.js                     XHR generated-bundle input scripts
modules/xhr/platform/apple/*            XHR Apple add-on installer/provider
modules/ws/js/*.js                      WebSocket generated-bundle input scripts
modules/ws/platform/apple/*             WebSocket Apple add-on installer/provider
modules/buffer/js/*.js                  Buffer generated-bundle input scripts
modules/buffer/platform/apple/*         Buffer Apple add-on installer
modules/kv/js/*.js                      KV and storage generated-bundle input scripts
modules/kv/platform/apple/*             KV Apple add-on installer/provider
modules/sqlite/js/*.js                  SQLite generated-bundle input scripts
modules/sqlite/platform/apple/*         SQLite Apple add-on installer/provider
modules/path/js/*.js                    Path generated-bundle input scripts
modules/path/platform/apple/*           Path Apple add-on installer
modules/worker/js/*.js                  Worker parent/child generated-bundle input scripts
modules/worker/platform/apple/*         Worker Apple add-on installer/provider
tests/core/*                            Core tests and fake host
tests/apple/*                           Apple platform facade tests
tests/wintertc/apple/*                  WinterTC Apple add-on tests
tests/fs/apple/*                        EJSFS Apple add-on tests
tests/buffer/apple/*                    Buffer Apple add-on tests
tests/kv/apple/*                        KV and storage Apple add-on tests
tests/sqlite/apple/*                    SQLite Apple add-on tests
tests/path/apple/*                      Path Apple add-on tests
tests/worker/apple/*                    Worker Apple add-on tests
tests/net/apple/*                       EJSNet Apple add-on tests
tests/js/network_js_test.js             Network JS helper regression test
tests/js/worker_js_test.js              Worker JS wrapper regression test
tests/ejspkg/converter_test.js          Converter regression tests
tools/ejs-pkg-convert/*                 Offline npm-to-ejspkg converter
sample/*                                C and Apple sample programs
```

## 3. Core Runtime

The public runtime ABI is `core/include/ejs_runtime.h`.

Main public types:

- `EJSCoreRuntime`: opaque runtime handle.
- `EJSCoreContext`: opaque JS execution context handle.
- `EJSCoreError`: opaque error object.
- `EJSCoreRuntimeConfig`: runtime creation config.
- `EJSCoreEvalOptions`: ES module evaluation config.
- `EJSCoreModuleSource`: context-scoped, already-audited ES module source table
  entry used by the generic loader.
- `EJSCoreResult`: synchronous API result with optional owned error.

Main public entries:

- `ejs_runtime_create`
- `ejs_runtime_destroy_with_completion`
- `ejs_runtime_destroy`
- `ejs_context_create`
- `ejs_context_destroy`
- `ejs_context_register_host`
- `ejs_context_register_module_sources`
- `ejs_eval_script`
- `ejs_eval_module`
- `ejs_request_interrupt`
- `ejs_error_*` accessors and `ejs_error_destroy`

Public structs use `abi_version` and `struct_size` validation before the runtime
reads extension fields. Public headers do not expose QuickJS-ng, libuv,
pthread, Objective-C, or platform SDK types.

The generic ES module loader is source-table based. Hosts must read packages,
verify hashes, check approval, and build a bounded `EJSCoreModuleSource` array
before calling `ejs_context_register_module_sources(...)`. The runtime then
deep-copies those sources into the context. QuickJS loader callbacks only
normalize specifiers and compile registered in-memory sources; they do not scan
directories, touch the file system, access the network, parse npm metadata, or
call native providers. Registered sources are context-scoped, and duplicate
specifiers replace the previous source-table entry for that context. Already
linked modules remain in the JavaScript engine module cache and are not
retroactively invalidated.

`ejs_eval_module(...)` uses the registered table for static imports. The
QuickJS-ng backend currently covers relative import normalization, module cache
reuse, circular dependency linking, `import.meta.url`, and diagnostics for
unresolved or syntactically invalid registered modules.

Lifecycle contract for platform integrators:

- once runtime destroy starts (`ejs_runtime_destroy*`), all context handles from
  that runtime become invalid immediately.
- after runtime destroy starts, platform code must not call `ejs_context_destroy`
  or any other context API for those handles.
- runtime destroy must be serialized per runtime by the platform facade. Do not
  depend on concurrent destroy calls as a stable ABI behavior.

## 4. Native Host ABI

The native host ABI is `core/include/ejs_native_api.h`. QuickJS-ng contexts get
this global binding:

```js
globalThis.__ejs_native__ = {
  invoke(module_id, method_id, payload, transfer_buffer),
  invokeSync(module_id, method_id, payload, transfer_buffer),
  timers: {
    create(delay_ms, repeat_ms, callback),
    destroy(timer_id)
  },
  events: {
    setPromiseRejectionTracker(callback),
    setExceptionReporter(callback)
  }
}
```

`invoke` is the general asynchronous bridge. It returns a Promise and routes to
`EJSCoreHostInvokeAPI.invoke`. The host must return an
`EJSCoreHostOperation`; completion can arrive later from any thread and is
marshalled back to the owner thread.

`invokeSync` is for bounded synchronous capabilities only, such as clock and
secure random. It routes to `EJSCoreHostSyncInvokeAPI.invoke_sync`, returns an
ArrayBuffer, and must not be used for network, file, or unbounded work.

The key lifecycle contracts are:

- `EJSCoreByteView` is borrowed.
- `EJSCoreByteBuffer` owns data only through its destroy callbacks.
- `EJSCoreUserData` supports retained and borrowed/static host data.
- registered host APIs are copied into core and retained by pending operations.
- replacing or unregistering the current host does not invalidate already issued
  pending invokes.

## 5. Owner-Thread Model

`core/src/ejs_runtime.c` routes public API calls through `EJSRuntimeLoop`.
QuickJS objects are created, evaluated, drained, and destroyed on the loop
owner thread.

The libuv backend:

- creates a private `uv_loop_t` on a dedicated owner thread,
- uses an async handle for cross-thread wakeup,
- supports synchronous and asynchronous task posting,
- uses prepare/check hooks to run pending Promise jobs,
- owns runtime timers used by `__ejs_native__.timers`.

The stub loop backend exists for build and ABI validation. It is not a real
async runtime backend.

Runtime destroy first marks the runtime invalid, requests interrupt, then
performs terminal shutdown on the owner-thread path. Context destroy on the
owner callback stack is deferred until it can safely release engine state.

## 6. Engine Backends

The selected engine backend is controlled by `EJS_ENGINE`:

- `stub`: buildable backend that rejects JS evaluation with unsupported errors.
- `quickjs-ng`: full backend that creates QuickJS runtimes/contexts, evaluates
  scripts/modules, injects `__ejs_native__`, handles timers, maps JS exceptions
  to `EJSCoreError`, and dispatches Promise rejection/exception events.

The selected loop backend is controlled by `EJS_RUNTIME_LOOP`:

- `stub`: synchronous compile/test backend.
- `libuv`: real owner-thread backend.

## 7. Apple Platform Facade

The implemented platform package is `platform/apple`.

Public Objective-C surface:

- `EJSRuntime`
- `EJSRuntimeConfiguration`
- `EJSContextConfiguration`
- `EJSContext`
- `EJSProvider`
- `EJSProviderResponder`
- `EJSImmediateOperation`
- `EJSBlockOperation`

`EJSRuntime` owns one `EJSCoreRuntime`. It creates `EJSContext` objects with
stable `contextID` values and prevents duplicate in-flight context IDs. Runtime
configuration can provide string `contextDefaults`, and per-context
`EJSContextConfiguration.values` shallowly override those defaults. The merged
configuration snapshot is read-only from `EJSContext` through
`configurationValueForKey:`.

`EJSContext` owns one `EJSCoreContext`, registers one `EJSCoreHostAPI`, and
dispatches `module_id` to Objective-C providers. Provider calls receive
`methodID`, payload data, transfer-buffer data, the platform context, and a
responder. Optional sync providers implement
`invokeSyncMethod:payload:transferBuffer:context:error:`.

The facade currently handles:

- script and module evaluation,
- provider registration, replacement, and unregister,
- provider snapshotting for pending invokes,
- async responder completion,
- sync invoke result copying,
- context and runtime invalidation,
- active core-call accounting during invalidation,
- provider error mapping into core host errors,
- context configuration inheritance, override, and snapshot lookup.

Apple framework packaging, Swift overlay, iOS/macOS-specific default provider
sets, and Android platform support are not implemented in the current source
tree.

TODO: add a runtime-level provider registry or default-provider installer for
providers that are process/runtime scoped and safe to share across contexts.
Registration should still materialize as context-level provider snapshots during
context creation so per-context sandboxing, tenant isolation, invalidation, and
pending invoke semantics remain explicit.

## 8. EJSFS Package

`modules/fs` is an optional package. Consumers link `ejs_fs_apple`, set a
namespaced `ejs.fs` JSON policy on the context configuration, and call
`EJSFileSystemInstallIntoContext(...)` explicitly. Root `platform/apple` does
not import EJSFS headers and does not parse file-system policy.

The installer reads `EJSFileSystemConfigurationKey` from
`[context configurationValueForKey:]`, parses the JSON once, registers the
`ejs.fs` provider, and evaluates the bundled JavaScript wrapper.

Current JavaScript surface:

```js
await EJSFS.promises.readFile(path, options);
await EJSFS.promises.writeFile(path, data, options);
await EJSFS.promises.stat(path, options);
await EJSFS.promises.lstat(path, options);
await EJSFS.promises.exists(path, options);
await EJSFS.promises.access(path, options);
const file = await EJSFS.promises.open(path, flags, mode);
await file.read(options);
await file.write(data, options);
await file.truncate(length);
await file.datasync();
await file.sync();
await file.close();
await EJSFS.promises.readdir(path, options);
await EJSFS.promises.mkdir(path, options);
await EJSFS.promises.copyFile(srcPath, destPath, options);
await EJSFS.promises.readLink(path, options);
await EJSFS.promises.link(existingPath, newPath, options);
await EJSFS.promises.symlink(target, path, options);
await EJSFS.promises.statFs(path, options);
await EJSFS.promises.makeTempDir(prefix, options);
await EJSFS.promises.makeTempFile(prefix, options);
await EJSFS.promises.chmod(path, mode, options);
await EJSFS.promises.chown(path, uid, gid, options);
await EJSFS.promises.lchown(path, uid, gid, options);
await EJSFS.promises.utime(path, atime, mtime, options);
await EJSFS.promises.lutime(path, atime, mtime, options);
await EJSFS.promises.rename(oldPath, newPath, options);
await EJSFS.promises.unlink(path, options);
await EJSFS.promises.rm(path, options);
```

Aliases currently installed by the wrapper are `list` for `readdir`,
`createDirectory` for `mkdir`, and `delete`/`remove` for `rm`.

Current Apple provider methods:

- `ejs.fs/readFile`
  - async only
  - payload: JSON with `path` and optional `root`
  - result: raw file bytes returned as an ArrayBuffer to JavaScript
- `ejs.fs/writeFile`
  - async only
  - payload: JSON with `path`, optional `root`, and optional `flag`
  - transfer buffer: raw bytes to write
  - result: `{"ok": true}` from the provider; JS wrapper resolves
    `undefined`
- `ejs.fs/stat` / `ejs.fs/lstat`
  - async only
  - payload: JSON with `path` and optional `root`
  - result: JSON with `dev`, `ino`, `mode`, `nlink`, `uid`, `gid`, `rdev`,
    `size`, `blksize`, `blocks`, `atimeMs`, `mtimeMs`, `ctimeMs`,
    `birthtimeMs`, and `type`; JS wrapper converts this into a stats object
    with mode-derived predicates
- `ejs.fs/open`
  - async only
  - payload: JSON with `path`, optional `root`, `flags`, and `mode`
  - result: JSON with a provider-owned file handle id
- `ejs.fs/fileHandleRead` / `fileHandleWrite` / `fileHandleTruncate` /
  `fileHandleDatasync` / `fileHandleSync` / `fileHandleClose`
  - async only
  - payload: JSON with `handle` plus operation-specific fields such as
    `length` and `position`
  - transfer buffer: raw bytes for `fileHandleWrite`
  - result: raw bytes for reads, `{"bytesWritten": n}` for writes, or
    `{"ok": true}` for metadata/close operations
- `ejs.fs/exists`
  - async only
  - payload: JSON with `path` and optional `root`
  - result: JSON with boolean `exists`
- `ejs.fs/access`
  - async only
  - payload: JSON with `path`, optional `root`, and optional `mode`
  - result: `{"ok": true}` from the provider; JS wrapper resolves
    `undefined`
- `ejs.fs/readdir`
  - async only
  - payload: JSON with `path` and optional `root`
  - result: JSON with sorted `entries`
- `ejs.fs/mkdir`
  - async only
  - payload: JSON with `path`, optional `root`, and optional `recursive`
  - result: `{"ok": true}` from the provider; JS wrapper resolves
    `undefined`
- `ejs.fs/copyFile`
  - async only
  - payload: JSON with `path`, `newPath`, optional `root`, optional `newRoot`,
    and optional `flag`
  - result: `{"ok": true}` from the provider; JS wrapper resolves
    `undefined`
- `ejs.fs/readLink` / `link` / `symlink`
  - async only
  - payload: JSON with `path` and optional root fields; link uses `newPath`,
    symlink uses `target`
- `ejs.fs/statFs`
  - async only
  - payload: JSON with `path` and optional `root`
  - result: JSON with `type`, `bsize`, `blocks`, `bfree`, `bavail`,
    `files`, and `ffree`
- `ejs.fs/makeTempDir` / `makeTempFile`
  - async only
  - payload: JSON with parent `path`, optional `root`, and `prefix`
  - result: JSON with sandbox-relative created `path`
- `ejs.fs/chmod` / `chown` / `lchown` / `utime` / `lutime`
  - async only
  - payload: JSON with `path`, optional `root`, and operation-specific
    metadata fields
  - restricted host failures return provider errors instead of silent success
- `ejs.fs/rename`
  - async only
  - payload: JSON with `path`, `newPath`, optional `root`, and optional
    `newRoot`
- `ejs.fs/delete`
  - async only
  - payload: JSON with `path`, optional `root`, optional `recursive`, and
    optional `force`

Current supported options:

- `encoding`: `undefined`, `null`, `"utf8"`, or `"utf-8"`.
- `root`: optional configured root name; omitted uses `defaultRoot`.
- `mode`: `"read"`, `"write"`, or `"readwrite"` for `access`.
- `flag`: `"w"` or `"wx"` for writes and `copyFile`.
- `newRoot`: optional `copyFile` and `rename` destination root.
- `recursive`: optional `mkdir` flag for intermediate directory creation, and
  optional `rm`/`delete` flag for directory deletion.
- `force`: optional `rm`/`delete` flag for missing-path success.
- `dir`: optional parent directory for `makeTempDir` and `makeTempFile`.
- `length` and `position`: optional file-handle read/write controls.

Current sandbox behavior:

- JavaScript paths are sandbox-relative by default.
- absolute JavaScript paths, parent traversal, and symlink escape are rejected
  unless the native policy explicitly allows them.
- each root has explicit read/write permissions.
- read and write sizes are capped by policy limits.
- `createIfMissing` creates configured roots at provider-install time.
- file I/O runs on a provider-owned serial dispatch queue.
- stat/lstat/statFs, exists, listing, and read access require read permission.
- write, write access, open-for-write, mkdir, temp path creation, links,
  chmod/chown/utime, copy destinations, rename, and delete require write
  permission.
- copyFile enforces both read and write size limits.
- recursive directory creation is opt-in through `mkdir` options.
- recursive directory delete is opt-in through `rm/delete` options.

## 9. EJSSystem Package

`modules/system` is an optional host-system package. Consumers link
`ejs_system_apple` and call `EJSSystemInstallIntoContext(...)` explicitly.

Current JavaScript surface is Promise-based:

```js
await EJSSystem.cwd();
await EJSSystem.chdir(path);
await EJSSystem.env();
await EJSSystem.getenv(name);
await EJSSystem.setenv(name, value);
await EJSSystem.unsetenv(name);
await EJSSystem.pid();
await EJSSystem.ppid();
await EJSSystem.homeDir();
await EJSSystem.tmpDir();
await EJSSystem.exePath();
await EJSSystem.hostName();
await EJSSystem.platform();
await EJSSystem.arch();
await EJSSystem.uname();
await EJSSystem.uptime();
await EJSSystem.loadAvg();
await EJSSystem.availableParallelism();
await EJSSystem.cpuInfo();
await EJSSystem.networkInterfaces();
await EJSSystem.userInfo();
```

Apple returns `"darwin"` for `platform()`, uses `uname(3)` for arch/uname,
uses `NSProcessInfo` for process and uptime fields, and degrades missing CPU or
network details to stable empty or zero-valued fields.

## 10. EJSFSWatch Package

`modules/fswatch` is an optional file-watch package with its own native policy.
Consumers set `EJSFSWatchConfigurationKey` (`"ejs.fswatch"`) on the context
configuration, link `ejs_fswatch_apple`, and call
`EJSFSWatchInstallIntoContext(...)`.

Current JavaScript surface:

```js
const watcher = await EJSFSWatch.watch(path, (eventType, path) => {
  // eventType is "change" or "rename"
}, options);
await watcher.close();
```

Apple uses `dispatch_source` vnode events. Direct file and directory watches are
supported. Recursive watch requests reject with `EJSProviderErrorCodeUnsupported`
because the current provider does not synthesize recursive watches.

## 11. Stdlib Hashing Package

`modules/stdlib/hashing` is an optional hashing package. Consumers link
`ejs_hashing_apple` and call `EJSHashingInstallIntoContext(...)`.

Current JavaScript surface:

```js
await EJSHashing.digest("sha256", data, { encoding: "hex" });
await EJSHashing.sha256(data);
await EJSHashing.sha512(data, { encoding: "base64" });
```

Inputs may be strings, `ArrayBuffer`, or `ArrayBufferView`. Strings are encoded
as UTF-8. Apple uses CommonCrypto and supports `sha256` and `sha512` with `hex`
or `base64` output.

## 12. Stdlib UUID Package

`modules/stdlib/uuid` is an optional UUID package. Consumers link
`ejs_uuid_apple` and call `EJSUUIDInstallIntoContext(...)`.

Current JavaScript surface:

```js
await EJSUUID.v4();
await EJSUUID.randomUUID();
EJSUUID.validate(value);
```

Apple uses `NSUUID` for v4 generation. Validation is synchronous JavaScript
canonical UUID format checking.

## 13. Stage 3 Network Packages

`modules/stdlib/ipaddr` is an optional pure-JavaScript IP/CIDR package.
Consumers link `ejs_ipaddr_apple` and call `EJSIPAddrInstallIntoContext(...)`.
It registers `globalThis.EJSIPAddr` and does not register a native provider.

```js
EJSIPAddr.isValid("192.0.2.1");
EJSIPAddr.isValidIPv4("127.0.0.1");
EJSIPAddr.isValidIPv6("::1");
EJSIPAddr.isValidCIDR("127.0.0.0/8");
EJSIPAddr.parse("2001:db8::1");
EJSIPAddr.parseCIDR("127.0.0.0/8");
EJSIPAddr.contains("127.0.0.0/8", "127.0.0.1");
EJSIPAddr.normalize("2001:0db8:0:0:0:0:0:1");
```

IPv4 parsing is strict dotted decimal. IPv6 parsing supports `::` compression
and embedded IPv4 tail syntax, and rejects zone identifiers. `parseCIDR`
validates prefix ranges and `contains` compares addresses by CIDR prefix.
Object-form CIDRs are accepted only when they match the parsed CIDR shape.

Stage 3 network add-ons are currently split by implementation state:

- `modules/net`: raw DNS/TCP/UDP add-on exposed as `EJSNet`; Apple currently
  implements `lookup(host, { family, all })` with `getaddrinfo`, TCP client
  `connect/read/write/shutdown/close`, TCP server `listen/accept/close`, and
  UDP `bind/send/recv/close` with non-blocking POSIX sockets.
- `modules/xhr`: embedded `XMLHttpRequest` subset (Phase 4C) with async
  `open/send/abort`, request/response headers, readyState/event model,
  `loadstart/progress/load/error/abort/timeout/loadend`, text/arraybuffer/json
  response handling, `ejs.network` fail-closed policy gating, and delegate-side
  early body-limit cancel.
- `modules/ws`: embedded WebSocket client subset (Phase 5A) with async state
  machine/events, text+binary send, close validation, and `ejs.network`
  fail-closed policy gating.

These modules must read the same future `EJSNetworkConfigurationKey` /
`"ejs.network"` policy, fail closed when policy is missing or invalid, and use
asynchronous `__ejs_native__.invoke` only. For `modules/net`, missing policy
installs the add-on but `lookup()` and TCP connect reject with `EPERM`;
malformed policy fails installation. TCP connect additionally requires
`capabilities.tcpConnect: true` and an outbound allow rule matching host, port,
and `tcp`. TCP listen additionally requires `capabilities.tcpListen: true` and
an inbound allow rule matching address, port, and `tcp`; `port: 0` is accepted
for local bind allocation and returns the assigned local port. UDP additionally
requires `capabilities.udp: true`; bind checks inbound `udp` rules, send checks
outbound `udp` rules with explicit remote port constraints, resolved addresses
must pass the second CIDR/literal-IP policy check, and `port: 0` bind results
must pass a second inbound check with the assigned local port. UDP datagrams are
bounded by `limits.maxDatagramBytes`. HTTP and WebSocket I/O are implemented by
`modules/xhr` and `modules/ws`.

## 14. WinterTC Package

`modules/wintertc` is the optional WinterTC package. Consumers link
`ejs_wintertc_apple` and call `EJSWinterTCInstallIntoContext(...)` explicitly.
Root `platform/apple` does not import WinterTC headers and does not install
WinterTC during runtime/context creation.

Current JS bundle inputs:

- `timers.js`
- `events.js`
- `url.js`
- `encoding.js`
- `blob.js`
- `streams.js`
- `fetch.js`
- `crypto.js`
- `performance.js`
- `console.js`
- `bootstrap.js`

The bundle installs `globalThis.WinterTC` metadata and standard-facing globals
including timers, events, URL/URLSearchParams, TextEncoder/TextDecoder,
Blob/File, ReadableStream, Headers/Request/Response/fetch, crypto helpers,
performance, and console.

Current Apple default providers are optional and installed only when
`EJSWinterTCInstallOptions.installDefaultProviders` is `YES`:

- `wintertc.clock`
  - sync method: `now`
  - result: JSON containing `timeOriginEpochMs` and `nowMs`
- `wintertc.crypto`
  - sync method: `getRandomValues`
  - async method: `digest`
  - supported digest algorithms: `SHA-256`, `SHA-384`, `SHA-512`
- `wintertc.console`
  - async method: `write`
- `wintertc.fetch`
  - async methods: `start`, `pull`, `cancel`
  - supported default Apple URL schemes: `data:`, `http:`, `https:`

`wintertc.fetch` response bodies are framed as pull results: `0x01` followed by
chunk bytes, or `0x00` for end-of-stream. The Apple default provider buffers
response bodies before exposing them through this stream framing.

## 15. Buffer Package

`modules/buffer` is an optional pure-JavaScript binary helper package. It does not aim to be a full Node.js `Buffer` compatibility layer. Consumers link `ejs_buffer_apple` and call `EJSBufferInstallIntoContext(...)` explicitly. It evaluates the bundled JS wrapper and exposes `globalThis.EJSBinary`.

Current JavaScript surface:

```js
const bytes = EJSBinary.fromString(str, encoding);
const text = EJSBinary.toString(bytes, encoding);
const decoded64 = EJSBinary.fromBase64(base64Str);
const encoded64 = EJSBinary.toBase64(bytes);
const decodedHex = EJSBinary.fromHex(hexStr);
const encodedHex = EJSBinary.toHex(bytes);
const combined = EJSBinary.concat([bytes1, bytes2]);
const same = EJSBinary.equals(bytes1, bytes2);
const order = EJSBinary.compare(bytes1, bytes2);
```

Supported encodings: `utf8`, `utf-8`, `base64`, `hex`.

## 16. Key-Value Store (KV) Package

`modules/kv` is an optional persistent key-value and storage package. It is not part of WinterTC. Consumers link `ejs_kv_apple`, set a JSON policy on the context configuration, and call `EJSKeyValueStoreInstallIntoContext(...)` explicitly.

The installer reads `EJSKeyValueStoreConfigurationKey` (`"ejs.kv"`) from the context configuration, parses it, registers the `ejs.kv` provider, and evaluates the JavaScript wrappers for both `EJSKV` and `EJSStorage`.

Current JavaScript surface:

```js
await EJSKV.set(key, value, options);
const bytes = await EJSKV.get(key, options);
const hasKey = await EJSKV.has(key, options);
const keys = await EJSKV.keys(options);
await EJSKV.delete(key, options);
await EJSKV.clear(options);

await EJSKV.setJSON(key, obj, options);
const obj = await EJSKV.getJSON(key, options);
```

`get` resolves to `ArrayBuffer` or `null`. `set` accepts `string`, `ArrayBuffer`, or `ArrayBufferView`.
Options: `{ store: "storeName" }` can be used to direct operations to a specific configured store.

Current Apple provider methods:
- `ejs.kv/get` (payload: store, key; result: raw bytes)
- `ejs.kv/set` (payload: store, key; transfer buffer: bytes; result: `{"ok": true}`)
- `ejs.kv/has` (payload: store, key; result: `{"exists": bool}`)
- `ejs.kv/keys` (payload: store; result: `{"keys": array}`)
- `ejs.kv/delete` (payload: store, key; result: `{"deleted": bool}`)
- `ejs.kv/clear` (payload: store; result: `{"ok": true}`)

Policy Schema (stored under `"ejs.kv"` in configuration):
```json
{
  "version": 1,
  "defaultStore": "default",
  "stores": {
    "storeName": {
      "path": "absolute path",
      "permissions": ["read", "write"],
      "createIfMissing": true
    }
  },
  "limits": {
    "maxKeyBytes": 512,
    "maxValueBytes": 1048576,
    "maxKeysPerList": 1000
  }
}
```

The Apple backend stores each configured store in `<store.path>/kv.sqlite3`
using SQLite WAL mode. The schema is
`kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL)`.
SQL statements use prepared statements and bound values. The provider dispatch
queue is concurrent, but operations are still serialized per store path so
different stores do not block each other behind one provider-wide queue. There
is no manifest compatibility path because this backend has not shipped yet.

`EJSStorage` is a pure JavaScript facade bundled by `modules/kv`. It has no separate native provider, install entrypoint, or target.

Current JavaScript surface:

```js
await EJSStorage.local.setItem(key, value);
const val = await EJSStorage.local.getItem(key);
const keyName = await EJSStorage.local.key(index);
const count = await EJSStorage.local.length();
await EJSStorage.local.removeItem(key);
await EJSStorage.local.clear();

await EJSStorage.json.set(key, obj);
const obj = await EJSStorage.json.get(key);
await EJSStorage.json.remove(key);
```

All operations are asynchronous because they delegate to `EJSKV`.

## 17. SQLite Package

`modules/sqlite` is an optional native-backed SQLite package. It is not part of
WinterTC and is not installed by root `platform/*`. Consumers link
`ejs_sqlite_apple`, set a JSON policy on the context configuration, and call
`EJSSQLiteInstallIntoContext(...)` explicitly.

The installer reads `EJSSQLiteConfigurationKey` (`"ejs.sqlite"`) from the
context configuration, parses named database policy, registers the `ejs.sqlite`
provider, and evaluates the JavaScript wrapper for `EJSSQLite`.

Current JavaScript surface:

```js
const db = await EJSSQLite.open(name, options);
await db.execute(sql, params);
const rows = await db.query(sql, params);
await db.transaction(async (tx) => {
  await tx.execute(sql, params);
});
await db.close();
```

Database names are policy names, not JavaScript file paths. The Apple provider
uses SQLite parameter binding for params and a provider-owned serial queue for
operations. Params currently support `null`, booleans, finite numbers, and
strings. Query rows are JSON-compatible objects keyed by column name; BLOB
columns are represented as `{ "type": "blob", "base64": "..." }` and checked
against `maxBlobBytes`. New operations after `close()` reject.

## 18. Path Package

`modules/path` is an optional pure-JavaScript POSIX path helper package. It does not access the file system. Consumers link `ejs_path_apple` and call `EJSPathInstallIntoContext(...)` explicitly. It registers `globalThis.EJSPath`.

Current JavaScript surface:

```js
EJSPath.posix.normalize(path);
EJSPath.posix.join(...paths);
EJSPath.posix.dirname(path);
EJSPath.posix.basename(path, ext);
EJSPath.posix.extname(path);
EJSPath.posix.isAbsolute(path);
EJSPath.posix.relative(from, to);
```

Only POSIX string semantics are supported. There are no Windows or URL modes.

## 19. JS-facing Type Declarations

TODO: add TypeScript declaration files for every public JavaScript-facing
surface, not only WinterTC. The declarations should act like C headers for JS
IDE completion and static checking, while staying narrower than browser
`lib.dom.d.ts` so unsupported DOM/browser APIs are not advertised.

Initial declaration ownership:

- `modules/wintertc/types/index.d.ts`: WinterTC-installed globals such as
  `WinterTC`, timers, events, URL/URLSearchParams, encoding, Blob/File,
  ReadableStream, Headers/Request/Response/fetch, crypto, performance, and
  console.
- `modules/fs/types/index.d.ts`: `EJSFS.promises` file, metadata, handles,
  links, temp paths, access, directory, copy, rename, and delete operations.
- `modules/system/types/index.d.ts`: `EJSSystem` host process, env, machine,
  network, and user metadata operations.
- `modules/fswatch/types/index.d.ts`: `EJSFSWatch.watch` watcher and event
  declarations.
- `modules/stdlib/hashing/types/index.d.ts`: `EJSHashing` digest helpers.
- `modules/stdlib/uuid/types/index.d.ts`: `EJSUUID` generation and validation.
- `modules/stdlib/ipaddr/types/index.d.ts`: `EJSIPAddr` IP/CIDR helpers.
- `modules/net/types/index.d.ts`: `EJSNet.lookup` and network error contracts.
- `modules/xhr/types/index.d.ts`: XHR constructor/state/event and diagnostics
  declarations for Phase 4C.
- `modules/ws/types/index.d.ts`: WebSocket constructor/state/event/error and
  diagnostics declarations for Phase 5A.
- `modules/buffer/types/index.d.ts`: `EJSBinary` type declarations.
- `modules/kv/types/index.d.ts`: `EJSKV` and `EJSStorage` type declarations.
- `modules/sqlite/types/index.d.ts`: `EJSSQLite` type declarations.
- `modules/path/types/index.d.ts`: `EJSPath` type declarations.
- `core/types/ejs-native-internal.d.ts`: optional internal-only declarations
  for `__ejs_native__.invoke`, `invokeSync`, timers, and events. This should be
  for package authors and tests, not the stable application SDK surface.
- Future JS-facing optional packages should add their own module-local
  `types/index.d.ts` next to their JS wrapper and README.

## 20. Build Targets

Root CMake always adds `core`, `platform`, `modules/wintertc`, `modules/fs`,
`modules/system`, `modules/fswatch`, `modules/path`, `modules/buffer`,
`modules/kv`, `modules/sqlite`, `modules/net`, `modules/xhr`, `modules/ws`,
`modules/stdlib/hashing`, `modules/stdlib/uuid`, `modules/stdlib/ipaddr`,
`sample`, and `tools`. `tests` is added only when `BUILD_TESTING=ON`.

Important targets:

- `ejs_core`
- `ejs_sample`
- `ejs_core_test`
- `ejs_regression_smoke`
- `ejs_phase1_modules_js_test` (CTest Node-based JS wrapper test)
- `ejs_ejspkg_converter_test` (CTest Node-based offline converter test)
- `ejs_apple_platform`
- `ejs_apple_platform_test`
- `ejs_fs_apple`
- `ejs_fs_apple_test`
- `ejs_system_apple`
- `ejs_system_apple_test`
- `ejs_fswatch_apple`
- `ejs_fswatch_apple_test`
- `ejs_net_apple`
- `ejs_net_apple_test`
- `ejs_hashing_apple`
- `ejs_uuid_apple`
- `ejs_ipaddr_apple`
- `ejs_stdlib_apple_test`
- `ejs_wintertc_apple`
- `ejs_wintertc_apple_test`
- `ejs_buffer_apple`
- `ejs_buffer_apple_test`
- `ejs_kv_apple`
- `ejs_kv_apple_test`
- `ejs_sqlite_apple`
- `ejs_sqlite_apple_test`
- `ejs_path_apple`
- `ejs_path_apple_test`
- `ejs_apple_sample`

Typical full backend configuration:

```sh
cmake -S . -B build -DEJS_ENGINE=quickjs-ng -DEJS_RUNTIME_LOOP=libuv -DEJS_TEST=ON
cmake --build build --target ejs_core_test ejs_regression_smoke ejs_apple_platform_test ejs_wintertc_apple_test ejs_fs_apple_test ejs_system_apple_test ejs_fswatch_apple_test ejs_net_apple_test ejs_stdlib_apple_test ejs_buffer_apple_test ejs_kv_apple_test ejs_sqlite_apple_test ejs_path_apple_test ejs_platform_boundary_check
ctest --test-dir build -R "ejs_phase1_modules_js_test|ejs_network_js_test|ejs_ejspkg_converter_test|ejs_fs_apple_test|ejs_system_apple_test|ejs_fswatch_apple_test|ejs_net_apple_test|ejs_stdlib_apple_test|ejs_platform_boundary_test" --output-on-failure
```

Do not document a test as passing unless it was run in the current verification
pass.

## 21. Testing Scope

Current test areas:

- core lifecycle, ABI validation, host invoke, byte payloads, async completion,
  sync completion, timers, microtasks, cancellation, registered-host lifecycle,
  error handling, and regression smoke cases.
- core source-table module loading, including static imports, relative
  normalization, module cache reuse, circular imports, `import.meta.url`, and
  unresolved/syntax diagnostics.
- offline `.ejspkg` conversion fixtures covering ESM, static CommonJS,
  package exports, dependency resolution, deterministic output, tarball
  integrity, and unsupported npm/Node feature rejection.
- Apple platform provider dispatch, context IDs, provider replacement and
  unregister, payload/transfer bridging, module evaluation, responder fail-fast,
  cancellation, invalidation, sync invoke, error mapping, and context
  configuration inheritance/override/snapshot behavior.
- WinterTC Apple add-on installation, JS globals, URL/events/timers/encoding,
  Blob, Request/Response/Headers body behavior, fetch transfer framing with
  fake provider, default `data:` fetch provider behavior, promise rejection
  events, crypto validation, performance clock, optional default providers,
  console payload sanitization, and digest provider behavior.
- EJSFS Apple add-on installation, missing/invalidated context failures, binary
  reads, UTF-8 reads/writes, typed-array slice writes, stat/lstat/statFs,
  FileHandle read/write/truncate/sync/close, links, temp paths, chmod/utime
  and restricted chown behavior, exists, access, directory listing, directory
  creation, copyFile, rename, unlink, rm/delete/remove, named roots,
  unsupported flag/encoding handling, read-only roots, parent traversal
  rejection, symlink escape rejection, and read/write size limits.
- EJSSystem Apple add-on installation, cwd/chdir success and failure paths, env
  mutation/validation, process IDs, host directories, executable path,
  host/platform/arch/uname, uptime/load average, parallelism, CPU info, network
  interfaces, and user info.
- EJSFSWatch Apple add-on installation, direct file change and rename events,
  close behavior, policy-bounded paths, and explicit recursive-watch rejection.
- Stdlib hashing/UUID/IPAddr Apple add-on installation, SHA-256/SHA-512 digest
  output in hex/base64, unsupported digest options, UUID v4 generation, UUID
  format validation, and IP/CIDR parsing behavior.
- Phase 1 JS wrapper test coverage runs under Node with mocked
  `__ejs_native__.invoke`. It checks wrapper-side validation, native request
  payload shaping, alias behavior, file-handle method dispatch, fswatch event
  dispatch, hashing request encoding, and UUID validation without requiring the
  Apple provider.
- Buffer Apple add-on installation, JavaScript API validation for UTF-8/Base64/Hex encoding and decoding, concat, equals, and compare.
- KV Apple add-on installation, policy parsing, path validation, read/write/delete/keys operations on default and custom stores, key/value/list limit enforcement, multi-store isolation, JSON helpers, SQLite persistence, ignored stale manifest files, concurrent runtime access, and bundled `EJSStorage` facade behavior.
- SQLite Apple add-on installation, policy parsing, opening by configured name, parameter-bound execute/query, transaction commit/rollback, close behavior, unsupported database names, read-only write rejection, BLOB row encoding, and row limits.
- Path Apple add-on installation, posix path utilities (normalize, join, dirname, basename, extname, isAbsolute, relative).
- Network JS helper tests cover `EJSIPAddr` IPv4/IPv6/generic validation,
  normalization, CIDR parsing/validation, CIDR containment, malformed CIDR
  object rejection, `EJSNet.lookup` request shaping, TCP client
  request/read/write/close wrapper behavior, TCP server
  listen/accept/close wrapper behavior, UDP bind/send/recv wrapper validation,
  and `EJSNetworkError` fields including POSIX/resolver diagnostic mapping with
  `nativeDomain/nativeCode`.
- EJSNet Apple add-on tests cover invalid policy install failure, default-deny
  lookup/connect/listen/udp-bind rejection, policy-denied host/port and inbound
  listen/bind port rejection, `port: 0` assigned-port policy recheck, local
  loopback TCP and UDP send/recv, refused connect and DNS resolver failure
  diagnostics, TCP/UDP timeout behavior, and close idempotency with post-close
  `ECANCELLED`.
- XHR tests now include JS mock coverage for constructor/success/header access,
  `arraybuffer`/`json` response types, progress readyState, invalid JSON,
  abort/policy+native error paths, and Apple `ejs_xhr_apple_test` with a local
  HTTP fixture plus streaming body-limit early-abort coverage.
- WebSocket tests now include JS mock coverage for constructor/state/events,
  open/message/binary/close/error/terminal-once behavior and Apple
  `ejs_ws_apple_test` for invalid/default-deny/disabled/system-proxy policy
  paths plus provider request-shaping validation.

## 22. Documentation Rules

Keep persistent documentation narrow:

- repository architecture: `docs/design.md`
- repository usage and verification entry: root `README.md`
- local directory usage: README files next to code
- consumer-facing module guides: module-local documents such as
  `platform/integration_zh.md` and `modules/wintertc/js_api_zh.md`
- completed expansion plans (for example the old `path/buffer/kv/sqlite`
  rollout) must be folded into this document and removed as standalone plan files

Do not preserve intermediate process docs, old review rounds, implementation
plans, or agent coordination notes as durable documentation. If a future task
needs a temporary review or plan artifact, keep it clearly scoped and remove or
fold it into the durable docs after the decision lands.
