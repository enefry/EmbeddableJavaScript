# EJSFSWatch

`modules/fswatch` is an optional file-watch package. It is separate from
`modules/fs` so embedders can enable file I/O and file observation
independently.

Consumers set `EJSFSWatchConfigurationKey` (`"ejs.fswatch"`) on the context
configuration, link `ejs_fswatch_apple`, and call
`EJSFSWatchInstallIntoContext(...)`.

## JavaScript API

```js
const watcher = await EJSFSWatch.watch("profile.json", (eventType, path) => {
  // eventType is "change" or "rename"
});

await watcher.close();
```

`watch(path, handler, options)` accepts an optional configured `root`. The
returned watcher has a stable `id`, a `recursive` flag, and `close()`.

## Policy Schema

```json
{
  "version": 1,
  "defaultRoot": "documents",
  "roots": {
    "documents": {
      "path": "/app/Documents/ejs"
    }
  },
  "pathPolicy": {
    "allowAbsolutePath": false,
    "allowParentTraversal": false,
    "allowSymlinkEscape": false
  }
}
```

## Apple Notes

The Apple provider uses `dispatch_source` vnode events. It supports direct
file or directory watches and reports native vnode write/attrib/link events as
`"change"` and delete/rename/revoke events as `"rename"`.

Recursive watching is not implemented by this provider. Passing
`{ recursive: true }` rejects with `EJSProviderErrorCodeUnsupported` so callers
can branch explicitly.

## Verification

```sh
node --check modules/fswatch/js/fswatch.js
cmake --build build --target ejs_fswatch_apple_test
ctest --test-dir build -R ejs_fswatch_apple_test --output-on-failure
```
