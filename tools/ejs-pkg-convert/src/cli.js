'use strict';

const { convertPackage, ConversionError } = require('./converter');

function printHelp() {
  process.stdout.write(`Usage:
  node tools/ejs-pkg-convert/bin/ejs-pkg-convert.js --input <package-dir-or-tgz> --out <out.ejspkg> [options]

Options:
  --input <path>                      Local package directory or npm tarball.
  --out <path>                        Output unpacked .ejspkg directory.
  --lock <path>                       package-lock.json used to verify exact version/integrity.
  --package <name>                    Package name to select from the lockfile.
  --conditions <a,b,c>                Export conditions. Default: ejs,import,default.
  --force                            Replace an existing output directory.
  --allow-scripts-for-audit-only      Record lifecycle scripts instead of failing.
  --help                             Show this help.
`);
}

function parseArgs(argv) {
  const options = {
    conditions: undefined,
    force: false,
    allowScriptsForAuditOnly: false
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--help':
      case '-h':
        options.help = true;
        break;
      case '--input':
        options.input = argv[++i];
        break;
      case '--out':
        options.out = argv[++i];
        break;
      case '--lock':
        options.lock = argv[++i];
        break;
      case '--package':
        options.packageName = argv[++i];
        break;
      case '--conditions':
        options.conditions = String(argv[++i] || '')
          .split(',')
          .map((condition) => condition.trim())
          .filter(Boolean);
        break;
      case '--force':
        options.force = true;
        break;
      case '--allow-scripts-for-audit-only':
        options.allowScriptsForAuditOnly = true;
        break;
      case '--deny-lifecycle-scripts':
      case '--deny-native':
      case '--deny-dynamic-require':
        break;
      default:
        if (!arg || arg.startsWith('-')) {
          throw new ConversionError('EJS_CONVERT_USAGE', `unknown option: ${arg}`);
        }
        if (!options.input) {
          options.input = arg;
        } else if (!options.out) {
          options.out = arg;
        } else {
          throw new ConversionError('EJS_CONVERT_USAGE', `unexpected argument: ${arg}`);
        }
    }
  }

  return options;
}

async function runCli(argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return;
  }
  if (!options.input || !options.out) {
    printHelp();
    throw new ConversionError('EJS_CONVERT_USAGE', '--input and --out are required');
  }

  const result = await convertPackage(options);
  process.stdout.write(`Converted ${result.packageId} -> ${result.outDir}\n`);
  process.stdout.write(`packageSha256: ${result.packageSha256}\n`);
}

module.exports = {
  parseArgs,
  runCli
};
