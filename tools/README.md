# Tools

This directory contains developer and CI helper tools.

## EJS Package Converter

`tools/ejs-pkg-convert` contains the offline npm-to-`.ejspkg` converter.
It is a developer/CI tool, not runtime functionality: it reads a local package
directory or npm-style `.tgz`, rejects unsupported package features, and writes
an unpacked deterministic `.ejspkg` directory with `ejs-package.json`,
converted ESM sources, copied licenses, and `report.json`.

Usage:

```sh
node tools/ejs-pkg-convert/bin/ejs-pkg-convert.js \
  --input tests/fixtures/npm/simple-esm \
  --out /tmp/ejs-simple-esm.ejspkg \
  --force
```

Verification:

```sh
node tests/ejspkg/converter_test.js
```

## Apple CLI

Apple hosts build one command-line tool from `tools/apple`:

- `ejs_apple_cli` runs a JavaScript file in the Apple EJS runtime.

The CLI installs WinterTC defaults, file-system helpers, and process helpers:

- `process.argv`
- `process.pid`
- `process.cwd()`
- `process.env(name)` / `process.env()`
- `process.stdout.write(value)`
- `process.stderr.write(value)`
- `process.exit(code, message?)`
- WinterTC globals including `fetch`, `crypto`, `URL`, `TextEncoder`,
  `TextDecoder`, `setTimeout`, `performance`, and `WinterTC`
- default `fetch` support for `data:`, `http:`, and `https:` URLs
- `EJS.WinterTC` / `EJS.winterTC` aliases for the WinterTC metadata object
- `EJSFS.promises.readFile(path, options)`
- `EJSFS.promises.writeFile(path, data, options)`
- `EJSFS.promises.stat(path, options)`
- `EJSFS.promises.exists(path, options)`
- `EJSFS.promises.access(path, options)`
- `EJSFS.promises.readdir(path, options)` / `list(path, options)`
- `EJSFS.promises.mkdir(path, options)` / `createDirectory(path, options)`
- `EJSFS.promises.copyFile(srcPath, destPath, options)`
- `EJSFS.promises.rename(oldPath, newPath, options)`
- `EJSFS.promises.unlink(path, options)`
- `EJSFS.promises.rm(path, options)` / `delete(path, options)`
- `EJS.fs` / `fs` aliases for the same file-system object

`process.stdout.write` / `process.stderr.write` accept `string`,
`ArrayBuffer`, or `ArrayBufferView`. Binary inputs are written as raw bytes.

## Apple Distribution Artifacts

`tools/apple/package_apple_distribution.sh` builds Apple distribution artifacts
that other projects can consume directly:

- `dist/apple/EJS.xcframework` (or `EJS_APPLE_PRODUCT_NAME`)
- `dist/apple/EJS.podspec`
- `dist/apple/Package.swift`

Run:

```sh
EJS_APPLE_PRODUCT_NAME=EJS \
  ./tools/apple/package_apple_distribution.sh
```

You can control the produced pod source and metadata via:

- `EJS_APPLE_PODSPEC_SOURCE_URL`
- `EJS_APPLE_PODSPEC_HOMEPAGE`
- `EJS_APPLE_PODSPEC_AUTHOR`
- `EJS_APPLE_PODSPEC_AUTHOR_EMAIL`

Usage:

```sh
cmake --build build_xcode --target ejs_apple_cli --config Debug
./build_xcode/tools/apple/Debug/ejs_apple_cli path/to/script.js arg1 arg2
./build_xcode/tools/apple/Debug/ejs_apple_cli tools/apple/examples/repo_report.js
./build_xcode/tools/apple/Debug/ejs_apple_cli --timeout 15 tools/apple/examples/api_check.js
```

The CLI file-system root named `cwd` points at the process working directory,
and root `tmp` points at the platform temporary directory. File-system paths are
relative to a configured root; absolute paths, parent traversal, and symlink
escapes are rejected.

`tools/apple/examples/api_check.js` also performs a real HTTPS fetch against
`https://api.ipify.org/?format=json`, so use a larger timeout when the network
is slow.
