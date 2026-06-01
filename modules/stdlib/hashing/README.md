# EJSHashing

`modules/stdlib/hashing` is an optional small hashing package. It installs
`globalThis.EJSHashing` and keeps hashing outside `core` and root
`platform/*`.

## JavaScript API

```js
const hex = await EJSHashing.sha256("abc");
const base64 = await EJSHashing.sha512(new Uint8Array([1, 2, 3]), {
  encoding: "base64"
});
const digest = await EJSHashing.digest("sha256", bytes, { encoding: "hex" });
```

Supported algorithms are `sha256` and `sha512`. Supported output encodings are
`hex` and `base64`; `hex` is the default.

Input data may be a string, `ArrayBuffer`, or `ArrayBufferView`. Strings are
encoded as UTF-8 by the JavaScript wrapper before dispatching to the provider.

## Apple Notes

The Apple provider uses CommonCrypto and returns only encoded digest strings.
It does not expose incremental hash state yet.

## Verification

```sh
node --check modules/stdlib/hashing/js/hashing.js
cmake --build build --target ejs_stdlib_apple_test
ctest --test-dir build -R ejs_stdlib_apple_test --output-on-failure
```
