const seen = [];

queueMicrotask(() => {
  seen.push("microtask");
});

await Promise.resolve();

await new Promise((resolve, reject) => {
  let fired = false;
  const id = setTimeout(() => {
    fired = true;
    resolve();
  }, 20);

  if (!id) {
    reject(new Error("setTimeout returned falsy id"));
  }

  setTimeout(() => {
    if (!fired) {
      clearTimeout(id);
      reject(new Error("setTimeout failed to fire"));
    }
  }, 200);
});

if (seen[0] !== "microtask") {
  throw new Error("queueMicrotask ordering regression");
}

console.log("timer ok");
