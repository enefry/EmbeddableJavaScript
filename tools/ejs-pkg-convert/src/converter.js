'use strict';

const crypto = require('crypto');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const zlib = require('zlib');

const CONVERTER_NAME = 'ejs-pkg-convert';
const CONVERTER_VERSION = '0.1.0';
const DEFAULT_CONDITIONS = ['ejs', 'import', 'default'];
const JS_EXTENSIONS = ['.js', '.mjs', '.cjs'];
const LIFECYCLE_SCRIPTS = new Set([
  'preinstall',
  'install',
  'postinstall',
  'prepare',
  'prepublish',
  'prepublishOnly'
]);
const NODE_BUILTINS = new Set([
  'assert',
  'async_hooks',
  'buffer',
  'child_process',
  'cluster',
  'console',
  'constants',
  'crypto',
  'dgram',
  'diagnostics_channel',
  'dns',
  'domain',
  'events',
  'fs',
  'http',
  'http2',
  'https',
  'inspector',
  'module',
  'net',
  'os',
  'path',
  'perf_hooks',
  'process',
  'punycode',
  'querystring',
  'readline',
  'repl',
  'stream',
  'string_decoder',
  'sys',
  'timers',
  'tls',
  'tty',
  'url',
  'util',
  'v8',
  'vm',
  'worker_threads',
  'zlib'
]);

const DEFAULT_LIMITS = Object.freeze({
  maxFiles: 10000,
  maxFileBytes: 2 * 1024 * 1024,
  maxSourceBytes: 8 * 1024 * 1024,
  maxPackageBytes: 64 * 1024 * 1024
});

class ConversionError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = 'ConversionError';
    this.code = code;
    this.details = details || null;
  }
}

class PackageInput {
  constructor({ kind, sourcePath, files, packageBytes, tarballBytes }) {
    this.kind = kind;
    this.sourcePath = sourcePath;
    this.files = files;
    this.packageBytes = packageBytes || 0;
    this.tarballBytes = tarballBytes || null;
  }

  hasFile(relPath) {
    return this.files.has(cleanRelPath(relPath));
  }

  readFile(relPath) {
    const clean = cleanRelPath(relPath);
    const entry = this.files.get(clean);
    if (!entry) {
      throw new ConversionError('EJS_CONVERT_FILE_NOT_FOUND', `missing package file: ${clean}`);
    }
    return entry.bytes;
  }

  readText(relPath) {
    const bytes = this.readFile(relPath);
    return bytes.toString('utf8');
  }

  listFiles() {
    return Array.from(this.files.keys()).sort();
  }
}

function cleanRelPath(value) {
  const normalized = path.posix.normalize(String(value || '').replace(/\\/g, '/'));
  if (normalized === '.') {
    return '';
  }
  return normalized.replace(/^\/+/, '');
}

function ensureSafeArchivePath(entryPath) {
  if (!entryPath || entryPath.includes('\0')) {
    throw new ConversionError('EJS_CONVERT_UNSAFE_ARCHIVE_PATH', `unsafe archive path: ${entryPath}`);
  }
  const normalized = entryPath.replace(/\\/g, '/');
  if (normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized)) {
    throw new ConversionError('EJS_CONVERT_UNSAFE_ARCHIVE_PATH', `absolute archive path rejected: ${entryPath}`);
  }
  const parts = normalized.split('/');
  if (parts.some((part) => part === '..')) {
    throw new ConversionError('EJS_CONVERT_UNSAFE_ARCHIVE_PATH', `path traversal rejected: ${entryPath}`);
  }
  return cleanRelPath(normalized);
}

function sha256Hex(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function hashJson(value) {
  return sha256Hex(Buffer.from(stableStringify(value), 'utf8'));
}

function stableStringify(value) {
  return `${JSON.stringify(sortJson(value), null, 2)}\n`;
}

function sortJson(value) {
  if (Array.isArray(value)) {
    return value.map(sortJson);
  }
  if (!value || typeof value !== 'object' || Buffer.isBuffer(value)) {
    return value;
  }
  const sorted = {};
  for (const key of Object.keys(value).sort()) {
    sorted[key] = sortJson(value[key]);
  }
  return sorted;
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new ConversionError('EJS_CONVERT_INVALID_JSON', `${label} is not valid JSON: ${error.message}`);
  }
}

function packageId(name, version) {
  return `npm:${name}@${version}`;
}

function packageUrlPrefix(name, version) {
  return `ejs-pkg://npm/${encodeURIComponent(name)}@${encodeURIComponent(version)}/modules`;
}

function moduleUrl(rootPackage, sourceRel) {
  return `${packageUrlPrefix(rootPackage.name, rootPackage.version)}/${sourceRel.split('/').map(encodeURIComponent).join('/')}`;
}

function moduleOutputPath(sourceRel) {
  return `modules/${sourceRel}`;
}

async function pathExists(filePath) {
  try {
    await fsp.access(filePath);
    return true;
  } catch (_) {
    return false;
  }
}

async function removeDirIfExists(dir) {
  if (await pathExists(dir)) {
    await fsp.rm(dir, { recursive: true, force: true });
  }
}

async function writeFileDeterministic(filePath, bytes) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, bytes);
}

async function loadDirectory(inputPath, limits) {
  const root = path.resolve(inputPath);
  const files = new Map();
  let packageBytes = 0;

  async function walk(absDir, relDir) {
    const entries = await fsp.readdir(absDir, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const dirent of entries) {
      const absPath = path.join(absDir, dirent.name);
      const relPath = cleanRelPath(path.posix.join(relDir, dirent.name));
      const stat = await fsp.lstat(absPath);
      if (stat.isSymbolicLink()) {
        throw new ConversionError('EJS_CONVERT_UNSAFE_SYMLINK', `symlink rejected: ${relPath}`);
      }
      if (stat.isDirectory()) {
        await walk(absPath, relPath);
        continue;
      }
      if (!stat.isFile()) {
        continue;
      }
      if (stat.size > limits.maxFileBytes) {
        throw new ConversionError('EJS_CONVERT_FILE_TOO_LARGE', `file is too large: ${relPath}`);
      }
      packageBytes += stat.size;
      if (packageBytes > limits.maxPackageBytes) {
        throw new ConversionError('EJS_CONVERT_PACKAGE_TOO_LARGE', 'package exceeds maxPackageBytes');
      }
      if (files.size + 1 > limits.maxFiles) {
        throw new ConversionError('EJS_CONVERT_TOO_MANY_FILES', 'package exceeds maxFiles');
      }
      files.set(relPath, { bytes: await fsp.readFile(absPath) });
    }
  }

  await walk(root, '');
  return new PackageInput({
    kind: 'directory',
    sourcePath: root,
    files,
    packageBytes
  });
}

function readTarString(block, offset, length) {
  const raw = block.slice(offset, offset + length);
  const nul = raw.indexOf(0);
  return raw.slice(0, nul === -1 ? raw.length : nul).toString('utf8').trim();
}

function readTarOctal(block, offset, length) {
  const text = readTarString(block, offset, length).replace(/\0/g, '').trim();
  if (!text) {
    return 0;
  }
  return parseInt(text, 8);
}

function parseTarEntries(tarBytes, limits) {
  const entries = [];
  let offset = 0;
  while (offset + 512 <= tarBytes.length) {
    const header = tarBytes.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) {
      break;
    }

    const name = readTarString(header, 0, 100);
    const prefix = readTarString(header, 345, 155);
    const typeflag = readTarString(header, 156, 1) || '0';
    const size = readTarOctal(header, 124, 12);
    const entryPath = prefix ? `${prefix}/${name}` : name;
    const dataStart = offset + 512;
    const dataEnd = dataStart + size;
    if (dataEnd > tarBytes.length) {
      throw new ConversionError('EJS_CONVERT_INVALID_TAR', `truncated tar entry: ${entryPath}`);
    }

    if (typeflag === '2') {
      throw new ConversionError('EJS_CONVERT_UNSAFE_SYMLINK', `tar symlink rejected: ${entryPath}`);
    }
    if (typeflag === '0' || typeflag === '') {
      if (size > limits.maxFileBytes) {
        throw new ConversionError('EJS_CONVERT_FILE_TOO_LARGE', `file is too large: ${entryPath}`);
      }
      entries.push({
        path: ensureSafeArchivePath(entryPath),
        bytes: Buffer.from(tarBytes.subarray(dataStart, dataEnd))
      });
    } else if (typeflag !== '5' && typeflag !== 'x' && typeflag !== 'g') {
      throw new ConversionError('EJS_CONVERT_UNSUPPORTED_TAR_ENTRY', `unsupported tar entry type ${typeflag}: ${entryPath}`);
    }

    offset = dataStart + Math.ceil(size / 512) * 512;
  }
  return entries;
}

async function loadTarball(inputPath, limits) {
  const sourcePath = path.resolve(inputPath);
  const tarballBytes = await fsp.readFile(sourcePath);
  if (tarballBytes.length > limits.maxPackageBytes) {
    throw new ConversionError('EJS_CONVERT_PACKAGE_TOO_LARGE', 'tarball exceeds maxPackageBytes');
  }
  let tarBytes;
  try {
    tarBytes = zlib.gunzipSync(tarballBytes);
  } catch (error) {
    throw new ConversionError('EJS_CONVERT_INVALID_TARBALL', `failed to gunzip tarball: ${error.message}`);
  }
  const entries = parseTarEntries(tarBytes, limits);
  const nonMetaEntries = entries.filter((entry) => !entry.path.startsWith('PaxHeaders.'));
  const prefixes = new Set(nonMetaEntries.map((entry) => entry.path.split('/')[0]).filter(Boolean));
  const stripPrefix = prefixes.size === 1 && prefixes.has('package') ? 'package/' : '';
  const files = new Map();
  let packageBytes = 0;

  for (const entry of nonMetaEntries) {
    let relPath = entry.path;
    if (stripPrefix && relPath.startsWith(stripPrefix)) {
      relPath = relPath.slice(stripPrefix.length);
    }
    relPath = cleanRelPath(relPath);
    if (!relPath) {
      continue;
    }
    packageBytes += entry.bytes.length;
    if (packageBytes > limits.maxPackageBytes) {
      throw new ConversionError('EJS_CONVERT_PACKAGE_TOO_LARGE', 'package exceeds maxPackageBytes');
    }
    if (files.size + 1 > limits.maxFiles) {
      throw new ConversionError('EJS_CONVERT_TOO_MANY_FILES', 'package exceeds maxFiles');
    }
    files.set(relPath, { bytes: entry.bytes });
  }

  return new PackageInput({
    kind: 'tarball',
    sourcePath,
    files,
    packageBytes,
    tarballBytes
  });
}

async function loadInput(inputPath, limits) {
  const stat = await fsp.stat(inputPath);
  if (stat.isDirectory()) {
    return loadDirectory(inputPath, limits);
  }
  if (stat.isFile()) {
    return loadTarball(inputPath, limits);
  }
  throw new ConversionError('EJS_CONVERT_INVALID_INPUT', `input must be a directory or tarball: ${inputPath}`);
}

function readPackageJson(input, packageRoot) {
  const rel = packageRoot ? path.posix.join(packageRoot, 'package.json') : 'package.json';
  if (!input.hasFile(rel)) {
    throw new ConversionError('EJS_CONVERT_MISSING_PACKAGE_JSON', `missing ${rel}`);
  }
  const packageJson = parseJson(input.readText(rel), rel);
  if (!packageJson.name || typeof packageJson.name !== 'string') {
    throw new ConversionError('EJS_CONVERT_INVALID_PACKAGE', `${rel} must contain a string name`);
  }
  if (!packageJson.version || typeof packageJson.version !== 'string' || /[<>=^~*xX]/.test(packageJson.version)) {
    throw new ConversionError('EJS_CONVERT_INVALID_PACKAGE', `${rel} must contain an exact version`);
  }
  return packageJson;
}

function findLifecycleScripts(packageJson) {
  const scripts = packageJson.scripts && typeof packageJson.scripts === 'object' ? packageJson.scripts : {};
  return Object.keys(scripts)
    .filter((name) => LIFECYCLE_SCRIPTS.has(name))
    .sort()
    .map((name) => ({ name, command: String(scripts[name]) }));
}

function detectNativeFiles(input) {
  const nativeFiles = [];
  for (const relPath of input.listFiles()) {
    const basename = path.posix.basename(relPath);
    if (
      relPath.endsWith('.node') ||
      basename === 'binding.gyp' ||
      relPath.includes('/prebuilds/') ||
      relPath.startsWith('prebuilds/') ||
      relPath.includes('/node-pre-gyp/') ||
      relPath.startsWith('node-pre-gyp/')
    ) {
      nativeFiles.push(relPath);
    }
  }
  return nativeFiles.sort();
}

function stripShebang(source) {
  return source.startsWith('#!') ? source.replace(/^#![^\n]*(?:\n|$)/, '') : source;
}

function stripCommentsPreserveLength(source) {
  let result = '';
  let i = 0;
  let mode = 'code';
  let quote = '';
  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];
    if (mode === 'code') {
      if (ch === '/' && next === '/') {
        result += '  ';
        i += 2;
        while (i < source.length && source[i] !== '\n') {
          result += ' ';
          i += 1;
        }
        continue;
      }
      if (ch === '/' && next === '*') {
        result += '  ';
        i += 2;
        while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) {
          result += source[i] === '\n' ? '\n' : ' ';
          i += 1;
        }
        if (i < source.length) {
          result += '  ';
          i += 2;
        }
        continue;
      }
      if (ch === '"' || ch === "'" || ch === '`') {
        mode = 'string';
        quote = ch;
      }
      result += ch;
      i += 1;
      continue;
    }

    result += ch;
    if (ch === '\\') {
      if (i + 1 < source.length) {
        result += source[i + 1];
        i += 2;
        continue;
      }
    } else if (ch === quote) {
      mode = 'code';
      quote = '';
    }
    i += 1;
  }
  return result;
}

function scanModuleSource(source) {
  const clean = stripCommentsPreserveLength(source);
  const imports = [];
  const literalRequireMatches = [];
  const namedCjsExports = new Set();
  const addImport = (kind, specifier, start, end) => {
    imports.push({ kind, specifier, start, end });
  };

  const importRe = /\bimport\s+(?:[^'";]*?\s+from\s*)?(['"])([^'"]+)\1/gm;
  let match;
  while ((match = importRe.exec(clean))) {
    const full = match[0];
    const specifier = match[2];
    const quoteIndex = full.lastIndexOf(match[1] + specifier + match[1]);
    addImport('esm', specifier, match.index + quoteIndex + 1, match.index + quoteIndex + 1 + specifier.length);
  }

  const exportRe = /\bexport\s+(?:[^'";]*?\s+from\s*)?(['"])([^'"]+)\1/gm;
  while ((match = exportRe.exec(clean))) {
    const full = match[0];
    const specifier = match[2];
    const quoteIndex = full.lastIndexOf(match[1] + specifier + match[1]);
    addImport('esm', specifier, match.index + quoteIndex + 1, match.index + quoteIndex + 1 + specifier.length);
  }

  const requireRe = /\brequire\s*\(\s*(['"])([^'"]+)\1\s*\)/gm;
  while ((match = requireRe.exec(clean))) {
    const full = match[0];
    const specifier = match[2];
    const quoteIndex = full.lastIndexOf(match[1] + specifier + match[1]);
    literalRequireMatches.push(match.index);
    addImport('require', specifier, match.index + quoteIndex + 1, match.index + quoteIndex + 1 + specifier.length);
  }

  const allRequireRe = /\brequire\s*\(/gm;
  const allRequires = [];
  while ((match = allRequireRe.exec(clean))) {
    allRequires.push(match.index);
  }
  const dynamicRequire = allRequires.filter((index) => !literalRequireMatches.includes(index));

  const exportsRe = /\bexports\.([A-Za-z_$][\w$]*)\s*=|\bmodule\.exports\.([A-Za-z_$][\w$]*)\s*=/gm;
  while ((match = exportsRe.exec(clean))) {
    namedCjsExports.add(match[1] || match[2]);
  }

  return {
    imports,
    dynamicRequire,
    dynamicImport: /\bimport\s*\(/m.test(clean),
    evalLikeUsage: /\beval\s*\(|\bFunction\s*\(/m.test(clean),
    hasEsmSyntax: imports.some((entry) => entry.kind === 'esm') || /\bexport\s+(?:default|const|let|var|function|class|\{|\*)/m.test(clean),
    hasCjsSyntax: allRequires.length > 0 || /\bmodule\.exports\b|\bexports\./m.test(clean),
    namedCjsExports: Array.from(namedCjsExports).sort(),
    networkLiteralUsage: /https?:\/\//m.test(clean),
    filesystemLiteralUsage: /(?:^|[^\w$])(?:\/tmp\/|\.\/|\.{2}\/)[^'"\s]*/m.test(clean)
  };
}

function detectModuleFormat(sourceRel, packageJson, scan) {
  const ext = path.posix.extname(sourceRel);
  if (ext === '.mjs') {
    return 'esm';
  }
  if (ext === '.cjs') {
    return 'cjs';
  }
  if (packageJson.type === 'module') {
    return 'esm';
  }
  if (scan.hasEsmSyntax && !scan.hasCjsSyntax) {
    return 'esm';
  }
  return 'cjs';
}

function isNodeBuiltin(specifier) {
  if (specifier.startsWith('node:')) {
    return NODE_BUILTINS.has(specifier.slice(5));
  }
  return NODE_BUILTINS.has(specifier);
}

function parsePackageName(specifier) {
  if (specifier.startsWith('@')) {
    const parts = specifier.split('/');
    if (parts.length < 2) {
      throw new ConversionError('EJS_CONVERT_INVALID_SPECIFIER', `invalid package specifier: ${specifier}`);
    }
    return {
      name: `${parts[0]}/${parts[1]}`,
      subpath: parts.length > 2 ? `./${parts.slice(2).join('/')}` : '.'
    };
  }
  const parts = specifier.split('/');
  return {
    name: parts[0],
    subpath: parts.length > 1 ? `./${parts.slice(1).join('/')}` : '.'
  };
}

function resolveExportsTarget(exportsValue, subpath, conditions, packageName) {
  function choose(value) {
    if (typeof value === 'string') {
      return value;
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new ConversionError('EJS_CONVERT_UNSUPPORTED_EXPORTS', `${packageName} has unsupported exports target for ${subpath}`);
    }
    for (const condition of conditions) {
      if (Object.prototype.hasOwnProperty.call(value, condition)) {
        return choose(value[condition]);
      }
    }
    if (Object.prototype.hasOwnProperty.call(value, 'default')) {
      return choose(value.default);
    }
    throw new ConversionError('EJS_CONVERT_UNRESOLVED_EXPORT', `${packageName} has no matching export condition for ${subpath}`);
  }

  if (typeof exportsValue === 'string') {
    if (subpath !== '.') {
      throw new ConversionError('EJS_CONVERT_UNRESOLVED_EXPORT', `${packageName} does not export ${subpath}`);
    }
    return exportsValue;
  }
  if (!exportsValue || typeof exportsValue !== 'object' || Array.isArray(exportsValue)) {
    throw new ConversionError('EJS_CONVERT_UNSUPPORTED_EXPORTS', `${packageName} has unsupported exports`);
  }

  const keys = Object.keys(exportsValue);
  const isSubpathMap = keys.some((key) => key === '.' || key.startsWith('./'));
  if (isSubpathMap) {
    if (!Object.prototype.hasOwnProperty.call(exportsValue, subpath)) {
      throw new ConversionError('EJS_CONVERT_UNRESOLVED_EXPORT', `${packageName} does not export ${subpath}`);
    }
    return choose(exportsValue[subpath]);
  }

  if (subpath !== '.') {
    throw new ConversionError('EJS_CONVERT_UNRESOLVED_EXPORT', `${packageName} does not export ${subpath}`);
  }
  return choose(exportsValue);
}

function targetFromPackageJson(packageJson, subpath, conditions) {
  if (packageJson.exports !== undefined) {
    const target = resolveExportsTarget(packageJson.exports, subpath, conditions, packageJson.name);
    if (typeof target !== 'string' || !target.startsWith('./')) {
      throw new ConversionError('EJS_CONVERT_UNSUPPORTED_EXPORTS', `${packageJson.name} export target must start with ./`);
    }
    return target;
  }
  if (subpath !== '.') {
    return subpath;
  }
  return packageJson.module || packageJson.main || './index.js';
}

function resolveAsFileOrDirectory(input, targetRel) {
  const safeTarget = ensureSafeArchivePath(targetRel);
  const candidates = [];
  candidates.push(safeTarget);
  if (!JS_EXTENSIONS.includes(path.posix.extname(safeTarget))) {
    for (const ext of JS_EXTENSIONS) {
      candidates.push(`${safeTarget}${ext}`);
    }
  }
  for (const candidate of candidates) {
    if (input.hasFile(candidate)) {
      return candidate;
    }
  }
  if (input.hasFile(path.posix.join(safeTarget, 'package.json'))) {
    const packageJson = readPackageJson(input, safeTarget);
    const entry = targetFromPackageJson(packageJson, '.', DEFAULT_CONDITIONS);
    return resolveAsFileOrDirectory(input, path.posix.join(safeTarget, entry));
  }
  for (const ext of JS_EXTENSIONS) {
    const indexCandidate = path.posix.join(safeTarget, `index${ext}`);
    if (input.hasFile(indexCandidate)) {
      return indexCandidate;
    }
  }
  throw new ConversionError('EJS_CONVERT_UNRESOLVED_MODULE', `unable to resolve module file: ${targetRel}`);
}

function findNodeModulePackage(input, importerRel, packageName) {
  let dir = cleanRelPath(path.posix.dirname(importerRel));
  while (true) {
    const candidate = cleanRelPath(path.posix.join(dir, 'node_modules', packageName));
    if (input.hasFile(path.posix.join(candidate, 'package.json'))) {
      return candidate;
    }
    if (!dir) {
      break;
    }
    const parent = cleanRelPath(path.posix.dirname(dir));
    if (parent === dir) {
      break;
    }
    dir = parent === '.' ? '' : parent;
  }
  throw new ConversionError('EJS_CONVERT_UNRESOLVED_PACKAGE', `unable to resolve package: ${packageName}`);
}

function resolvePackageEntry(input, packageRoot, packageJson, subpath, conditions) {
  const target = targetFromPackageJson(packageJson, subpath, conditions);
  if (typeof target !== 'string' || target.length === 0) {
    throw new ConversionError('EJS_CONVERT_UNSUPPORTED_EXPORTS', `${packageJson.name} has unsupported package entry target`);
  }
  const safeTarget = ensureSafeArchivePath(target);
  return resolveAsFileOrDirectory(input, path.posix.join(packageRoot, safeTarget));
}

function resolveSpecifier(input, importer, specifier, conditions, packageJsonCache) {
  if (isNodeBuiltin(specifier)) {
    throw new ConversionError('EJS_CONVERT_UNSUPPORTED_BUILTIN', `unsupported Node builtin import: ${specifier}`, {
      importer: importer.sourceRel,
      specifier
    });
  }

  if (specifier.startsWith('./') || specifier.startsWith('../')) {
    const baseDir = path.posix.dirname(importer.sourceRel);
    const target = path.posix.normalize(path.posix.join(baseDir, specifier));
    const sourceRel = resolveAsFileOrDirectory(input, target);
    return { sourceRel, packageRoot: importer.packageRoot };
  }

  if (specifier.startsWith('/') || specifier.includes('\0')) {
    throw new ConversionError('EJS_CONVERT_INVALID_SPECIFIER', `invalid module specifier: ${specifier}`);
  }

  const parsed = parsePackageName(specifier);
  const packageRoot = findNodeModulePackage(input, importer.sourceRel, parsed.name);
  let depPackageJson = packageJsonCache.get(packageRoot);
  if (!depPackageJson) {
    depPackageJson = readPackageJson(input, packageRoot);
    packageJsonCache.set(packageRoot, depPackageJson);
  }
  const sourceRel = resolvePackageEntry(input, packageRoot, depPackageJson, parsed.subpath, conditions);
  return { sourceRel, packageRoot };
}

function buildModuleGraph(input, rootPackageJson, entryRel, conditions) {
  const packageJsonCache = new Map([['', rootPackageJson]]);
  const modules = new Map();
  const security = {
    dynamicRequire: [],
    evalLikeUsage: [],
    dynamicImport: [],
    networkLiteralUsage: [],
    filesystemLiteralUsage: [],
    unsupportedNodeBuiltins: []
  };
  const dependencies = new Map();

  function packageJsonForRoot(packageRoot) {
    let packageJson = packageJsonCache.get(packageRoot);
    if (!packageJson) {
      packageJson = readPackageJson(input, packageRoot);
      packageJsonCache.set(packageRoot, packageJson);
    }
    return packageJson;
  }

  function addModule(sourceRel, packageRoot) {
    const existing = modules.get(sourceRel);
    if (existing) {
      return existing;
    }
    const packageJson = packageJsonForRoot(packageRoot);
    const source = stripShebang(input.readText(sourceRel));
    const scan = scanModuleSource(source);
    const format = detectModuleFormat(sourceRel, packageJson, scan);
    const record = {
      sourceRel,
      packageRoot,
      packageJson,
      source,
      scan,
      format,
      dependencies: []
    };
    modules.set(sourceRel, record);

    if (scan.dynamicRequire.length > 0) {
      security.dynamicRequire.push({ file: sourceRel, count: scan.dynamicRequire.length });
      throw new ConversionError('EJS_CONVERT_DYNAMIC_REQUIRE', `dynamic require rejected in ${sourceRel}`);
    }
    if (scan.dynamicImport) {
      security.dynamicImport.push({ file: sourceRel });
      throw new ConversionError('EJS_CONVERT_DYNAMIC_IMPORT', `dynamic import rejected in ${sourceRel}`);
    }
    if (scan.evalLikeUsage) {
      security.evalLikeUsage.push({ file: sourceRel });
      throw new ConversionError('EJS_CONVERT_DYNAMIC_CODE', `eval/Function usage rejected in ${sourceRel}`);
    }
    if (scan.networkLiteralUsage) {
      security.networkLiteralUsage.push({ file: sourceRel });
    }
    if (scan.filesystemLiteralUsage) {
      security.filesystemLiteralUsage.push({ file: sourceRel });
    }

    for (const dependency of scan.imports) {
      let resolved;
      try {
        resolved = resolveSpecifier(input, record, dependency.specifier, conditions, packageJsonCache);
      } catch (error) {
        if (error && error.code === 'EJS_CONVERT_UNSUPPORTED_BUILTIN') {
          security.unsupportedNodeBuiltins.push({
            file: sourceRel,
            specifier: dependency.specifier
          });
        }
        throw error;
      }
      record.dependencies.push({
        ...dependency,
        resolvedRel: resolved.sourceRel
      });
      if (resolved.packageRoot) {
        const depPackage = packageJsonForRoot(resolved.packageRoot);
        dependencies.set(depPackage.name, {
          packageId: packageId(depPackage.name, depPackage.version),
          version: depPackage.version
        });
      }
      addModule(resolved.sourceRel, resolved.packageRoot);
    }
    return record;
  }

  addModule(entryRel, '');
  return {
    modules,
    dependencies,
    security,
    cycles: findCycles(modules)
  };
}

function findCycles(modules) {
  const cycles = [];
  const visiting = new Set();
  const visited = new Set();
  const stack = [];

  function visit(sourceRel) {
    if (visiting.has(sourceRel)) {
      const start = stack.indexOf(sourceRel);
      if (start !== -1) {
        cycles.push(stack.slice(start).concat(sourceRel));
      }
      return;
    }
    if (visited.has(sourceRel)) {
      return;
    }
    visiting.add(sourceRel);
    stack.push(sourceRel);
    const record = modules.get(sourceRel);
    for (const dependency of record.dependencies) {
      visit(dependency.resolvedRel);
    }
    stack.pop();
    visiting.delete(sourceRel);
    visited.add(sourceRel);
  }

  for (const sourceRel of modules.keys()) {
    visit(sourceRel);
  }
  return cycles;
}

function replaceRanges(source, replacements) {
  const sorted = replacements.slice().sort((a, b) => b.start - a.start);
  let output = source;
  for (const replacement of sorted) {
    output = `${output.slice(0, replacement.start)}${replacement.value}${output.slice(replacement.end)}`;
  }
  return output;
}

function transformEsm(record, rootPackage) {
  const replacements = record.dependencies
    .filter((dependency) => dependency.kind === 'esm')
    .map((dependency) => ({
      start: dependency.start,
      end: dependency.end,
      value: moduleUrl(rootPackage, dependency.resolvedRel)
    }));
  return `${replaceRanges(record.source, replacements)}\n//# sourceURL=${moduleUrl(rootPackage, record.sourceRel)}\n`;
}

function transformCjs(record, rootPackage, modules) {
  const deps = record.dependencies.filter((dependency) => dependency.kind === 'require');
  const imports = [];
  const cases = [];
  deps.forEach((dependency, index) => {
    const variable = `__ejs_cjs_dep_${index}`;
    const depRecord = modules.get(dependency.resolvedRel);
    const depUrl = moduleUrl(rootPackage, dependency.resolvedRel);
    if (depRecord && depRecord.format === 'cjs') {
      imports.push(`import ${variable} from ${JSON.stringify(depUrl)};`);
      cases.push(`    case ${JSON.stringify(dependency.specifier)}: return ${variable};`);
    } else {
      imports.push(`import * as ${variable} from ${JSON.stringify(depUrl)};`);
      cases.push(`    case ${JSON.stringify(dependency.specifier)}: return ${variable};`);
    }
  });

  const namedExports = record.scan.namedCjsExports
    .map((name) => `export const ${name} = Object.prototype.hasOwnProperty.call(Object(module.exports), ${JSON.stringify(name)}) ? module.exports[${JSON.stringify(name)}] : undefined;`)
    .join('\n');

  return `${imports.join('\n')}
const exports = {};
const module = { exports };
function require(specifier) {
  switch (specifier) {
${cases.join('\n')}
    default:
      throw new Error("Unresolved converted CommonJS require: " + specifier);
  }
}
${record.source}
const __ejs_default = module.exports;
export default __ejs_default;
${namedExports}
//# sourceURL=${moduleUrl(rootPackage, record.sourceRel)}
`;
}

function transformModules(graph, rootPackage) {
  const transformed = new Map();
  for (const sourceRel of Array.from(graph.modules.keys()).sort()) {
    const record = graph.modules.get(sourceRel);
    const source = record.format === 'cjs'
      ? transformCjs(record, rootPackage, graph.modules)
      : transformEsm(record, rootPackage);
    transformed.set(sourceRel, {
      source,
      format: 'esm',
      originalFormat: record.format,
      sourceUrl: moduleUrl(rootPackage, sourceRel),
      outputPath: moduleOutputPath(sourceRel),
      sha256: sha256Hex(Buffer.from(source, 'utf8'))
    });
  }
  return transformed;
}

function readLockInfo(lockfilePath, name, version) {
  if (!lockfilePath) {
    return null;
  }
  const lockJson = parseJson(fs.readFileSync(lockfilePath, 'utf8'), lockfilePath);
  const candidates = [];
  if (lockJson.packages && typeof lockJson.packages === 'object') {
    for (const [lockPath, entry] of Object.entries(lockJson.packages)) {
      if (!entry || typeof entry !== 'object') {
        continue;
      }
      const entryName = entry.name || (lockPath.startsWith('node_modules/') ? lockPath.slice('node_modules/'.length) : undefined);
      if (entryName === name && entry.version === version) {
        candidates.push(entry);
      }
    }
  }
  if (lockJson.dependencies && lockJson.dependencies[name] && lockJson.dependencies[name].version === version) {
    candidates.push(lockJson.dependencies[name]);
  }
  const match = candidates.find((entry) => entry.integrity) || candidates[0];
  if (!match) {
    throw new ConversionError('EJS_CONVERT_LOCK_MISSING_PACKAGE', `lockfile does not contain ${name}@${version}`);
  }
  if (!match.integrity) {
    throw new ConversionError('EJS_CONVERT_LOCK_MISSING_INTEGRITY', `lockfile entry for ${name}@${version} has no integrity`);
  }
  return {
    integrity: match.integrity,
    resolved: match.resolved || null
  };
}

function verifyIntegrity(bytes, integrity) {
  const entries = integrity.split(/\s+/).filter(Boolean);
  for (const entry of entries) {
    const dash = entry.indexOf('-');
    if (dash === -1) {
      continue;
    }
    const algorithm = entry.slice(0, dash);
    const expected = entry.slice(dash + 1);
    if (!crypto.getHashes().includes(algorithm)) {
      continue;
    }
    const actual = crypto.createHash(algorithm).update(bytes).digest('base64');
    if (actual === expected) {
      return true;
    }
  }
  return false;
}

function findLicenseFiles(input, rootPackageJson) {
  const licenseFiles = [];
  for (const relPath of input.listFiles()) {
    if (relPath.includes('/node_modules/')) {
      continue;
    }
    const basename = path.posix.basename(relPath).toLowerCase();
    if (basename === 'license' || basename.startsWith('license.') || basename === 'copying' || basename.startsWith('copying.')) {
      const extension = path.posix.extname(relPath) || '.txt';
      const safeName = rootPackageJson.name.replace(/[^A-Za-z0-9_.-]+/g, '_');
      licenseFiles.push({
        package: `${rootPackageJson.name}@${rootPackageJson.version}`,
        license: rootPackageJson.license || 'UNKNOWN',
        sourcePath: relPath,
        file: `licenses/${safeName}-LICENSE${extension}`,
        bytes: input.readFile(relPath)
      });
    }
  }
  return licenseFiles.sort((a, b) => a.file.localeCompare(b.file));
}

function buildManifest({ rootPackageJson, input, lockInfo, conditions, transformed, dependencies, report, packageHash }) {
  const modules = {};
  for (const [sourceRel, record] of transformed) {
    modules[record.sourceUrl] = {
      path: record.outputPath,
      sha256: record.sha256,
      format: record.format,
      originalFormat: record.originalFormat,
      sourceMap: null
    };
  }
  const deps = {};
  for (const [name, dependency] of Array.from(dependencies.entries()).sort(([a], [b]) => a.localeCompare(b))) {
    deps[name] = {
      packageId: dependency.packageId,
      manifestSha256: null
    };
  }
  const entryRel = report.compatibility.entryModule;
  const entryUrl = moduleUrl(rootPackageJson, entryRel);
  return {
    format: 1,
    name: rootPackageJson.name,
    version: rootPackageJson.version,
    packageId: packageId(rootPackageJson.name, rootPackageJson.version),
    entry: entryUrl,
    source: {
      type: input.kind === 'tarball' ? 'npm-tarball' : 'local-directory',
      registry: null,
      tarball: input.kind === 'tarball' && lockInfo ? lockInfo.resolved : null,
      integrity: lockInfo ? lockInfo.integrity : null,
      resolvedBy: lockInfo ? 'package-lock.json' : null
    },
    converter: {
      name: CONVERTER_NAME,
      version: CONVERTER_VERSION,
      optionsHash: `sha256-${hashJson({ conditions })}`
    },
    conditions,
    modules,
    imports: {
      '.': entryUrl,
      [rootPackageJson.name]: entryUrl
    },
    dependencies: deps,
    capabilities: {
      filesystem: 'none',
      network: 'none',
      process: 'none',
      native: 'none',
      dynamicCode: 'none'
    },
    policy: {
      requiresApproval: true,
      allowDynamicImport: false,
      allowEval: false
    },
    packageSha256: packageHash ? `sha256-${packageHash}` : null,
    signature: null
  };
}

function buildReport({ rootPackageJson, input, lockInfo, integrityVerified, lifecycleScripts, nativeFiles, graph, transformed, entryRel, licenseFiles }) {
  const commonJSWrappedModules = [];
  for (const [sourceRel, record] of transformed) {
    if (record.originalFormat === 'cjs') {
      commonJSWrappedModules.push(moduleUrl(rootPackageJson, sourceRel));
    }
  }
  return {
    summary: {
      status: 'converted',
      warnings: graph.security.networkLiteralUsage.length + graph.security.filesystemLiteralUsage.length,
      unsupportedFeatures: 0
    },
    sourcePackage: {
      name: rootPackageJson.name,
      version: rootPackageJson.version,
      license: rootPackageJson.license || 'UNKNOWN',
      sourceType: input.kind,
      integrity: lockInfo ? lockInfo.integrity : null,
      integrityVerified
    },
    security: {
      lifecycleScripts,
      nativeFiles,
      dynamicRequire: graph.security.dynamicRequire,
      dynamicImport: graph.security.dynamicImport,
      evalLikeUsage: graph.security.evalLikeUsage,
      networkLiteralUsage: graph.security.networkLiteralUsage,
      filesystemLiteralUsage: graph.security.filesystemLiteralUsage
    },
    compatibility: {
      entryModule: entryRel,
      moduleFormat: 'esm',
      commonJSWrappedModules: commonJSWrappedModules.sort(),
      externalizedImports: [],
      unsupportedNodeBuiltins: graph.security.unsupportedNodeBuiltins,
      circularDependencies: graph.cycles
    },
    licenses: licenseFiles.map((licenseFile) => ({
      package: licenseFile.package,
      license: licenseFile.license,
      file: licenseFile.file
    }))
  };
}

async function validateOutput(outDir, manifest) {
  const manifestPath = path.join(outDir, 'ejs-package.json');
  const writtenManifest = parseJson(await fsp.readFile(manifestPath, 'utf8'), manifestPath);
  for (const [url, entry] of Object.entries(writtenManifest.modules)) {
    const filePath = path.join(outDir, entry.path);
    const bytes = await fsp.readFile(filePath);
    const actual = sha256Hex(bytes);
    if (actual !== entry.sha256) {
      throw new ConversionError('EJS_CONVERT_SELF_CHECK_FAILED', `module hash mismatch for ${url}`);
    }
  }
  if (writtenManifest.packageSha256 !== manifest.packageSha256) {
    throw new ConversionError('EJS_CONVERT_SELF_CHECK_FAILED', 'manifest packageSha256 changed during write');
  }
}

async function writeOutput(outDir, { manifest, report, transformed, licenseFiles, force }) {
  if (await pathExists(outDir)) {
    if (!force) {
      throw new ConversionError('EJS_CONVERT_OUTPUT_EXISTS', `output already exists: ${outDir}`);
    }
    await removeDirIfExists(outDir);
  }
  await fsp.mkdir(outDir, { recursive: true });
  for (const [, record] of transformed) {
    await writeFileDeterministic(path.join(outDir, record.outputPath), `${record.source}`, 'utf8');
  }
  for (const licenseFile of licenseFiles) {
    await writeFileDeterministic(path.join(outDir, licenseFile.file), licenseFile.bytes);
  }
  await writeFileDeterministic(path.join(outDir, 'report.json'), stableStringify(report), 'utf8');
  await writeFileDeterministic(path.join(outDir, 'ejs-package.json'), stableStringify(manifest), 'utf8');
  await validateOutput(outDir, manifest);
}

async function convertPackage(rawOptions) {
  const options = {
    ...rawOptions,
    input: rawOptions.input || rawOptions.inputPath,
    out: rawOptions.out || rawOptions.outDir,
    conditions: rawOptions.conditions && rawOptions.conditions.length > 0 ? rawOptions.conditions : DEFAULT_CONDITIONS,
    limits: { ...DEFAULT_LIMITS, ...(rawOptions.limits || {}) },
    force: Boolean(rawOptions.force)
  };
  if (!options.input || !options.out) {
    throw new ConversionError('EJS_CONVERT_USAGE', 'input and out are required');
  }

  const input = await loadInput(options.input, options.limits);
  const rootPackageJson = readPackageJson(input, '');
  if (options.packageName && options.packageName !== rootPackageJson.name) {
    throw new ConversionError('EJS_CONVERT_PACKAGE_MISMATCH', `input package is ${rootPackageJson.name}, expected ${options.packageName}`);
  }

  const lifecycleScripts = findLifecycleScripts(rootPackageJson);
  if (lifecycleScripts.length > 0 && !options.allowScriptsForAuditOnly) {
    throw new ConversionError('EJS_CONVERT_LIFECYCLE_SCRIPT', `lifecycle script rejected: ${lifecycleScripts.map((script) => script.name).join(', ')}`);
  }
  const nativeFiles = detectNativeFiles(input);
  if (nativeFiles.length > 0) {
    throw new ConversionError('EJS_CONVERT_NATIVE_ADDON', `native addon files rejected: ${nativeFiles.join(', ')}`);
  }

  const lockInfo = readLockInfo(options.lock, rootPackageJson.name, rootPackageJson.version);
  let integrityVerified = false;
  if (lockInfo && input.kind === 'tarball') {
    integrityVerified = verifyIntegrity(input.tarballBytes, lockInfo.integrity);
    if (!integrityVerified) {
      throw new ConversionError('EJS_CONVERT_INTEGRITY_MISMATCH', `${rootPackageJson.name}@${rootPackageJson.version} tarball integrity mismatch`);
    }
  } else if (lockInfo) {
    integrityVerified = false;
  }

  const entryRel = resolvePackageEntry(input, '', rootPackageJson, '.', options.conditions);
  const graph = buildModuleGraph(input, rootPackageJson, entryRel, options.conditions);
  const transformed = transformModules(graph, rootPackageJson);
  const licenseFiles = findLicenseFiles(input, rootPackageJson);
  const report = buildReport({
    rootPackageJson,
    input,
    lockInfo,
    integrityVerified,
    lifecycleScripts,
    nativeFiles,
    graph,
    transformed,
    entryRel,
    licenseFiles
  });
  const manifestWithoutHash = buildManifest({
    rootPackageJson,
    input,
    lockInfo,
    conditions: options.conditions,
    transformed,
    dependencies: graph.dependencies,
    report,
    packageHash: null
  });
  const packageHash = hashJson({
    manifest: manifestWithoutHash,
    report,
    modules: Array.from(transformed.entries()).map(([sourceRel, record]) => ({
      sourceRel,
      sourceSha256: record.sha256,
      outputPath: record.outputPath
    })),
    licenses: licenseFiles.map((licenseFile) => ({
      file: licenseFile.file,
      sha256: sha256Hex(licenseFile.bytes)
    }))
  });
  const manifest = buildManifest({
    rootPackageJson,
    input,
    lockInfo,
    conditions: options.conditions,
    transformed,
    dependencies: graph.dependencies,
    report,
    packageHash
  });

  const outDir = path.resolve(options.out);
  await writeOutput(outDir, {
    manifest,
    report,
    transformed,
    licenseFiles,
    force: options.force
  });

  return {
    outDir,
    packageId: manifest.packageId,
    packageSha256: manifest.packageSha256,
    manifest,
    report
  };
}

module.exports = {
  CONVERTER_NAME,
  CONVERTER_VERSION,
  ConversionError,
  convertPackage,
  stableStringify,
  verifyIntegrity,
  sha256Hex
};
