const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");

function bytes(text) {
  return new Uint8Array(Buffer.from(String(text), "utf8"));
}

function jsonBytes(value) {
  return bytes(JSON.stringify(value));
}

function install(relativePath, invoke, globals = {}) {
  const context = vm.createContext({
    console,
    assert,
    ...globals,
    __ejs_native__: { invoke }
  });
  const source = fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
  vm.runInContext(source, context, { filename: relativePath });
  return context;
}

function createFinalizationRegistryHarness() {
  const instances = [];
  const records = [];
  class FakeFinalizationRegistry {
    constructor(callback) {
      this.callback = callback;
      this.records = [];
      instances.push(this);
    }

    register(target, heldValue, unregisterToken) {
      const record = { type: "register", target, heldValue, unregisterToken };
      this.records.push(record);
      records.push(record);
    }

    unregister(token) {
      const record = { type: "unregister", token };
      this.records.push(record);
      records.push(record);
      return true;
    }
  }
  return { FakeFinalizationRegistry, instances, records };
}

async function runInContext(context, source) {
  return vm.runInContext(`(async function(){${source}\n})()`, context);
}

async function testFSWrapper() {
  const calls = [];
  const context = install("modules/fs/js/fs.js", async (moduleID, methodID, payload, transferBuffer) => {
    calls.push({ moduleID, methodID, payload: JSON.parse(payload || "{}"), transferBuffer });
    assert.strictEqual(moduleID, "ejs.fs");

    switch (methodID) {
      case "stat":
      case "lstat":
        return jsonBytes({
          type: methodID === "lstat" ? "symbolicLink" : "file",
          dev: 1,
          ino: 2,
          mode: methodID === "lstat" ? 0o120777 : 0o100644,
          nlink: 1,
          uid: 501,
          gid: 20,
          rdev: 0,
          size: 4,
          blksize: 4096,
          blocks: 8,
          atimeMs: 10,
          mtimeMs: 20,
          ctimeMs: 30,
          birthtimeMs: 40
        });
      case "open":
        return jsonBytes({ handle: "h1" });
      case "fileHandleRead":
        return bytes("read-ok");
      case "fileHandleWrite":
        assert.deepStrictEqual(Array.from(new Uint8Array(transferBuffer.buffer, transferBuffer.byteOffset, transferBuffer.byteLength)), [119, 114, 105, 116, 101]);
        return jsonBytes({ bytesWritten: 5 });
      case "fileHandleTruncate":
      case "fileHandleDatasync":
      case "fileHandleSync":
      case "fileHandleClose":
      case "link":
      case "symlink":
      case "chmod":
      case "chown":
      case "lchown":
      case "utime":
      case "lutime":
      case "delete":
        return jsonBytes({ ok: true });
      case "readLink":
        return jsonBytes({ target: "target.txt" });
      case "statFs":
        return jsonBytes({ type: 1, bsize: 4096, blocks: 10, bfree: 8, bavail: 7, files: 6, ffree: 5 });
      case "makeTempDir":
        return jsonBytes({ path: "tmp-dir" });
      case "makeTempFile":
        return jsonBytes({ path: "tmp-dir/tmp-file" });
      default:
        throw new Error(`unexpected fs method ${methodID}`);
    }
  });

  await runInContext(context, `
    const stat = await EJSFS.promises.stat("file.txt", { root: "documents" });
    assert(stat.isFile() && !stat.isDirectory() && !stat.isSymbolicLink());
    assert.strictEqual(stat.mode, 0o100644);
    const lstat = await EJSFS.promises.lstat("link.txt");
    assert(lstat.isSymbolicLink() && !lstat.isFile());

    const handle = await EJSFS.promises.open("file.txt", "r+", 0o600, { root: "documents" });
    assert.strictEqual(await handle.read({ length: 7, position: 0, encoding: "utf8" }), "read-ok");
    assert.strictEqual(await handle.write("write", { position: 1 }), 5);
    await handle.truncate(4);
    await handle.datasync();
    await handle.sync();
    await handle.close();
    await handle.close();

    assert.strictEqual(await EJSFS.promises.readLink("link.txt"), "target.txt");
    await EJSFS.promises.link("file.txt", "hard.txt", { newRoot: "cache" });
    await EJSFS.promises.symlink("file.txt", "sym.txt");
    const statFs = await EJSFS.promises.statFs(".");
    assert.strictEqual(statFs.bsize, 4096);
    assert.strictEqual(await EJSFS.promises.makeTempDir("pfx-"), "tmp-dir");
    assert.strictEqual(await EJSFS.promises.makeTempFile("pfx-", { dir: "tmp-dir" }), "tmp-dir/tmp-file");
    await EJSFS.promises.chmod("file.txt", 0o600);
    await EJSFS.promises.chown("file.txt", 501, 20);
    await EJSFS.promises.lchown("sym.txt", 501, 20);
    await EJSFS.promises.utime("file.txt", new Date(1000), 2000);
    await EJSFS.promises.lutime("sym.txt", 1000, new Date(2000));
    await EJSFS.promises.remove("tmp-dir", { recursive: true });
  `);

  assert.deepStrictEqual(calls.map((call) => call.methodID), [
    "stat",
    "lstat",
    "open",
    "fileHandleRead",
    "fileHandleWrite",
    "fileHandleTruncate",
    "fileHandleDatasync",
    "fileHandleSync",
    "fileHandleClose",
    "readLink",
    "link",
    "symlink",
    "statFs",
    "makeTempDir",
    "makeTempFile",
    "chmod",
    "chown",
    "lchown",
    "utime",
    "lutime",
    "delete"
  ]);

  await assert.rejects(
    () => vm.runInContext("EJSFS.promises.open('', 'r')", context),
    /fs path must not be empty/
  );
  await assert.rejects(
    () => runInContext(context, "await EJSFS.promises.chown('file.txt', -1, 20);"),
    /uid must be a non-negative integer/
  );
}

async function testFSFinalizerCleanup() {
  let openCount = 0;
  const calls = [];
  const harness = createFinalizationRegistryHarness();
  const context = install("modules/fs/js/fs.js", async (moduleID, methodID, payload) => {
    calls.push({ moduleID, methodID, payload: JSON.parse(payload || "{}") });
    assert.strictEqual(moduleID, "ejs.fs");
    if (methodID === "open") {
      openCount += 1;
      return jsonBytes({ handle: `fh-${openCount}` });
    }
    if (methodID === "fileHandleClose") {
      return jsonBytes({ ok: true });
    }
    throw new Error(`unexpected fs method ${methodID}`);
  }, { FinalizationRegistry: harness.FakeFinalizationRegistry });

  const finalizerHandle = await context.EJSFS.promises.open("finalizer.txt", "r");
  assert.strictEqual(finalizerHandle.handle, "fh-1");
  assert.strictEqual(harness.records[0].type, "register");
  assert.strictEqual(harness.records[0].heldValue, "fh-1");
  await harness.instances[0].callback("fh-1");
  assert.deepStrictEqual(calls.map((call) => call.methodID), ["open", "fileHandleClose"]);
  assert.deepStrictEqual(calls[1].payload, { handle: "fh-1" });

  const explicitHandle = await context.EJSFS.promises.open("explicit.txt", "r");
  await explicitHandle.close();
  await explicitHandle.close();
  assert.strictEqual(harness.records.some((record) => record.type === "unregister" && record.token === explicitHandle), true);
  assert.deepStrictEqual(calls.map((call) => call.methodID), ["open", "fileHandleClose", "open", "fileHandleClose"]);
  assert.deepStrictEqual(calls[3].payload, { handle: "fh-2" });
}

function testBufferWrapper() {
  const context = install("modules/buffer/js/buffer.js", null, {
    TextEncoder: undefined,
    TextDecoder: undefined
  });
  const binary = context.EJSBinary;
  const expectedLargeText = "a".repeat(70000) + "🌍" + "\ufffd";
  const bytesValue = binary.fromString("a".repeat(70000) + "🌍" + "\ud800", "utf8");
  assert.strictEqual(binary.toString(bytesValue, "utf8"), expectedLargeText);
  assert.strictEqual(binary.toString(binary.fromString("68656c6c6f", "hex"), "utf8"), "hello");
  assert.strictEqual(binary.toString(binary.fromString("aGVsbG8", "base64"), "utf8"), "hello");
  assert.strictEqual(binary.toString(binary.fromString(binary.toString(bytesValue, "base64"), "base64"), "utf8"), expectedLargeText);
  assert.throws(() => binary.fromString("abc", "hex"), /even length/);
  assert.throws(() => binary.fromString("ab!c", "hex"), /invalid characters/);
}

function testPathWrapper() {
  const context = install("modules/path/js/path.js");
  const posix = context.EJSPath.posix;
  assert.strictEqual(posix.resolve("a", "../b"), "/b");
  assert.deepStrictEqual(JSON.parse(JSON.stringify(posix.parse("/tmp/file.txt"))), {
    root: "/",
    dir: "/tmp",
    base: "file.txt",
    ext: ".txt",
    name: "file"
  });
  assert.strictEqual(posix.format({ dir: "/", base: "file.txt" }), "/file.txt");
  assert.strictEqual(posix.format({ dir: "/tmp", name: "file", ext: ".txt" }), "/tmp/file.txt");
  assert.strictEqual(posix.relative("/a/b", "/a/c"), "../c");
}

async function testSystemWrapper() {
  const methods = [];
  const context = install("modules/system/js/system.js", async (moduleID, methodID, payload) => {
    methods.push({ methodID, payload: JSON.parse(payload || "{}") });
    assert.strictEqual(moduleID, "ejs.system");
    const responses = {
      cwd: { cwd: "/tmp/ejs" },
      chdir: { ok: true },
      env: { env: { A: "1" } },
      getenv: { value: methodID === "getenv" ? "value" : null },
      setenv: { ok: true },
      unsetenv: { ok: true },
      pid: { pid: 11 },
      ppid: { ppid: 10 },
      homeDir: { homeDir: "/home/ejs" },
      tmpDir: { tmpDir: "/tmp" },
      exePath: { exePath: "/bin/ejs" },
      hostName: { hostName: "host" },
      platform: { platform: "darwin" },
      arch: { arch: "arm64" },
      uname: { uname: { sysname: "Darwin", nodename: "host", release: "1", version: "v", machine: "arm64" } },
      uptime: { uptime: 12 },
      loadAvg: { loadAvg: [1, 2, 3] },
      availableParallelism: { availableParallelism: 8 },
      cpuInfo: { cpuInfo: [{ model: "cpu", speed: 0 }] },
      networkInterfaces: { networkInterfaces: { lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true }] } },
      userInfo: { userInfo: { uid: 501, gid: 20, username: "ejs", homedir: "/home/ejs", shell: "/bin/zsh" } }
    };
    return jsonBytes(responses[methodID]);
  });

  await runInContext(context, `
    assert.strictEqual(await EJSSystem.cwd(), "/tmp/ejs");
    await EJSSystem.chdir("/tmp/next");
    assert.deepStrictEqual(await EJSSystem.env(), { A: "1" });
    assert.strictEqual(await EJSSystem.getenv("NAME"), "value");
    await EJSSystem.setenv("NAME", "value");
    await EJSSystem.unsetenv("NAME");
    assert.strictEqual(await EJSSystem.pid(), 11);
    assert.strictEqual(await EJSSystem.ppid(), 10);
    assert.strictEqual(await EJSSystem.homeDir(), "/home/ejs");
    assert.strictEqual(await EJSSystem.tmpDir(), "/tmp");
    assert.strictEqual(await EJSSystem.exePath(), "/bin/ejs");
    assert.strictEqual(await EJSSystem.hostName(), "host");
    assert.strictEqual(await EJSSystem.platform(), "darwin");
    assert.strictEqual(await EJSSystem.arch(), "arm64");
    assert.strictEqual((await EJSSystem.uname()).machine, "arm64");
    assert.strictEqual(await EJSSystem.uptime(), 12);
    assert.deepStrictEqual(await EJSSystem.loadAvg(), [1, 2, 3]);
    assert.strictEqual(await EJSSystem.availableParallelism(), 8);
    assert.strictEqual((await EJSSystem.cpuInfo())[0].model, "cpu");
    assert.strictEqual((await EJSSystem.networkInterfaces()).lo0[0].address, "127.0.0.1");
    assert.strictEqual((await EJSSystem.userInfo()).username, "ejs");
  `);

  assert.deepStrictEqual(methods.map((call) => call.methodID), [
    "cwd",
    "chdir",
    "env",
    "getenv",
    "setenv",
    "unsetenv",
    "pid",
    "ppid",
    "homeDir",
    "tmpDir",
    "exePath",
    "hostName",
    "platform",
    "arch",
    "uname",
    "uptime",
    "loadAvg",
    "availableParallelism",
    "cpuInfo",
    "networkInterfaces",
    "userInfo"
  ]);
  await assert.rejects(
    () => vm.runInContext("EJSSystem.getenv('BAD=NAME')", context),
    /environment variable name/
  );
  await assert.rejects(
    () => vm.runInContext("EJSSystem.chdir('')", context),
    /system path/
  );
  await assert.rejects(
    () => vm.runInContext("EJSSystem.setenv('', 'value')", context),
    /environment variable name/
  );
}

async function testFSWatchWrapper() {
  const calls = [];
  const context = install("modules/fswatch/js/fswatch.js", async (moduleID, methodID, payload) => {
    calls.push({ methodID, payload: JSON.parse(payload || "{}") });
    assert.strictEqual(moduleID, "ejs.fswatch");
    if (methodID === "watch") return jsonBytes({ watcherID: "w1", recursive: false });
    if (methodID === "close") return jsonBytes({ ok: true });
    throw new Error(`unexpected fswatch method ${methodID}`);
  });

  await runInContext(context, `
    const events = [];
    const watcher = await EJSFSWatch.watch("file.txt", (type, path) => events.push(type + ":" + path), { root: "documents" });
    assert.strictEqual(watcher.id, "w1");
    assert.strictEqual(watcher.recursive, false);
    __EJSFSWatchDispatch("w1", "change", "file.txt");
    assert.deepStrictEqual(events, ["change:file.txt"]);
    await watcher.close();
    await watcher.close();
  `);

  assert.deepStrictEqual(calls.map((call) => call.methodID), ["watch", "close"]);
  assert.deepStrictEqual(calls[0].payload, { path: "file.txt", root: "documents" });
  await assert.rejects(
    () => vm.runInContext("EJSFSWatch.watch('', () => {})", context),
    /watch path/
  );
  await assert.rejects(
    () => vm.runInContext("EJSFSWatch.watch('file.txt', null)", context),
    /watch handler/
  );
  await assert.rejects(
    () => vm.runInContext("EJSFSWatch.watch('file.txt', () => {}, { recursive: 'yes' })", context),
    /recursive/
  );
}

async function testFSWatchFinalizerCleanup() {
  const calls = [];
  const events = [];
  const harness = createFinalizationRegistryHarness();
  const context = install("modules/fswatch/js/fswatch.js", async (moduleID, methodID, payload) => {
    calls.push({ methodID, payload: JSON.parse(payload || "{}") });
    assert.strictEqual(moduleID, "ejs.fswatch");
    if (methodID === "watch") return jsonBytes({ watcherID: "watch-finalizer", recursive: false });
    if (methodID === "close") return jsonBytes({ ok: true });
    throw new Error(`unexpected fswatch method ${methodID}`);
  }, { FinalizationRegistry: harness.FakeFinalizationRegistry });

  const watcher = await context.EJSFSWatch.watch("file.txt", (type, filePath) => {
    events.push(`${type}:${filePath}`);
  });
  assert.strictEqual(watcher.id, "watch-finalizer");
  assert.strictEqual(harness.records[0].type, "register");
  assert.strictEqual(harness.records[0].heldValue, "watch-finalizer");

  await harness.instances[0].callback("watch-finalizer");
  context.__EJSFSWatchDispatch("watch-finalizer", "change", "file.txt");
  assert.deepStrictEqual(events, []);
  assert.deepStrictEqual(calls.map((call) => call.methodID), ["watch", "close"]);
  assert.deepStrictEqual(calls[1].payload, { watcherID: "watch-finalizer" });
}

async function testStdlibWrappers() {
  const context = install("modules/stdlib/hashing/js/hashing.js", async (moduleID, methodID, payload, transferBuffer) => {
    assert.strictEqual(moduleID, "ejs.hashing");
    assert.strictEqual(methodID, "digest");
    const request = JSON.parse(payload);
    const data = Buffer.from(transferBuffer.buffer, transferBuffer.byteOffset, transferBuffer.byteLength).toString("utf8");
    return jsonBytes({ digest: `${request.algorithm}:${request.encoding}:${data}` });
  });
  const uuidSource = fs.readFileSync(path.join(repoRoot, "modules/stdlib/uuid/js/uuid.js"), "utf8");
  context.__ejs_native__.invoke = async (moduleID, methodID) => {
    assert.strictEqual(moduleID, "ejs.uuid");
    assert.strictEqual(methodID, "v4");
    return jsonBytes({ uuid: "123e4567-e89b-42d3-a456-426614174000" });
  };
  vm.runInContext(uuidSource, context, { filename: "modules/stdlib/uuid/js/uuid.js" });

  context.__ejs_native__.invoke = async (moduleID, methodID, payload, transferBuffer) => {
    if (moduleID === "ejs.hashing") {
      const request = JSON.parse(payload);
      const data = Buffer.from(transferBuffer.buffer, transferBuffer.byteOffset, transferBuffer.byteLength).toString("utf8");
      return jsonBytes({ digest: `${request.algorithm}:${request.encoding}:${data}` });
    }
    if (moduleID === "ejs.uuid") {
      return jsonBytes({ uuid: "123e4567-e89b-42d3-a456-426614174000" });
    }
    throw new Error(`unexpected module ${moduleID}`);
  };

  await runInContext(context, `
    assert.strictEqual(await EJSHashing.sha256("abc"), "sha256:hex:abc");
    assert.strictEqual(await EJSHashing.sha512("abc", { encoding: "base64" }), "sha512:base64:abc");
    assert.strictEqual(await EJSUUID.v4(), "123e4567-e89b-42d3-a456-426614174000");
    assert.strictEqual(await EJSUUID.randomUUID(), "123e4567-e89b-42d3-a456-426614174000");
    assert.strictEqual(EJSUUID.validate("123e4567-e89b-42d3-a456-426614174000"), true);
    assert.strictEqual(EJSUUID.validate("nope"), false);
  `);
  await assert.rejects(
    () => runInContext(context, "await EJSHashing.sha256('abc', { encoding: 'binary' });"),
    /hash encoding/
  );
  await assert.rejects(
    () => runInContext(context, "await EJSHashing.sha256({});"),
    /hash data/
  );
}

(async function main() {
  await testFSWrapper();
  await testFSFinalizerCleanup();
  testBufferWrapper();
  testPathWrapper();
  await testSystemWrapper();
  await testFSWatchWrapper();
  await testFSWatchFinalizerCleanup();
  await testStdlibWrappers();
  console.log("phase1_modules_js_test PASS");
})().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
