function fail(message) {
  throw new Error(message);
}

if (!Array.isArray(process.argv)) {
  fail(`process.argv should be an array, got ${typeof process.argv}`);
}

if (typeof process.pid !== "number" || process.pid <= 0) {
  fail(`invalid process.pid: ${process.pid}`);
}

if (typeof process.cwd() !== "string" || process.cwd().length === 0) {
  fail(`invalid process.cwd(): ${process.cwd()}`);
}

const pathEnv = process.env("PATH");
if (pathEnv !== undefined && typeof pathEnv !== "string") {
  fail(`invalid PATH env value: ${typeof pathEnv}`);
}

console.log(`[process] pid=${process.pid}`);
console.log(`[process] argvLen=${process.argv.length}`);
console.log(`[process] cwd=${process.cwd()}`);
await process.stdout.write(`stdout: process ok pid=${process.pid}\n`);
await process.stderr.write("stderr: process check ok\n");
