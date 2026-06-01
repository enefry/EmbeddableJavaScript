# EJSBinary

`modules/buffer` is an optional pure-JavaScript binary helper package. It does
not aim to be a full Node.js `Buffer` compatibility layer.

Dependency direction:

```text
Application
  -> ejs_buffer_apple
  -> ejs_apple_platform
  -> ejs_core
```

## Apple Installation

```objc
#import "EJSBufferApple.h"

NSError *error = nil;
EJSContext *context = [runtime createContextWithID:@"app://main" error:&error];

if (!EJSBufferInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The installer evaluates the bundled JavaScript wrapper and exposes
`globalThis.EJSBinary`.

## JavaScript API

```js
const bytes = EJSBinary.fromString("hello", "utf8");
const text = EJSBinary.toString(bytes, "utf8");

const decoded64 = EJSBinary.fromBase64("aGVsbG8=");
const encoded64 = EJSBinary.toBase64(decoded64);

const decodedHex = EJSBinary.fromHex("68656c6c6f");
const encodedHex = EJSBinary.toHex(decodedHex);

const combined = EJSBinary.concat([bytes, new Uint8Array([33])]);
const same = EJSBinary.equals(bytes, decoded64);
const order = EJSBinary.compare(bytes, combined);
```

Supported encodings are `utf8`, `utf-8`, `base64`, and `hex`. Decoders return
`Uint8Array`; string conversion methods return JavaScript strings.

## Verification

```sh
node --check modules/buffer/js/buffer.js
cmake --build build --target ejs_buffer_apple_test
./build/tests/ejs_buffer_apple_test
```
