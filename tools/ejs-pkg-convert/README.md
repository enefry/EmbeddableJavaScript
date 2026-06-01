# ejs-pkg-convert

`ejs-pkg-convert` is the offline npm-to-`.ejspkg` converter described in
`docs/npm_ejspkg_conversion_plan.md`.

It is a developer/CI tool. It does not run inside the EJS runtime, does not
run `npm install`, does not execute npm lifecycle scripts, and does not grant
host capabilities to converted packages.

## Usage

```sh
node tools/ejs-pkg-convert/bin/ejs-pkg-convert.js \
  --input tests/fixtures/npm/simple-esm \
  --out /tmp/ejs-simple-esm.ejspkg \
  --force
```

Supported MVP inputs:

- local package directory
- `.tgz` npm-style tarball
- optional `package-lock.json` integrity verification for tarball input

The output is an unpacked deterministic `.ejspkg` directory containing:

- `ejs-package.json`
- converted ESM sources under `modules/`
- copied root license files under `licenses/`
- `report.json`

## Default Rejections

The converter rejects these by default:

- npm lifecycle scripts
- native addon markers such as `.node`, `binding.gyp`, and `prebuilds/`
- dynamic `require(...)`
- dynamic `import(...)`
- `eval(...)` and `Function(...)`
- Node builtins such as `fs`, `path`, `process`, `http`, and `node:*`

CommonJS support is intentionally limited to static literal `require(...)`.
Converted CommonJS files are wrapped as ESM modules with a default export and
statically detected named exports.

## Verification

```sh
node --check tools/ejs-pkg-convert/bin/ejs-pkg-convert.js
node --check tools/ejs-pkg-convert/src/cli.js
node --check tools/ejs-pkg-convert/src/converter.js
node tests/ejspkg/converter_test.js
```

To verify a real cheerio conversion, prepare a local package directory that
contains `cheerio` under `node_modules`, then run:

```sh
EJS_CHEERIO_INPUT_DIR=/path/to/local/input \
  node tests/ejspkg/cheerio_conversion_test.js
```
