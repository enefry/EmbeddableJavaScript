# EJSSystem

`modules/system` is an optional host-system package. It is not installed by
root `platform/apple`; consumers link `ejs_system_apple` and call
`EJSSystemInstallIntoContext(...)` explicitly.

## JavaScript API

All operations are Promise-based and are exposed on `globalThis.EJSSystem`:

```js
await EJSSystem.cwd();
await EJSSystem.chdir("/tmp/app-work");

const env = await EJSSystem.env();
const value = await EJSSystem.getenv("NAME");
await EJSSystem.setenv("NAME", "value");
await EJSSystem.unsetenv("NAME");

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

`cpuInfo()` and `networkInterfaces()` degrade field-by-field when the platform
does not expose optional details. Missing CPU speed is reported as `0`; missing
network data returns an empty object.

## Apple Notes

- `platform()` returns `"darwin"`.
- `arch()` and `uname()` come from `uname(3)`.
- `loadAvg()` returns three numbers, falling back to `[0, 0, 0]`.
- `chdir()` mutates process-wide current working directory; embedders should
  install this module only where that behavior is acceptable.

## Verification

```sh
node --check modules/system/js/system.js
cmake --build build --target ejs_system_apple_test
ctest --test-dir build -R ejs_system_apple_test --output-on-failure
```
