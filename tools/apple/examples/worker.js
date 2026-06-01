if (typeof postMessage === "function" && globalThis.self === globalThis) {
  self.onmessage = (event) => {
    self.postMessage({
      echo: event.data,
      worker: true,
    });
  };
} else {
  console.log("worker helper script loaded");
}
