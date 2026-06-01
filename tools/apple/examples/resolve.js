if (!globalThis.EJSPath || !EJSPath.posix || typeof EJSPath.posix.resolve !== "function") {
  throw new Error("EJSPath.posix.resolve is not available");
}

const result = EJSPath.posix.resolve("foo", "bar", "..", "baz.txt");
const base = EJSPath.posix.basename(result);
const dir = EJSPath.posix.dirname(result);
const ext = EJSPath.posix.extname(result);

console.log(`resolve: ${result}`);
console.log(`basename: ${base}`);
console.log(`dirname: ${dir}`);
console.log(`extname: ${ext}`);
