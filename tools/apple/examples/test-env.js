const env = process.env();

if (env === undefined || env === null || typeof env !== "object") {
  throw new Error("process.env() should return an object");
}

const pathEnv = process.env("PATH");
if (pathEnv !== undefined && pathEnv !== null && typeof pathEnv !== "string") {
  throw new Error(`Unexpected PATH value type: ${typeof pathEnv}`);
}

console.log(`[env] PATH=${pathEnv || ""}`);
console.log(`[env] keyCount=${Object.keys(env).length}`);
