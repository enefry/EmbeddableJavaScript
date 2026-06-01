# EJSUUID

`modules/stdlib/uuid` is an optional UUID helper package. It installs
`globalThis.EJSUUID`.

## JavaScript API

```js
const id = await EJSUUID.v4();
const same = await EJSUUID.randomUUID();

EJSUUID.validate(id); // true
EJSUUID.validate("not-a-uuid"); // false
```

`v4()` and `randomUUID()` return RFC 4122 version-4 UUID strings. `validate()`
is synchronous and checks canonical UUID text format.

## Apple Notes

The Apple provider uses `NSUUID` for generation. Validation is done in the
JavaScript wrapper so callers can validate without a native round trip.

## Verification

```sh
node --check modules/stdlib/uuid/js/uuid.js
cmake --build build --target ejs_stdlib_apple_test
ctest --test-dir build -R ejs_stdlib_apple_test --output-on-failure
```
