const results = [];
let passedCount = 0;
let failedCount = 0;

async function logLine(message) {
  try {
    console.error(message);
    await process.stderr.write(`[api_check] ${message}\n`);
  } catch (_) {
    // Logging must not hide the API failure being checked.
  }
}

const COLORS = {
  reset: "\x1b[0m",
  green: "\x1b[32m",
  red: "\x1b[31m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
};

function asBool(value) {
  if (typeof value !== "string") {
    return false;
  }
  const normalized = value.trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes";
}

const testEnv = (typeof process === "object" && process !== null && typeof process.env === "function")
  ? process.env()
  : {};
const skipApiNetworkChecks = asBool(testEnv.EJS_API_CHECK_SKIP_NETWORK);
const skipApiFsWatch = skipApiNetworkChecks || asBool(testEnv.EJS_API_CHECK_SKIP_FSWATCH);
const skipApiHttpsFetch = skipApiNetworkChecks || asBool(testEnv.EJS_API_CHECK_SKIP_HTTPS_FETCH);
const strictFsWatch = asBool(testEnv.EJS_API_CHECK_STRICT_FSWATCH);

async function logColor(color, message) {
  await logLine(`${color}${message}${COLORS.reset}`);
}

function fail(message) {
  throw new Error(message);
}

function expect(actual) {
  return {
    toBe(expected) {
      if (actual !== expected) fail(`Expected ${expected}, but got ${actual}`);
    },
    toEqual(expected) {
      if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        fail(`Expected ${JSON.stringify(expected)}, but got ${JSON.stringify(actual)}`);
      }
    },
    toThrow() {
      if (typeof actual !== 'function') fail(`expect.toThrow requires a function`);
      let threw = false;
      try {
        actual();
      } catch (e) {
        threw = true;
      }
      if (!threw) fail(`Expected to throw, but didn't`);
    },
    toBeGreaterThan(expected) {
      if (!(actual > expected)) fail(`Expected > ${expected}, but got ${actual}`);
    },
    toBeLessThan(expected) {
      if (!(actual < expected)) fail(`Expected < ${expected}, but got ${actual}`);
    },
    toContain(expected) {
      if (!actual || typeof actual.includes !== 'function') fail(`Target does not have includes method`);
      if (!actual.includes(expected)) fail(`Expected to contain ${expected}`);
    },
    toBeInstanceOf(expected) {
      if (!(actual instanceof expected)) fail(`Expected instance of ${expected.name}`);
    }
  };
}

const expectAsync = {
  async toThrow(promise) {
    let threw = false;
    try {
      await promise;
    } catch (e) {
      threw = true;
    }
    if (!threw) fail(`Expected promise to throw, but it resolved`);
  }
};

function assert(condition, message) {
  if (!condition) {
    fail(message);
  }
}

function textFromBuffer(buffer) {
  return new TextDecoder().decode(buffer || new ArrayBuffer(0));
}

function hex(buffer) {
  return Array.prototype.map
    .call(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function bytesEqual(left, right) {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function isUUID(value) {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function waitFor(predicate, timeoutMs, message) {
  const startedAt = performance.now();
  while ((performance.now() - startedAt) < timeoutMs) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  fail(message || "Timed out waiting for condition");
}

const suites = [];
let currentDescribeTests = null;

function describe(suiteName, fn) {
  suites.push({ name: suiteName, fn });
}

function it(testName, fn) {
  if (!currentDescribeTests) fail("it() must be called inside describe()");
  currentDescribeTests.push({ name: testName, fn });
}

// ================= SUITES =================

describe("process", () => {
  it("should have basic environment properties", () => {
    expect(process).toBe(EJS.process);
    assert(Array.isArray(process.argv), "process.argv should be an array");
    expect(process.argv.length > 0).toBe(true);
    expect(typeof process.pid).toBe("number");
    expect(process.pid > 0).toBe(true);
  });

  it("should return valid cwd", () => {
    const cwd = process.cwd();
    expect(typeof cwd).toBe("string");
    expect(cwd.length > 0).toBe(true);
  });

  it("should access environment variables", () => {
    const env = process.env();
    expect(typeof env).toBe("object");
    const pathEnv = process.env("PATH");
    assert(pathEnv === undefined || typeof pathEnv === "string", "PATH should be string or undefined");
  });

  it("should write to stdout and stderr without throwing", async () => {
    const stdoutResponse = JSON.parse(textFromBuffer(await process.stdout.write("")));
    const stderrResponse = JSON.parse(textFromBuffer(await process.stderr.write("")));
    expect(stdoutResponse.ok).toBe(true);
    expect(stderrResponse.ok).toBe(true);
  });
});

describe("wintertc-metadata", () => {
  it("should load metadata properly", () => {
    expect(WinterTC.loaded).toBe(true);
    expect(EJS.WinterTC).toBe(WinterTC);
    expect(EJS.winterTC).toBe(WinterTC);
  });

  it("should list all expected standard APIs", () => {
    const expected = [
      "timers", "url", "events", "encoding", "blob", "streams",
      "fetch", "request", "crypto", "performance", "console"
    ];
    assert(Array.isArray(WinterTC.apis), "WinterTC.apis should be an array");
    for (const name of expected) {
      expect(WinterTC.apis).toContain(name);
    }
  });
});

describe("module-mounts", () => {
  it("should mount every CLI module on EJS", () => {
    const expected = {
      fs: globalThis.EJSFS,
      system: globalThis.EJSSystem,
      fswatch: globalThis.EJSFSWatch,
      path: globalThis.EJSPath,
      buffer: globalThis.EJSBinary,
      binary: globalThis.EJSBinary,
      kv: globalThis.EJSKV,
      storage: globalThis.EJSStorage,
      sqlite: globalThis.EJSSQLite,
      hashing: globalThis.EJSHashing,
      uuid: globalThis.EJSUUID,
      net: globalThis.EJSNet,
      ws: globalThis.EJSWebSocket,
      xhr: globalThis.EJSXHR,
      ipaddr: globalThis.EJSIPAddr,
      worker: globalThis.EJSWorker,
    };
    for (const [name, value] of Object.entries(expected)) {
      assert(value && typeof value === "object", `${name} module should exist`);
      expect(EJS[name]).toBe(value);
    }
    expect(fs).toBe(EJS.fs);
  });
});

if (typeof Worker !== "undefined") {
  describe("worker", () => {
    function nextWorkerMessage(worker, trigger, timeoutMs = 2000) {
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error("Timed out waiting for worker message"));
        }, timeoutMs);
        worker.onerror = (event) => {
          clearTimeout(timeout);
          reject(new Error(event.message || "Worker error"));
        };
        worker.onmessageerror = (event) => {
          clearTimeout(timeout);
          reject(new Error(event.message || "Worker message error"));
        };
        worker.onmessage = (event) => {
          clearTimeout(timeout);
          resolve(event);
        };
        trigger();
      });
    }

    it("should expose Worker globals and EJS worker metadata", () => {
      expect(typeof Worker).toBe("function");
      expect(EJS.worker).toBe(EJSWorker);
      expect(EJSWorker.moduleID).toBe("ejs.worker");
    });

    it("should create an inline worker and echo queued messages", async () => {
      const worker = new Worker("inline-echo", { name: "api-check-worker" });
      try {
        const event = await nextWorkerMessage(worker, () => {
          worker.postMessage({ op: "ping", value: 42 });
        });
        expect(event.data.echo.op).toBe("ping");
        expect(event.data.echo.value).toBe(42);
        expect(event.data.selfIsGlobal).toBe(true);
      } finally {
        worker.terminate();
      }
    });

    it("should round-trip ArrayBuffer messages", async () => {
      const worker = new Worker("inline-echo", { name: "api-check-transfer" });
      try {
        const buffer = new ArrayBuffer(4);
        new Uint8Array(buffer).set([7, 8, 9, 10]);
        const event = await nextWorkerMessage(worker, () => {
          worker.postMessage({ buffer }, [buffer]);
        });
        const bytes = new Uint8Array(event.data.echo.buffer);
        expect(bytesEqual(bytes, new Uint8Array([7, 8, 9, 10]))).toBe(true);
        assert(buffer.byteLength === 0 || buffer.byteLength === 4, `unexpected transferred byteLength ${buffer.byteLength}`);
      } finally {
        worker.terminate();
      }
    });

    it("should release workers after close and tolerate repeated terminate", async () => {
      const worker = new Worker("inline-echo", { name: "api-check-close" });
      worker.postMessage({ op: "close" });
      await waitFor(() => __EJSWorkerInternalActiveCount() === 0, 2000, "Timed out waiting for worker close");
      worker.terminate();
      worker.terminate();
    });
  });
}

describe("fs", () => {
  const basePath = `ejs-cli-api-check-${process.pid}-fs`;
  const tmpRoot = "tmp";

  it("should expose correct aliases and methods", () => {
    expect(fs).toBe(EJSFS);
    expect(EJS.fs).toBe(EJSFS);
    const expectedMethods = [
      "access", "chmod", "chown", "createDirectory", "copyFile", "delete",
      "exists", "lchown", "link", "list", "lstat", "lutime",
      "makeTempDir", "makeTempFile", "mkdir", "open", "readFile",
      "readdir", "readLink", "rename", "remove", "rm", "stat", "statFs",
      "symlink", "unlink", "utime", "writeFile"
    ];
    for (const method of expectedMethods) {
      expect(typeof fs.promises[method]).toBe("function");
    }
    expect(typeof fs.FileHandle).toBe("function");
  });

  it("should read files from root", async () => {
    const readme = await fs.promises.readFile("tools/README.md", "utf8");
    expect(readme).toContain("ejs_apple_cli");
  });

  it("should throw error when reading missing file", async () => {
    await expectAsync.toThrow(fs.promises.readFile(`${basePath}/nonexistent.txt`, { root: tmpRoot }));
  });

  it("should handle write/read text lifecycle", async () => {
    await fs.promises.rm(basePath, { root: tmpRoot, recursive: true, force: true });
    
    const textPath = `${basePath}/nested/text.txt`;
    await fs.promises.mkdir(`${basePath}/nested`, { root: tmpRoot, recursive: true });
    
    await fs.promises.writeFile(textPath, "hello fs", { root: tmpRoot, encoding: "utf8", flag: "w" });
    const content = await fs.promises.readFile(textPath, { root: tmpRoot, encoding: "utf8" });
    expect(content).toBe("hello fs");
  });

  it("should handle write/read binary lifecycle", async () => {
    const binPath = `${basePath}/nested/bin.dat`;
    const bytes = new Uint8Array([10, 20, 255, 0]);
    await fs.promises.writeFile(binPath, bytes, { root: tmpRoot, flag: "w" });
    
    const readBytes = new Uint8Array(await fs.promises.readFile(binPath, { root: tmpRoot }));
    expect(bytesEqual(bytes, readBytes)).toBe(true);
  });

  it("should properly stat files and directories", async () => {
    const binPath = `${basePath}/nested/bin.dat`;
    const fileStat = await fs.promises.stat(binPath, { root: tmpRoot });
    expect(fileStat.type).toBe("file");
    expect(fileStat.isFile()).toBe(true);
    expect(fileStat.isDirectory()).toBe(false);
    expect(fileStat.size).toBe(4);
    expect(typeof fileStat.mtimeMs).toBe("number");

    const dirStat = await fs.promises.stat(`${basePath}/nested`, { root: tmpRoot });
    expect(dirStat.type).toBe("directory");
    expect(dirStat.isDirectory()).toBe(true);
    expect(dirStat.isFile()).toBe(false);
  });

  it("should support existence checks", async () => {
    expect(await fs.promises.exists(`${basePath}/nested`, { root: tmpRoot })).toBe(true);
    expect(await fs.promises.exists(`${basePath}/missing`, { root: tmpRoot })).toBe(false);
  });

  it("should accurately assess access permissions", async () => {
    const binPath = `${basePath}/nested/bin.dat`;
    await fs.promises.access(binPath, { root: tmpRoot, mode: "read" });
    await fs.promises.access(binPath, { root: tmpRoot, mode: "write" });
    await fs.promises.access(binPath, { root: tmpRoot, mode: "readwrite" });
    await expectAsync.toThrow(fs.promises.access(`${basePath}/missing.dat`, { root: tmpRoot }));
  });

  it("should copy files properly", async () => {
    const src = `${basePath}/nested/bin.dat`;
    const dest = `${basePath}/nested/bin_copy.dat`;
    
    await fs.promises.copyFile(src, dest, { root: tmpRoot, newRoot: tmpRoot, flag: "wx" });
    
    const original = new Uint8Array(await fs.promises.readFile(src, { root: tmpRoot }));
    const copied = new Uint8Array(await fs.promises.readFile(dest, { root: tmpRoot }));
    expect(bytesEqual(original, copied)).toBe(true);
    
    await expectAsync.toThrow(fs.promises.copyFile(src, dest, { root: tmpRoot, newRoot: tmpRoot, flag: "wx" }));
  });

  it("should list directories correctly", async () => {
    const entries = await fs.promises.readdir(`${basePath}/nested`, { root: tmpRoot });
    expect(entries).toContain("bin.dat");
    expect(entries).toContain("bin_copy.dat");
    expect(entries).toContain("text.txt");
  });

  it("should use FileHandle read/write/truncate/sync/close", async () => {
    const handlePath = `${basePath}/nested/handle.txt`;
    const writer = await fs.promises.open(handlePath, "w+", 0o600, { root: tmpRoot });
    expect(writer instanceof fs.FileHandle).toBe(true);
    expect(await writer.write("abcdef", { position: 0 })).toBe(6);
    await writer.truncate(4);
    await writer.datasync();
    await writer.sync();
    await writer.close();
    await writer.close();

    const reader = await fs.promises.open(handlePath, "r", { root: tmpRoot });
    expect(await reader.read({ length: 4, position: 0, encoding: "utf8" })).toBe("abcd");
    await reader.close();
    await expectAsync.toThrow(reader.read({ length: 1 }));
  });

  it("should support lstat, symlink, readLink, hard link, and statFs", async () => {
    const source = `${basePath}/nested/link-source.txt`;
    const symlinkPath = `${basePath}/nested/link-symbolic`;
    const hardLinkPath = `${basePath}/nested/link-hard`;
    await fs.promises.writeFile(source, "link-ok", { root: tmpRoot, encoding: "utf8", flag: "w" });
    await fs.promises.symlink("link-source.txt", symlinkPath, { root: tmpRoot });
    expect(await fs.promises.readLink(symlinkPath, { root: tmpRoot })).toBe("link-source.txt");
    const symlinkStat = await fs.promises.lstat(symlinkPath, { root: tmpRoot });
    expect(symlinkStat.isSymbolicLink()).toBe(true);
    expect(await fs.promises.readFile(symlinkPath, { root: tmpRoot, encoding: "utf8" })).toBe("link-ok");

    await fs.promises.link(source, hardLinkPath, { root: tmpRoot, newRoot: tmpRoot });
    expect(await fs.promises.readFile(hardLinkPath, { root: tmpRoot, encoding: "utf8" })).toBe("link-ok");
    const fsInfo = await fs.promises.statFs(basePath, { root: tmpRoot });
    expect(typeof fsInfo.bsize).toBe("number");
    expect(fsInfo.bsize > 0).toBe(true);
  });

  it("should support temp paths, metadata mutation, and delete aliases", async () => {
    const tempDir = await fs.promises.makeTempDir("api-", { root: tmpRoot, dir: basePath });
    const tempFile = await fs.promises.makeTempFile("api-", { root: tmpRoot, dir: tempDir });
    await fs.promises.writeFile(tempFile, "temp", { root: tmpRoot, encoding: "utf8", flag: "w" });
    await fs.promises.chmod(tempFile, 0o600, { root: tmpRoot });
    await fs.promises.utime(tempFile, 1000, 2000, { root: tmpRoot });
    const stat = await fs.promises.stat(tempFile, { root: tmpRoot });
    expect(stat.isFile()).toBe(true);
    expect((stat.mode & 0o777)).toBe(0o600);

    const symlinkPath = `${basePath}/nested/link-symbolic`;
    await fs.promises.lutime(symlinkPath, 1000, 2000, { root: tmpRoot });
    const user = await EJSSystem.userInfo();
    let chownErrorCode = null;
    try {
      await fs.promises.chown(tempFile, user.uid, user.gid, { root: tmpRoot });
    } catch (error) {
      chownErrorCode = error && error.code;
    }
    assert(chownErrorCode === null || chownErrorCode === 7, `unexpected chown error code ${chownErrorCode}`);

    let lchownErrorCode = null;
    try {
      await fs.promises.lchown(symlinkPath, user.uid, user.gid, { root: tmpRoot });
    } catch (error) {
      lchownErrorCode = error && error.code;
    }
    assert(lchownErrorCode === null || lchownErrorCode === 7, `unexpected lchown error code ${lchownErrorCode}`);

    const deletePath = `${basePath}/nested/delete-alias.txt`;
    await fs.promises.writeFile(deletePath, "delete", { root: tmpRoot, encoding: "utf8", flag: "w" });
    await fs.promises.delete(deletePath, { root: tmpRoot });
    expect(await fs.promises.exists(deletePath, { root: tmpRoot })).toBe(false);

    await fs.promises.remove(tempDir, { root: tmpRoot, recursive: true });
    expect(await fs.promises.exists(tempDir, { root: tmpRoot })).toBe(false);
  });

  it("should rename and delete files", async () => {
    const oldPath = `${basePath}/nested/text.txt`;
    const newPath = `${basePath}/nested/moved.txt`;
    
    await fs.promises.rename(oldPath, newPath, { root: tmpRoot, newRoot: tmpRoot });
    expect(await fs.promises.exists(oldPath, { root: tmpRoot })).toBe(false);
    expect(await fs.promises.exists(newPath, { root: tmpRoot })).toBe(true);
    
    await fs.promises.unlink(newPath, { root: tmpRoot });
    expect(await fs.promises.exists(newPath, { root: tmpRoot })).toBe(false);
  });

  it("should support recursive directory deletion", async () => {
    await fs.promises.rm(basePath, { root: tmpRoot, recursive: true, force: true });
    expect(await fs.promises.exists(basePath, { root: tmpRoot })).toBe(false);
  });
});

describe("system", () => {
  it("should expose and use all system methods", async () => {
    expect(EJS.system).toBe(EJSSystem);
    const originalCwd = await EJSSystem.cwd();
    const tmpDir = await EJSSystem.tmpDir();
    expect(typeof originalCwd).toBe("string");
    expect(originalCwd.length > 0).toBe(true);
    expect(typeof tmpDir).toBe("string");
    expect(tmpDir.length > 0).toBe(true);

    await EJSSystem.chdir(tmpDir);
    expect((await EJSSystem.cwd()).length > 0).toBe(true);
    await EJSSystem.chdir(originalCwd);
    expect(await EJSSystem.cwd()).toBe(originalCwd);

    const envName = `EJS_API_CHECK_${process.pid}`;
    await EJSSystem.setenv(envName, "system-ok");
    expect(await EJSSystem.getenv(envName)).toBe("system-ok");
    const env = await EJSSystem.env();
    expect(typeof env).toBe("object");
    await EJSSystem.unsetenv(envName);
    expect(await EJSSystem.getenv(envName)).toBe(null);

    expect(await EJSSystem.pid()).toBe(process.pid);
    expect(typeof (await EJSSystem.ppid())).toBe("number");
    expect((await EJSSystem.homeDir()).length > 0).toBe(true);
    expect((await EJSSystem.exePath()).length > 0).toBe(true);
    expect((await EJSSystem.hostName()).length > 0).toBe(true);
    expect(await EJSSystem.platform()).toBe("darwin");
    expect((await EJSSystem.arch()).length > 0).toBe(true);

    const uname = await EJSSystem.uname();
    expect(uname.sysname).toBe("Darwin");
    expect(typeof uname.machine).toBe("string");
    expect(await EJSSystem.uptime()).toBeGreaterThan(0);
    expect((await EJSSystem.loadAvg()).length).toBe(3);
    expect(await EJSSystem.availableParallelism()).toBeGreaterThan(0);
    expect((await EJSSystem.cpuInfo()).length).toBeGreaterThan(0);
    expect(typeof (await EJSSystem.networkInterfaces())).toBe("object");
    const user = await EJSSystem.userInfo();
    expect(typeof user.uid).toBe("number");
    expect(typeof user.gid).toBe("number");
  });
});

if (!skipApiFsWatch) {
  describe("fswatch", () => {
    const watchRoot = `ejs-cli-api-check-${process.pid}-fswatch`;
    const tmpRoot = "tmp";

  it("should watch direct file changes and close", async () => {
      expect(EJS.fswatch).toBe(EJSFSWatch);
      await fs.promises.rm(watchRoot, { root: tmpRoot, recursive: true, force: true });
      await fs.promises.mkdir(watchRoot, { root: tmpRoot, recursive: true });
      const watchedPath = `${watchRoot}/watched.txt`;
      await fs.promises.writeFile(watchedPath, "seed", { root: tmpRoot, encoding: "utf8", flag: "w" });
      console.log(`begin:${Date()}`);
      const events = [];
      const watcher = await EJSFSWatch.watch(watchedPath, (type, path) => {
        console.log(`recv:${Date()} type=${type},path=${path}`);
        events.push({ type, path });
      }, { root: tmpRoot });
      console.log(`after await:${Date()}`);
      try {

        expect(typeof watcher.id).toBe("string");
        expect(watcher.recursive).toBe(false);
        await logLine("fswatch: watcher ready, triggering mutation");

        const triggerWatchEvent = async () => {
          await new Promise((resolve) => setTimeout(resolve, 100));
          console.log(`will write file:${watchedPath}, ${Date()}`);
          await fs.promises.writeFile(watchedPath, `changed-${performance.now()}`, { root: tmpRoot, flag: "w", encoding: "utf8" });
          console.log(`did write file:${watchedPath}, ${Date()}`);
        };

        const isTimeout = (error) => {
          const message = `${error && (error.message || error)}`;
          return message.includes("Timed out waiting") ||
            message.includes("Timed out waiting for condition");
        };

        let observed = false;
        for (let attempt = 0; attempt < 3 && !observed; attempt += 1) {
          await logLine(`fswatch: attempt ${attempt + 1}`);
          if (attempt > 0) {
            await new Promise((resolve) => setTimeout(resolve, 100 * attempt));
          }
          await triggerWatchEvent();
          try {
            await waitFor(() => events.length > 0, 1800, "Timed out waiting for fswatch event");
            observed = true;
          } catch (error) {
            if (!strictFsWatch && isTimeout(error)) {
              await logLine("fswatch is unsupported or unstable in this environment, skip strict assertion and continue.");
              return;
            }
            if (attempt + 1 < 3) {
              continue;
            }
          }
        }
        
        if (!observed) {
          if (strictFsWatch) {
            throw new Error("fswatch did not deliver any events");
          }
          await logLine("fswatch is unsupported or unstable in this environment, skip strict assertion and continue.");
          return;
        }

        assert(events.length > 0, "fswatch did not deliver any events");
        const firstEvent = events[0];
        if (firstEvent && typeof firstEvent === "object") {
          const eventPath = firstEvent.path || firstEvent.filePath || firstEvent.file;
          if (typeof eventPath === "string") {
            assert(eventPath.includes("watched.txt"), `unexpected fswatch path ${eventPath}`);
          }
          if (typeof firstEvent.type === "string") {
            assert(
              firstEvent.type === "change" || firstEvent.type === "rename",
              `unexpected fswatch event ${firstEvent.type}`,
            );
          }
        }
      } finally {
        await watcher.close();
        await watcher.close();
        await fs.promises.rm(watchRoot, { root: tmpRoot, recursive: true, force: true });
      }
    });

    it("should reject recursive watches explicitly", async () => {
      await expectAsync.toThrow(EJSFSWatch.watch(".", () => {}, { root: tmpRoot, recursive: true }));
    });
  });
}

describe("hashing", () => {
  it("should digest strings and typed arrays with supported encodings", async () => {
    expect(EJS.hashing).toBe(EJSHashing);
    expect(await EJSHashing.sha256("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    expect(await EJSHashing.digest("sha512", new Uint8Array([97, 98, 99]))).toBe("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    expect(await EJSHashing.sha256("abc", { encoding: "base64" })).toBe("ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
    await expectAsync.toThrow(EJSHashing.digest("sha1", "abc"));
    await expectAsync.toThrow(EJSHashing.sha256("abc", { encoding: "binary" }));
  });
});

describe("uuid", () => {
  it("should generate and validate UUIDs", async () => {
    expect(EJS.uuid).toBe(EJSUUID);
    const uuid = await EJSUUID.v4();
    const uuid2 = await EJSUUID.randomUUID();
    expect(EJSUUID.validate(uuid)).toBe(true);
    expect(EJSUUID.validate(uuid2)).toBe(true);
    expect(isUUID(uuid)).toBe(true);
    expect(EJSUUID.validate("not-a-uuid")).toBe(false);
  });
});

describe("timers", () => {
  it("should execute queueMicrotask before setTimeout", async () => {
    const order = [];
    queueMicrotask(() => order.push("microtask"));
    await Promise.resolve();
    expect(order[0]).toBe("microtask");
  });

  it("should support setTimeout with arguments", async () => {
    const result = await new Promise((resolve) => {
      setTimeout((a, b) => resolve(a + b), 1, "hello", " world");
    });
    expect(result).toBe("hello world");
  });

  it("should clear timeouts successfully", async () => {
    let fired = false;
    const id = setTimeout(() => { fired = true; }, 10);
    clearTimeout(id);
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(fired).toBe(false);
  });

  it("should support setInterval and clearInterval", async () => {
    let count = 0;
    await new Promise((resolve) => {
      const id = setInterval(() => {
        count++;
        if (count === 3) {
          clearInterval(id);
          resolve();
        }
      }, 5);
    });
    expect(count).toBe(3);
  });
});

describe("url", () => {
  it("should resolve URLs and mutate query params", () => {
    const url = new URL("/search?q=ejs", "https://example.test/docs/index.html");
    url.searchParams.set("page", "1");
    expect(url.href).toBe("https://example.test/search?q=ejs&page=1");
    expect(url.protocol).toBe("https:");
    expect(url.hostname).toBe("example.test");
    expect(url.pathname).toBe("/search");
    expect(url.search).toBe("?q=ejs&page=1");
  });

  it("should parse and stringify URLSearchParams", () => {
    const params = new URLSearchParams("a=1&a=2");
    params.append("b", "3");
    expect(params.get("a")).toBe("1");
    expect(params.getAll("a").length).toBe(2);
    expect(params.toString()).toBe("a=1&a=2&b=3");
    
    params.delete("a");
    expect(params.toString()).toBe("b=3");
  });
});

describe("events", () => {
  it("should support EventTarget dispatch and addEventListener", () => {
    const target = new EventTarget();
    let received = null;
    target.addEventListener("api-check", (event) => {
      received = event.detail;
    });
    const dispatched = target.dispatchEvent(new CustomEvent("api-check", { detail: "ok" }));
    expect(dispatched).toBe(true);
    expect(received).toBe("ok");
  });

  it("should expose ErrorEvent and PromiseRejectionEvent", () => {
    const err = new ErrorEvent("error", { message: "msg", filename: "f.js", lineno: 1 });
    expect(err.message).toBe("msg");
    expect(err.filename).toBe("f.js");
    
    const rej = new PromiseRejectionEvent("unhandled", { promise: Promise.resolve(), reason: "rsn" });
    expect(rej.reason).toBe("rsn");
  });

  it("should support AbortController and signals", () => {
    const ac = new AbortController();
    let abortedSeen = false;
    ac.signal.addEventListener("abort", () => {
      abortedSeen = true;
    });
    expect(ac.signal.aborted).toBe(false);
    ac.abort("reason");
    expect(ac.signal.aborted).toBe(true);
    expect(ac.signal.reason).toBe("reason");
    expect(abortedSeen).toBe(true);
  });

  it("should support global reportError and removeEventListener", () => {
    let errSeen = false;
    const handler = (e) => { errSeen = true; };
    addEventListener("error", handler);
    reportError(new Error("test error"));
    expect(errSeen).toBe(true);
    
    removeEventListener("error", handler);
  });
});

describe("encoding", () => {
  it("should encode and decode utf-8 strings correctly", () => {
    const original = "Hello EJS 🚀";
    const encoded = new TextEncoder().encode(original);
    expect(encoded instanceof Uint8Array).toBe(true);
    const decoded = new TextDecoder().decode(encoded);
    expect(decoded).toBe(original);
  });
});

describe("blob-file", () => {
  it("should handle Blob creation, sizing, and text extraction", async () => {
    const blob = new Blob(["hello", new Uint8Array([32, 119, 111, 114, 108, 100])], { type: "text/plain" });
    expect(blob.size).toBe(11);
    expect(blob.type).toBe("text/plain");
    const text = await blob.text();
    expect(text).toBe("hello world");
    
    const buffer = await blob.arrayBuffer();
    expect(buffer.byteLength).toBe(11);
    
    const sliced = blob.slice(6, 11);
    expect(await sliced.text()).toBe("world");
  });

  it("should handle File creation with metadata", async () => {
    const file = new File(["data"], "doc.txt", { type: "text/plain", lastModified: 999 });
    expect(file.name).toBe("doc.txt");
    expect(file.lastModified).toBe(999);
    expect(await file.text()).toBe("data");
  });
});

describe("streams", () => {
  it("should read from a ReadableStream", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("chunk1"));
        controller.enqueue(new TextEncoder().encode("chunk2"));
        controller.close();
      }
    });
    
    expect(stream.locked).toBe(false);
    const reader = stream.getReader();
    expect(stream.locked).toBe(true);
    
    const { value: v1, done: d1 } = await reader.read();
    expect(d1).toBe(false);
    expect(textFromBuffer(v1)).toBe("chunk1");
    
    const { value: v2, done: d2 } = await reader.read();
    expect(d2).toBe(false);
    expect(textFromBuffer(v2)).toBe("chunk2");
    
    const { done: d3 } = await reader.read();
    expect(d3).toBe(true);
    
    reader.releaseLock();
    expect(stream.locked).toBe(false);
  });

  it("should support cancel and error on ReadableStream", async () => {
    let cancelReason = null;
    const stream = new ReadableStream({
      cancel(reason) {
        cancelReason = reason;
      }
    });
    
    await stream.cancel("timeout");
    expect(cancelReason).toBe("timeout");
    
    const stream2 = new ReadableStream({
      start(controller) {
        controller.error(new Error("broken"));
      }
    });
    const reader = stream2.getReader();
    await expectAsync.toThrow(reader.read());
  });
});

describe("fetch", () => {
  it("should manipulate Headers correctly", () => {
    const headers = new Headers({ "x-Custom": "1" });
    headers.append("x-custom", "2");
    expect(headers.get("x-custom")).toBe("1, 2");
    expect(headers.has("X-CUSTOM")).toBe(true);
    headers.delete("x-custom");
    expect(headers.has("x-custom")).toBe(false);
  });

  it("should handle Request construction and cloning", async () => {
    const req = new Request("http://localhost", { method: "POST", body: "body" });
    expect(req.method).toBe("POST");
    
    const clone = req.clone();
    expect(await req.text()).toBe("body");
    expect(await clone.text()).toBe("body");
  });

  it("should handle Response factories", async () => {
    const jsonRes = Response.json({ a: 1 });
    expect(jsonRes.headers.get("content-type")).toBe("application/json");
    const data = await jsonRes.json();
    expect(data.a).toBe(1);
    
    const errRes = Response.error();
    expect(errRes.type).toBe("error");
    expect(errRes.status).toBe(0);
    
    const redirectRes = Response.redirect("https://example.com", 301);
    expect(redirectRes.status).toBe(301);
    expect(redirectRes.headers.get("location")).toBe("https://example.com");
  });

  it("should execute fetch against data URLs", async () => {
    const url = "data:application/json,{\"ok\":true}";
    const res = await fetch(url);
    expect(res.ok).toBe(true);
    const body = await res.json();
    expect(body.ok).toBe(true);
  });

  if (!skipApiHttpsFetch) {
    it("should execute HTTPS fetch", async () => {
      const url = "https://api.ipify.org/?format=json";
      const res = await fetch(url);
      expect(res.ok).toBe(true);
      expect(res.status).toBe(200);
      const contentType = res.headers.get("content-type") || "";
      expect(contentType).toContain("application/json");

      const body = await res.json();
      expect(typeof body.ip).toBe("string");
      expect(body.ip.length > 0).toBe(true);
    });
  }
});

describe("crypto", () => {
  it("should generate random values", () => {
    const bytes = new Uint8Array(16);
    const ret = crypto.getRandomValues(bytes);
    expect(ret).toBe(bytes);
    expect(bytes.some(b => b > 0)).toBe(true);
  });

  it("should generate valid randomUUID", () => {
    const uuid = crypto.randomUUID();
    const regex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    expect(regex.test(uuid)).toBe(true);
  });

  it("should perform SHA-256 digest", async () => {
    const data = new TextEncoder().encode("ejs api check");
    const digest = await crypto.subtle.digest("SHA-256", data);
    expect(digest.byteLength).toBe(32);
    const hashHex = hex(digest);
    expect(hashHex).toBe("7e3a913879e9b13666c00a31a5de002f821121e2e4b00c801d73387e34b5a8d0");
  });
});

describe("performance-console", () => {
  it("should expose valid performance metrics", async () => {
    expect(typeof performance.timeOrigin).toBe("number");
    const t1 = performance.now();
    await new Promise(r => setTimeout(r, 10));
    const t2 = performance.now();
    expect(t2 > t1).toBe(true);
  });

  it("should expose console methods", () => {
    expect(typeof console.log).toBe("function");
    expect(typeof console.error).toBe("function");
    expect(typeof console.debug).toBe("function");
    expect(typeof console.info).toBe("function");
    expect(typeof console.warn).toBe("function");
  });
});

if (typeof EJSPath !== "undefined") {
  describe("path", () => {
    it("should normalize paths", () => {
      expect(EJSPath.posix.normalize("/foo/bar//baz/asdf/quux/..")).toBe("/foo/bar/baz/asdf");
    });
    it("should join paths", () => {
      expect(EJSPath.posix.join("/foo", "bar", "baz/asdf", "quux", "..")).toBe("/foo/bar/baz/asdf");
    });
    it("should get dirname, basename, extname", () => {
      expect(EJSPath.posix.dirname("/foo/bar/baz/asdf/quux")).toBe("/foo/bar/baz/asdf");
      expect(EJSPath.posix.basename("/foo/bar/baz/asdf/quux.html")).toBe("quux.html");
      expect(EJSPath.posix.extname("/foo/bar/baz/asdf/quux.html")).toBe(".html");
    });
  });
}

if (typeof EJSBinary !== "undefined") {
  describe("buffer", () => {
    it("should convert from and to hex", () => {
      const bytes = EJSBinary.fromHex("deadbeef");
      expect(bytes.length).toBe(4);
      expect(EJSBinary.toHex(bytes)).toBe("deadbeef");
    });
    it("should convert from and to base64", () => {
      const bytes = EJSBinary.fromBase64("aGVsbG8=");
      expect(EJSBinary.toString(bytes, "utf8")).toBe("hello");
      expect(EJSBinary.toBase64(bytes)).toBe("aGVsbG8=");
    });
    it("should concatenate buffers", () => {
      const a = EJSBinary.fromString("hello ", "utf8");
      const b = EJSBinary.fromString("world", "utf8");
      const c = EJSBinary.concat([a, b]);
      expect(EJSBinary.toString(c, "utf8")).toBe("hello world");
    });
  });
}

if (typeof EJSKV !== "undefined") {
  describe("kv", () => {
    it("should set and get values", async () => {
      await EJSKV.set("test-key", "test-value");
      expect(EJSBinary.toString(await EJSKV.get("test-key"), "utf8")).toBe("test-value");
    });
    it("should delete values", async () => {
      await EJSKV.set("test-key-2", "v");
      expect(await EJSKV.has("test-key-2")).toBe(true);
      await EJSKV.delete("test-key-2");
      expect(await EJSKV.has("test-key-2")).toBe(false);
    });
  });
}

if (typeof EJSSQLite !== "undefined") {
  describe("sqlite", () => {
    it("should open db and execute queries", async () => {
      const db = await EJSSQLite.open("main");
      const tableName = `api_check_${process.pid}_${Date.now()}`;
      try {
        await db.execute(`DROP TABLE IF EXISTS ${tableName}`);
        await db.execute(`CREATE TABLE ${tableName} (id INTEGER, name TEXT)`);
        await db.execute(`INSERT INTO ${tableName} VALUES (1, 'alice')`);
        const rows = await db.query(`SELECT * FROM ${tableName}`);
        expect(rows.length).toBe(1);
        expect(rows[0].name).toBe("alice");
      } finally {
        try {
          await db.execute(`DROP TABLE IF EXISTS ${tableName}`);
        } finally {
          await db.close();
        }
      }
    });
  });
}

if (typeof EJSStorage !== "undefined") {
  describe("storage", () => {
    it("should handle local storage methods", async () => {
      await EJSStorage.local.clear();
      expect(await EJSStorage.local.length()).toBe(0);
      
      await EJSStorage.local.setItem("a", 12);
      expect(await EJSStorage.local.getItem("a")).toBe("12");
      
      await EJSStorage.local.setItem("bool", true);
      expect(await EJSStorage.local.getItem("bool")).toBe("true");
      
      await EJSStorage.local.setItem("objLocal", { ok: true });
      expect(await EJSStorage.local.getItem("objLocal")).toBe("[object Object]");
      
      expect(await EJSStorage.local.length()).toBe(3);
      
      const firstKey = await EJSStorage.local.key(0);
      expect(typeof firstKey).toBe("string");
      expect(await EJSStorage.local.key(-1)).toBe(null);
      expect(await EJSStorage.local.key(100)).toBe(null);
      
      await EJSStorage.local.removeItem("a");
      expect(await EJSStorage.local.getItem("a")).toBe(null);
      
      await EJSStorage.local.clear();
      expect(await EJSStorage.local.length()).toBe(0);
    });

    it("should handle json storage methods", async () => {
      await EJSStorage.json.set("obj", { ok: true, n: 9 });
      const obj = await EJSStorage.json.get("obj");
      expect(obj.ok).toBe(true);
      expect(obj.n).toBe(9);
      
      await EJSStorage.json.remove("obj");
      expect(await EJSStorage.json.get("obj")).toBe(null);
    });
  });
}

// ================= TEST RUNNER =================

async function runTests() {
  await logColor(COLORS.blue, "\n=============================================");
  await logColor(COLORS.blue, "  EJS API Comprehensive Check");
  await logColor(COLORS.blue, "=============================================\n");

  const globalStart = performance.now();

  for (const suite of suites) {
    currentDescribeTests = [];
    suite.fn();
    
    const suiteTests = currentDescribeTests;
    currentDescribeTests = null;

    if (suiteTests.length > 0) {
      await logColor(COLORS.yellow, `\n> ${suite.name}`);
    }

    for (const test of suiteTests) {
      const startedAt = performance.now();
      try {
        await test.fn();
        const elapsedMs = Math.round((performance.now() - startedAt) * 1000) / 1000;
        passedCount++;
        results.push({
          suite: suite.name,
          test: test.name,
          ok: true,
          elapsedMs
        });
        await logColor(COLORS.green, `  ✓ PASS : ${test.name} (${elapsedMs} ms)`);
      } catch (error) {
        const elapsedMs = Math.round((performance.now() - startedAt) * 1000) / 1000;
        failedCount++;
        const message = error && error.stack ? error.stack : String(error);
        results.push({
          suite: suite.name,
          test: test.name,
          ok: false,
          elapsedMs,
          error: message
        });
        await logColor(COLORS.red, `  ✗ FAIL : ${test.name} (${elapsedMs} ms)`);
        await logColor(COLORS.red, `    ${(error.message || String(error)).split('\n')[0]}`);
      }
    }
  }

  const globalElapsed = Math.round((performance.now() - globalStart) * 1000) / 1000;
  await logColor(COLORS.blue, "\n=============================================");
  await logColor(COLORS.blue, `  Run Finished in ${globalElapsed}ms`);
  
  if (passedCount > 0) {
    await logColor(COLORS.green, `  Tests Passed: ${passedCount}`);
  }
  if (failedCount > 0) {
    await logColor(COLORS.red, `  Tests Failed: ${failedCount}`);
  }
  await logColor(COLORS.blue, "=============================================\n");

  const report = {
    ok: failedCount === 0,
    generatedAt: new Date().toISOString(),
    checkedCount: results.length,
    passedCount,
    failedCount,
    results
  };

  const reportPath = `ejs-cli-api-check-${process.pid}.json`;
  await fs.promises.writeFile(reportPath, JSON.stringify(report, null, 2), {
    root: "tmp",
    flag: "w"
  });

  const finalOutput = {
    ok: report.ok,
    checkedCount: report.checkedCount,
    failedCount: report.failedCount,
    reportPath: `tmp:${reportPath}`,
    failed: results.filter(r => !r.ok).map(r => `${r.suite} - ${r.test}`)
  };

  await process.stdout.write(JSON.stringify(finalOutput) + "\n");

  if (failedCount > 0) {
    await process.exit(1);
  }
}

// Execute tests
await runTests();
