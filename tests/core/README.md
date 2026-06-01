# Core Tests

Core tests cover the minimal runtime kernel and native ABI.

Current coverage includes:

- runtime/context create, destroy, invalid-handle, and ABI validation paths,
- script/module evaluation, JS exception propagation, and stack extraction,
- `__ejs_native__.invoke` argument validation, binary payloads, async
  resolve/reject, duplicate completion idempotency, and inline host completion,
- `__ejs_native__.invokeSync` host dispatch and result/error framing,
- host registration lifecycle, host snapshot retain/release, and pending
  operation cancel/release races,
- libuv timer and microtask integration,
- Promise rejection and exception reporter plumbing,
- regression smoke for reentrant context destroy and started/stopped loop
  teardown.

Primary targets:

```sh
cmake --build build --target ejs_core_test ejs_regression_smoke
./build/tests/ejs_core_test
./build/tests/ejs_regression_smoke
```

Apple platform tests live under `tests/apple`. WinterTC add-on tests live under
`tests/wintertc`.
