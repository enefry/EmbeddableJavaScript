const root = "tmp";
const basePath = `ejs-apple-cli-example-${process.pid}`;
const target = `${basePath}/demo.txt`;

try {
  await fs.promises.mkdir(basePath, { root, recursive: true });
  await fs.promises.writeFile(target, "hello apple", { root, encoding: "utf8", flag: "w" });

  const content = await fs.promises.readFile(target, { root, encoding: "utf8" });
  if (content !== "hello apple") {
    throw new Error(`Unexpected file content: ${content}`);
  }

  const exists = await fs.promises.exists(target, { root });
  if (!exists) {
    throw new Error("File should exist after write");
  }

  const entries = await fs.promises.readdir(basePath, { root });
  if (!Array.isArray(entries) || entries.length !== 1) {
    throw new Error("readdir result mismatch");
  }

  const stat = await fs.promises.stat(target, { root });
  if (!stat || typeof stat.isFile !== "function" || !stat.isFile()) {
    throw new Error("stat should report a regular file");
  }

  await fs.promises.unlink(target, { root });
  const removed = await fs.promises.exists(target, { root });
  if (removed) {
    throw new Error("File should be removed");
  }

  console.log(`fs ok for ${basePath}`);
} finally {
  await fs.promises.rm(basePath, { root, recursive: true, force: true });
}
