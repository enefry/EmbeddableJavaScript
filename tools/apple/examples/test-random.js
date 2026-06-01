if (typeof crypto?.getRandomValues !== "function") {
  throw new Error("crypto.getRandomValues is unavailable");
}

const values = [
  new Uint8Array(8),
  new Int16Array(4),
  new Uint32Array(2),
];

for (const typed of values) {
  crypto.getRandomValues(typed);
  if (typed.length === 0) {
    throw new Error("random values length is zero");
  }
}

const empty = new Uint8Array(0);
crypto.getRandomValues(empty);
console.log(`random ok`);
