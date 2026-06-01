# WinterTC

`modules/wintertc` is the optional WinterTC standard API module. It is not part
of the core runtime and is not installed by root `platform/apple`.

Chinese JavaScript API guide: [js_api_zh.md](js_api_zh.md).

Consumers link the add-on they need and install it explicitly into a platform
context:

```objc
#import "EJSWinterTCApple.h"

NSError *error = nil;
BOOL ok = EJSWinterTCInstallIntoContext(context, &error);
```

## Current Code

`modules/wintertc/js/*.js` is bundled deterministically by
`modules/wintertc/cmake/generate_wintertc_bundle.cmake` into
`ejs_wintertc_js_bundle.h`.

The current bundle installs:

- timers: `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`,
  `queueMicrotask`
- events: `Event`, `CustomEvent`, `ErrorEvent`, `PromiseRejectionEvent`,
  `EventTarget`, `AbortSignal`, `AbortController`, global event handlers, and
  `reportError`
- URL and `URLSearchParams`
- `TextEncoder` and `TextDecoder`
- `Blob` and `File`
- minimal `ReadableStream`
- `Headers`, `Request`, `Response`, and `fetch` backed by a `wintertc.fetch`
  provider
- crypto helpers backed by `wintertc.crypto`
- `performance` backed by `wintertc.clock`
- `console` backed by `wintertc.console`
- `globalThis.WinterTC` metadata

## Apple Add-On

Current Apple add-on files:

- `modules/wintertc/platform/apple/include/EJSWinterTCApple.h`
- `modules/wintertc/platform/apple/src/EJSWinterTCApple.m`

Default Apple providers are optional:

```objc
EJSWinterTCInstallOptions *options = [[EJSWinterTCInstallOptions alloc] init];
options.installDefaultProviders = YES;
BOOL ok = EJSWinterTCInstallIntoContextWithOptions(context, options, &error);
```

When enabled, the add-on registers:

- `wintertc.clock`
- `wintertc.crypto`
- `wintertc.console`
- `wintertc.fetch`

The default `wintertc.fetch` provider supports `data:`, `http:`, and `https:`
requests. It buffers response bodies in native memory and exposes them to JS
through the package's pull-based body stream framing. Tests still use fake
providers for request framing coverage and the default provider for `data:`
URL coverage without external network access.

## Local Verification

```sh
cmake --build build --target ejs_wintertc_apple_test
./build/tests/ejs_wintertc_apple_test
```

The Apple sample also links this add-on explicitly:

```sh
cmake --build build --target ejs_apple_sample
./build/sample/ejs_apple_sample
```
