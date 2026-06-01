# WinterTC Tests

WinterTC tests cover the optional package, not root `platform/apple`.

Current implemented target:

```sh
cmake --build build --target ejs_wintertc_apple_test
./build/tests/ejs_wintertc_apple_test
```

The Apple test currently verifies:

- explicit WinterTC bundle installation,
- expected globals for timers, events, URL, encoding, Blob, streams,
  Headers/Request/Response/fetch, crypto, performance, console, and `WinterTC`
  metadata,
- URLSearchParams mutation behavior,
- EventTarget object listeners,
- timer repeat behavior,
- Blob text and UTF-8 encode/decode behavior,
- Request/Response/Headers body behavior,
- fetch request framing with fake `wintertc.fetch` provider,
- default `wintertc.fetch` provider behavior for `data:` URLs,
- `reportError`, `unhandledrejection`, and `rejectionhandled`,
- crypto `getRandomValues` validation and short-provider error handling,
- performance clock through fake `wintertc.clock`,
- optional default Apple providers for random values, UUID, clock, console,
  fetch, and digest,
- install failure after context invalidation.

Full cross-platform WinterTC conformance is not implemented yet.
