if (!Array.isArray(process.argv)) {
  throw new Error("process.argv should be an array");
}

console.log(JSON.stringify(process.argv));
