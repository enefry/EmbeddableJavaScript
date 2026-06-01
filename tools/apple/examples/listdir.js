const target = process.argv[2] || ".";
const root = process.argv[3] || "cwd";

const entries = await fs.promises.readdir(target, { root });
if (!Array.isArray(entries)) {
  throw new Error(`Expected array from readdir, got ${typeof entries}`);
}

for (const entry of entries) {
  if (typeof entry === "string") {
    console.log(entry);
  } else if (entry && typeof entry === "object") {
    console.log(JSON.stringify(entry));
  } else {
    console.log(String(entry));
  }
}

console.log(`[listdir] count=${entries.length}`);
