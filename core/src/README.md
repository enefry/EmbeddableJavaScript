# Core Source

`core/src` implements the runtime behind the public C ABI in
`core/include/ejs_runtime.h` and `core/include/ejs_native_api.h`.

## Files

- `ejs_runtime.c`: public runtime/context API routing, owner-thread lifecycle,
  host registration, evaluation dispatch, and destroy state machine.
- `ejs_native_api.c`: host API validation, `EJSCoreHostOperation`, byte buffer
  helpers, secure wipe, and native operation state transitions.
- `ejs_error.c`: `EJSCoreError` allocation, copying, accessors, and destroy.
- `ejs_abi.c`: ABI metadata and reserved-field validation for public structs.
- `ejs_engine.h`: private JS engine backend interface.
- `ejs_engine_quickjs_ng.c`: QuickJS-ng backend, `__ejs_native__` bindings,
  timers, Promise rejection/exception reporting, script/module evaluation, and
  JS error extraction.
- `ejs_engine_stub.c`: no-engine backend for compile and ABI validation.
- `ejs_runtime_loop.h`: private runtime loop backend interface.
- `ejs_runtime_loop_libuv.c`: libuv owner-thread loop, task queue, wakeup,
  prepare/check job drain, and timer backend.
- `ejs_runtime_loop_stub.c`: synchronous stub loop backend.
- `ejs_runtime_internal.h`: private runtime/context structs and lifecycle
  helpers.
- `ejs_util.h`: small internal helpers.

## Invariants

- QuickJS runtime and context access happens on the runtime loop owner thread.
- Public ABI structs are validated before extension fields are read.
- Host APIs are copied into core and retained while pending operations need
  them.
- Async host completion may arrive from any thread and is posted back to the
  owner thread before touching JS state.
- `invokeSync` is only for bounded synchronous provider work.
- Context destroy on the owner callback stack is deferred until the engine can
  safely release state.
- `EJS_TEST` gates white-box injection symbols and must stay off for production
  builds.

## Backends

`EJS_ENGINE` selects `stub` or `quickjs-ng`.

`EJS_RUNTIME_LOOP` selects `stub` or `libuv`.

The full runtime path is `quickjs-ng + libuv`. Stub backends are useful for
compile and ABI checks but do not represent a real async runtime.
