'use strict';

const assert = require('assert');
const fsp = require('fs').promises;
const os = require('os');
const path = require('path');

const {
  convertPackage
} = require('../../tools/ejs-pkg-convert/src/converter');

async function readJson(filePath) {
  return JSON.parse(await fsp.readFile(filePath, 'utf8'));
}

async function withTempDir(fn) {
  const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'ejs-cheerio-conversion-test-'));
  try {
    await fn(tmp);
  } finally {
    await fsp.rm(tmp, { recursive: true, force: true });
  }
}

async function main() {
  const input = process.env.EJS_CHEERIO_INPUT_DIR;
  if (!input) {
    process.stdout.write('cheerio_conversion_test: SKIP EJS_CHEERIO_INPUT_DIR is not set\n');
    process.exitCode = 77;
    return;
  }

  await withTempDir(async (tmp) => {
    const out = path.join(tmp, 'cheerio.ejspkg');
    const result = await convertPackage({
      input,
      out,
      conditions: ['ejs', 'browser', 'import', 'default'],
      allowScriptsForAuditOnly: true
    });

    const manifest = await readJson(path.join(out, 'ejs-package.json'));
    const report = await readJson(path.join(out, 'report.json'));
    const modules = Object.keys(manifest.modules);
    const dependencies = Object.keys(manifest.dependencies);

    assert.strictEqual(result.packageId, manifest.packageId);
    assert.strictEqual(report.summary.status, 'converted');
    assert.strictEqual(manifest.capabilities.filesystem, 'none');
    assert.strictEqual(manifest.capabilities.network, 'none');
    const isDirectCheerioPackage = manifest.packageId.startsWith('npm:cheerio@');
    assert(isDirectCheerioPackage || dependencies.includes('cheerio'),
      'converted package should be cheerio or include cheerio dependency');
    assert(modules.length > 50, `expected a real cheerio module graph, got ${modules.length} modules`);
    assert(modules.some((url) =>
      url.includes('/modules/dist/browser/index.js') ||
      url.includes('/modules/node_modules/cheerio/dist/browser/index.js')));
    assert(modules.some((url) => url.includes('/modules/node_modules/parse5/dist/')));
  });

  process.stdout.write('cheerio_conversion_test: PASS\n');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});
