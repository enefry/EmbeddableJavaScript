'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const fsp = fs.promises;
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawnSync } = require('child_process');

const {
  convertPackage,
  stableStringify,
  verifyIntegrity
} = require('../../tools/ejs-pkg-convert/src/converter');

const repoRoot = path.resolve(__dirname, '..', '..');
const fixturesRoot = path.join(repoRoot, 'tests', 'fixtures', 'npm');
const cliPath = path.join(repoRoot, 'tools', 'ejs-pkg-convert', 'bin', 'ejs-pkg-convert.js');

function sha512Integrity(bytes) {
  return `sha512-${crypto.createHash('sha512').update(bytes).digest('base64')}`;
}

function tarHeader(name, size) {
  const header = Buffer.alloc(512, 0);
  header.write(name, 0, 100, 'utf8');
  header.write('0000644\0', 100, 8, 'ascii');
  header.write('0000000\0', 108, 8, 'ascii');
  header.write('0000000\0', 116, 8, 'ascii');
  header.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
  header.write('00000000000\0', 136, 12, 'ascii');
  header.fill(' ', 148, 156);
  header.write('0', 156, 1, 'ascii');
  header.write('ustar\0', 257, 6, 'ascii');
  header.write('00', 263, 2, 'ascii');
  let checksum = 0;
  for (const byte of header) {
    checksum += byte;
  }
  header.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
  return header;
}

async function createTarballFromDirectory(sourceDir, outFile) {
  const chunks = [];
  async function walk(absDir, relDir) {
    const entries = await fsp.readdir(absDir, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const absPath = path.join(absDir, entry.name);
      const relPath = path.posix.join(relDir, entry.name);
      if (entry.isDirectory()) {
        await walk(absPath, relPath);
        continue;
      }
      if (!entry.isFile()) {
        continue;
      }
      const bytes = await fsp.readFile(absPath);
      const tarName = path.posix.join('package', relPath);
      chunks.push(tarHeader(tarName, bytes.length));
      chunks.push(bytes);
      const padding = (512 - (bytes.length % 512)) % 512;
      if (padding) {
        chunks.push(Buffer.alloc(padding, 0));
      }
    }
  }
  await walk(sourceDir, '');
  chunks.push(Buffer.alloc(1024, 0));
  const tarBytes = Buffer.concat(chunks);
  const tgz = zlib.gzipSync(tarBytes, { mtime: 0 });
  await fsp.writeFile(outFile, tgz);
  return tgz;
}

async function readJson(filePath) {
  return JSON.parse(await fsp.readFile(filePath, 'utf8'));
}

async function withTempDir(fn) {
  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'ejs-converter-test-'));
  try {
    await fn(tmp);
  } finally {
    await fsp.rm(tmp, { recursive: true, force: true });
  }
}

async function assertRejectsCode(fn, code) {
  let thrown = null;
  try {
    await fn();
  } catch (error) {
    thrown = error;
  }
  assert(thrown, `expected ${code} to be thrown`);
  assert.strictEqual(thrown.code, code);
}

async function testSimpleEsm(tmp) {
  const out = path.join(tmp, 'simple-esm.ejspkg');
  const result = await convertPackage({
    input: path.join(fixturesRoot, 'simple-esm'),
    out
  });
  const manifest = await readJson(path.join(out, 'ejs-package.json'));
  const report = await readJson(path.join(out, 'report.json'));
  assert.strictEqual(result.packageId, 'npm:simple-esm@1.0.0');
  assert.strictEqual(manifest.name, 'simple-esm');
  assert.strictEqual(report.summary.status, 'converted');
  assert(Object.keys(manifest.modules).some((url) => url.endsWith('/modules/index.js')));
  const moduleSource = await fsp.readFile(path.join(out, 'modules', 'index.js'), 'utf8');
  assert(moduleSource.includes('ejs-pkg://npm/simple-esm@1.0.0/modules/lib/add.js'));
  assert.strictEqual(manifest.packageSha256, result.packageSha256);
}

async function testSimpleCjs(tmp) {
  const out = path.join(tmp, 'simple-cjs.ejspkg');
  await convertPackage({
    input: path.join(fixturesRoot, 'simple-cjs'),
    out
  });
  const source = await fsp.readFile(path.join(out, 'modules', 'index.cjs'), 'utf8');
  assert(source.includes('const module = { exports };'));
  assert(source.includes('export default __ejs_default;'));
  assert(source.includes('export const answer ='));
  const report = await readJson(path.join(out, 'report.json'));
  assert.strictEqual(report.compatibility.commonJSWrappedModules.length, 1);
}

async function testExportsAndDependencies(tmp) {
  const exportsOut = path.join(tmp, 'exports.ejspkg');
  await convertPackage({
    input: path.join(fixturesRoot, 'package-exports'),
    out: exportsOut
  });
  const exportsManifest = await readJson(path.join(exportsOut, 'ejs-package.json'));
  assert(exportsManifest.entry.endsWith('/modules/src/ejs.js'));

  const depsOut = path.join(tmp, 'with-dependency.ejspkg');
  await convertPackage({
    input: path.join(fixturesRoot, 'with-dependency'),
    out: depsOut
  });
  const depsManifest = await readJson(path.join(depsOut, 'ejs-package.json'));
  assert.strictEqual(depsManifest.dependencies['tiny-dep'].packageId, 'npm:tiny-dep@2.0.0');
  const source = await fsp.readFile(path.join(depsOut, 'modules', 'index.js'), 'utf8');
  assert(source.includes('/modules/node_modules/tiny-dep/index.js'));
}

async function testPackageEntryWithoutDotPrefix(tmp) {
  const out = path.join(tmp, 'entry-no-dot.ejspkg');
  await convertPackage({
    input: path.join(fixturesRoot, 'package-entry-no-dot'),
    out
  });
  const manifest = await readJson(path.join(out, 'ejs-package.json'));
  assert(manifest.entry.endsWith('/modules/lib/index.js'));
  const source = await fsp.readFile(path.join(out, 'modules', 'lib', 'index.js'), 'utf8');
  assert(source.includes('entry-without-dot'));
}

async function testInvalidExportsTargetsRejected(tmp) {
  const cases = [
    'denied-invalid-exports-target',
    'denied-invalid-conditional-exports',
    'denied-invalid-dependency-exports'
  ];
  for (const fixture of cases) {
    await assertRejectsCode(() => convertPackage({
      input: path.join(fixturesRoot, fixture),
      out: path.join(tmp, `${fixture}.ejspkg`)
    }), 'EJS_CONVERT_UNSUPPORTED_EXPORTS');
  }
}

async function testDeterministicOutput(tmp) {
  const first = path.join(tmp, 'first.ejspkg');
  const second = path.join(tmp, 'second.ejspkg');
  const firstResult = await convertPackage({
    input: path.join(fixturesRoot, 'simple-esm'),
    out: first
  });
  const secondResult = await convertPackage({
    input: path.join(fixturesRoot, 'simple-esm'),
    out: second
  });
  assert.strictEqual(firstResult.packageSha256, secondResult.packageSha256);
  assert.strictEqual(
    await fsp.readFile(path.join(first, 'ejs-package.json'), 'utf8'),
    await fsp.readFile(path.join(second, 'ejs-package.json'), 'utf8')
  );
}

async function testRejections(tmp) {
  const cases = [
    ['denied-lifecycle', 'EJS_CONVERT_LIFECYCLE_SCRIPT'],
    ['denied-native', 'EJS_CONVERT_NATIVE_ADDON'],
    ['denied-dynamic-require', 'EJS_CONVERT_DYNAMIC_REQUIRE'],
    ['denied-node-builtin', 'EJS_CONVERT_UNSUPPORTED_BUILTIN']
  ];
  for (const [fixture, code] of cases) {
    await assertRejectsCode(() => convertPackage({
      input: path.join(fixturesRoot, fixture),
      out: path.join(tmp, `${fixture}.ejspkg`)
    }), code);
  }
}

async function testTarballIntegrity(tmp) {
  const tarball = path.join(tmp, 'simple-esm.tgz');
  const tarballBytes = await createTarballFromDirectory(path.join(fixturesRoot, 'simple-esm'), tarball);
  const integrity = sha512Integrity(tarballBytes);
  assert(verifyIntegrity(tarballBytes, integrity));
  const lock = path.join(tmp, 'package-lock.json');
  await fsp.writeFile(lock, stableStringify({
    name: 'fixture-lock',
    lockfileVersion: 3,
    packages: {
      'node_modules/simple-esm': {
        version: '1.0.0',
        resolved: 'file:simple-esm.tgz',
        integrity
      }
    }
  }));
  const out = path.join(tmp, 'tarball.ejspkg');
  await convertPackage({
    input: tarball,
    out,
    lock,
    packageName: 'simple-esm'
  });
  const report = await readJson(path.join(out, 'report.json'));
  assert.strictEqual(report.sourcePackage.integrityVerified, true);

  const badLock = path.join(tmp, 'bad-package-lock.json');
  await fsp.writeFile(badLock, stableStringify({
    lockfileVersion: 3,
    packages: {
      'node_modules/simple-esm': {
        version: '1.0.0',
        integrity: `sha512-${Buffer.alloc(64).toString('base64')}`
      }
    }
  }));
  await assertRejectsCode(() => convertPackage({
    input: tarball,
    out: path.join(tmp, 'bad.ejspkg'),
    lock: badLock,
    packageName: 'simple-esm'
  }), 'EJS_CONVERT_INTEGRITY_MISMATCH');
}

async function testCli(tmp) {
  const out = path.join(tmp, 'cli.ejspkg');
  const result = spawnSync(process.execPath, [
    cliPath,
    '--input',
    path.join(fixturesRoot, 'simple-esm'),
    '--out',
    out
  ], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  assert.strictEqual(result.status, 0, result.stderr);
  assert(result.stdout.includes('Converted npm:simple-esm@1.0.0'));
  assert(await fsp.stat(path.join(out, 'ejs-package.json')));
}

(async () => {
  await withTempDir(async (tmp) => {
    await testSimpleEsm(tmp);
    await testSimpleCjs(tmp);
    await testExportsAndDependencies(tmp);
    await testPackageEntryWithoutDotPrefix(tmp);
    await testInvalidExportsTargetsRejected(tmp);
    await testDeterministicOutput(tmp);
    await testRejections(tmp);
    await testTarballIntegrity(tmp);
    await testCli(tmp);
  });
  process.stdout.write('converter_test: PASS\n');
})().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});
