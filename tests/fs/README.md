# EJSFS Tests

`tests/fs` covers the optional EJSFS package. These tests are separate from
root platform tests and WinterTC tests because EJSFS owns file-system policy,
provider behavior, and JavaScript wrapper semantics.

## Apple Coverage

`apple/ejs_fs_apple_test.m` verifies:

- EJSFS installation from `EJSFileSystemConfigurationKey`.
- missing configuration fails install.
- invalidated contexts reject install.
- `EJSFS.promises.readFile` returns bytes as an ArrayBuffer.
- UTF-8 read/write string behavior.
- typed-array slice writes preserve the selected view range.
- `stat` returns file metadata with stats helper methods.
- `exists` returns true and false for present and missing sandbox paths.
- `access` succeeds for readable paths and fails for missing paths.
- `readdir` and `list` return sorted directory entries.
- `mkdir` and `createDirectory` create directories, including opt-in
  intermediate directories.
- non-recursive `mkdir` fails when the parent directory is missing.
- `copyFile` copies bytes, supports named destination roots, and honors
  exclusive `flag: "wx"`.
- `rename` moves paths inside configured roots.
- `unlink` deletes files.
- `rm`/`delete` supports force and explicit recursive directory deletion.
- named root selection.
- unsupported raw-provider encoding and unsupported write flags.
- read-only roots reject writes.
- read-only roots reject write access checks.
- read-only roots reject copy destinations.
- read-only roots reject directory creation.
- read-only roots reject deletes.
- parent traversal is rejected.
- symlink escape is rejected.
- max read/write size limits are enforced.

## Verification

```sh
cmake --build build --target ejs_fs_apple_test
./build/tests/ejs_fs_apple_test
```
