# EJSFS

`modules/fs` is an optional file-system package. It is not part of WinterTC and
is not auto-installed by root `platform/apple`.

Dependency direction:

```text
Application
  -> ejs_fs_apple
  -> ejs_apple_platform
  -> ejs_core
```

## Apple Installation

Consumers configure policy through the generic context configuration channel and
then install EJSFS into that context:

```objc
#import "EJSFileSystemApple.h"

NSError *error = nil;
EJSRuntimeConfiguration *runtimeConfig = [[EJSRuntimeConfiguration alloc] init];
runtimeConfig.contextDefaults = @{
  EJSFileSystemConfigurationKey: fsConfigJSON
};

EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:runtimeConfig];
EJSContext *context = [runtime createContextWithID:@"app://main" error:&error];

if (!EJSFileSystemInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The installer reads `EJSFileSystemConfigurationKey`, parses the JSON once,
registers the `ejs.fs` provider, and evaluates the bundled JavaScript wrapper.

## JavaScript API

```js
const bytes = await EJSFS.promises.readFile("profile.bin");
const text = await EJSFS.promises.readFile("profile.json", "utf8");

await EJSFS.promises.writeFile("profile.json", "{\"ok\":true}", "utf8");
await EJSFS.promises.writeFile("profile.bin", new Uint8Array([1, 2, 3]));

const entries = await EJSFS.promises.readdir("profiles");
const info = await EJSFS.promises.stat("profiles");
const linkInfo = await EJSFS.promises.lstat("profile-link");
const hasProfile = await EJSFS.promises.exists("profile.json");
await EJSFS.promises.access("profile.json", { mode: "read" });
await EJSFS.promises.mkdir("profiles/new", { recursive: true });
await EJSFS.promises.copyFile("profile.json", "profile-copy.json");
await EJSFS.promises.rename("profile.tmp", "profile.json");
const handle = await EJSFS.promises.open("profile.json", "r+");
await handle.write("{\"ok\":true}", "utf8");
await handle.truncate(11);
await handle.datasync();
await handle.sync();
await handle.close();
await EJSFS.promises.symlink("profile.json", "profile-link");
await EJSFS.promises.readLink("profile-link");
await EJSFS.promises.link("profile.json", "profile-hardlink.json");
await EJSFS.promises.statFs(".");
const tempDir = await EJSFS.promises.makeTempDir("profile-");
const tempFile = await EJSFS.promises.makeTempFile("profile-", { dir: tempDir });
await EJSFS.promises.chmod(tempFile, 0o600);
await EJSFS.promises.utime(tempFile, Date.now(), Date.now());
await EJSFS.promises.unlink("old-profile.json");
await EJSFS.promises.rm("old-cache", { recursive: true });
```

Supported first-step options:

- `encoding`: `undefined`, `null`, `"utf8"`, or `"utf-8"`.
- `root`: optional configured root name; omitted uses `defaultRoot`.
- `mode`: `"read"`, `"write"`, or `"readwrite"` for `access`.
- `flag`: `"w"` or `"wx"` for writes and `copyFile`.
- `newRoot`: optional destination root for `copyFile` and `rename`; omitted
  uses `root` or `defaultRoot`.
- `recursive`: optional `mkdir` flag for intermediate directory creation, and
  optional `rm`/`delete` flag for directory deletion.
- `force`: optional `rm`/`delete` flag for missing-path success.
- `dir`: optional parent directory for `makeTempDir` and `makeTempFile`.
- `position` and `length`: optional `FileHandle.read/write` byte controls.

`readFile` without encoding resolves to an `ArrayBuffer`. `readFile` with UTF-8
encoding resolves to a string. `readdir` resolves to a sorted string array.
`stat` follows symlinks and `lstat` observes the link itself. Both resolve to a
stats object with `dev`, `ino`, `mode`, `nlink`, `uid`, `gid`, `rdev`, `size`,
`blksize`, `blocks`, `atimeMs`, `mtimeMs`, `ctimeMs`, `birthtimeMs`, `type`,
`isFile()`, `isDirectory()`, and `isSymbolicLink()`. Time fields are epoch
milliseconds. `type` is kept as a readability/legacy field; predicates prefer
`mode` when available.

`open` resolves to a `FileHandle` with `read`, `write`, `truncate`,
`datasync`, `sync`, and `close`. `FileHandle.read` resolves to an
`ArrayBuffer`, or to a string when UTF-8 encoding is requested.

`statFs` resolves to `{ type, bsize, blocks, bfree, bavail, files, ffree }`.
`exists` resolves to a boolean. Mutating operations resolve to `undefined`.

Aliases:

- `list(path, options)` is an alias for `readdir`.
- `createDirectory(path, options)` is an alias for `mkdir`.
- `delete(path, options)` is an alias for `rm`.
- `remove(path, options)` is an alias for `rm`.
- `mkdir(path, options)` creates one directory, or intermediate directories
  when `{ recursive: true }` is set.
- `copyFile(srcPath, destPath, options)` copies a file. It overwrites by
  default and rejects an existing destination with `{ flag: "wx" }`.
- `unlink(path, options)` deletes files and symlinks only.
- `rm(path, options)` deletes files and deletes directories only with
  `{ recursive: true }`.
- `datasync()` currently maps to `fsync(2)` on Apple because Darwin does not
  expose a separate `fdatasync(2)` contract.
- `chown` and `lchown` are implemented where the host permits them. Restricted
  platforms return a provider error instead of silently succeeding.

## Policy Schema

The policy is a JSON string stored under `EJSFileSystemConfigurationKey`
(`"ejs.fs"`):

```json
{
  "version": 1,
  "defaultRoot": "documents",
  "roots": {
    "documents": {
      "path": "/app/Documents/ejs",
      "permissions": ["read", "write"],
      "createIfMissing": true
    },
    "cache": {
      "path": "/app/Library/Caches/ejs",
      "permissions": ["read", "write"],
      "createIfMissing": true
    }
  },
  "limits": {
    "maxReadBytes": 8388608,
    "maxWriteBytes": 8388608
  },
  "pathPolicy": {
    "allowAbsolutePath": false,
    "allowParentTraversal": false,
    "allowSymlinkEscape": false
  }
}
```

## Sandbox Behavior

- JavaScript paths are sandbox-relative by default.
- absolute JavaScript paths are rejected unless policy allows them.
- parent traversal is rejected unless policy allows it.
- symlink escape is rejected unless policy allows it.
- each root has explicit read/write permissions.
- read and write sizes are capped by policy limits.
- roots with `createIfMissing` are created during provider installation.
- file I/O runs asynchronously on a provider-owned serial dispatch queue.
- stat, exists, and read access require read permission on the selected root.
- open enforces read and/or write root permissions according to its flags.
- mkdir, temp path creation, chmod/chown/utime, and symlink creation require
  write permission on the selected root.
- copyFile requires read permission on the source root and write permission on
  the destination root.
- rename and delete require write permission on the selected root.
- rename can cross configured roots only when both source and destination roots
  allow writes.

## Verification

```sh
node --check modules/fs/js/fs.js
cmake --build build --target ejs_fs_apple_test
./build/tests/ejs_fs_apple_test
```
