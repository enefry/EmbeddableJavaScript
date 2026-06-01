# Fix Plan From EJSPkg Converter Review

Date: 2026-05-31
Scope: current `codex/ejspkg-converter` worktree diff for `.ejspkg` package installer and cheerio conversion validation.

## RF-001: Preserve strict `exports` target validation while allowing legacy package entry fields

- Status: fixed
- Severity: medium
- Finding: Cheerio conversion exposed that some dependencies use package `module`/`main` fields without a leading `./` (for example `lib/es/index.js`). The current converter patch accepts that, but it also accepts non-`./` targets returned from `exports`, weakening the existing package-boundary validation for export maps.
- Goal: Allow legacy `main`/`module` entry strings without `./`, while still rejecting invalid `exports` targets that do not begin with `./`.
- Minimal change proposal: Teach `targetFromPackageJson` or `resolvePackageEntry` whether the selected target came from `exports`; only legacy fallback fields get normalized with `ensureSafeArchivePath`.
- Regression test proposal: Add a fixture whose `exports` target omits `./` and assert `EJS_CONVERT_UNSUPPORTED_EXPORTS`, while keeping the `module: "lib/index.js"` fixture passing.
- Verification command: `node tests/ejspkg/converter_test.js`
- Evidence:
  - Two independent subagent reviews agreed the fix should validate `exports` targets separately from legacy `module`/`main`.
  - Implemented `exports`-only `./` validation in `targetFromPackageJson`.
  - Added root, conditional, and dependency invalid-exports fixtures.
  - Verified: `node tests/ejspkg/converter_test.js`.
  - Verified cheerio direct package still converts with `--conditions ejs,browser,import,default --allow-scripts-for-audit-only`.

## Final Verification

- `git diff --check`
- `node --check tools/ejs-pkg-convert/src/converter.js`
- `node --check tests/ejspkg/cheerio_conversion_test.js`
- `node tests/ejspkg/converter_test.js`
- `cmake --build build --target ejs_package_cheerio_apple_test ejs_package_apple_test ejs_platform_boundary_check`
- With prepared local cheerio input/package:
  `EJS_CHEERIO_INPUT_DIR=/private/tmp/ejs-cheerio-work/cheerio-root EJS_CHEERIO_EJSPKG_PATH=/private/tmp/ejs-cheerio-work/cheerio-direct.ejspkg ctest --test-dir build -R "ejs_ejspkg_cheerio_conversion_test|ejs_ejspkg_converter_test|ejs_package_cheerio_apple_test|ejs_package_apple_test|ejs_platform_boundary_test" --output-on-failure`
