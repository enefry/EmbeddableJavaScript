const worker = new Worker("tools/apple/examples/worker.js", { name: "hello-workers-example" });

const result = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    reject(new Error("Worker timeout"));
  }, 2000);

  worker.onmessage = (event) => {
    clearTimeout(timer);
    resolve(event.data);
  };

  worker.onerror = (event) => {
    clearTimeout(timer);
    reject(new Error(event.message || "Worker runtime error"));
  };

  worker.postMessage("hello from main thread");
});

worker.terminate();

if (!result || result.echo !== "hello from main thread" || result.worker !== true) {
  throw new Error("Worker result format mismatch");
}

console.log(`hello! ${JSON.stringify(result)}`);
