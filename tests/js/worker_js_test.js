const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");

function utf8Bytes(text) {
  return new Uint8Array(Buffer.from(String(text), "utf8"));
}

function jsonBytes(value) {
  return utf8Bytes(JSON.stringify(value));
}

function encodeFrame(envelope, sidecar) {
  const header = Buffer.from(JSON.stringify({ envelope }), "utf8");
  const sidecarBytes = sidecar
    ? Buffer.from(sidecar.buffer, sidecar.byteOffset, sidecar.byteLength)
    : Buffer.alloc(0);
  const out = Buffer.alloc(4 + header.length + sidecarBytes.length);
  out.writeUInt32LE(header.length, 0);
  header.copy(out, 4);
  sidecarBytes.copy(out, 4 + header.length);
  return new Uint8Array(out);
}

function decodeFrame(frameData) {
  const bytes = Buffer.from(frameData.buffer, frameData.byteOffset, frameData.byteLength);
  const headerLength = bytes.readUInt32LE(0);
  const header = JSON.parse(bytes.subarray(4, 4 + headerLength).toString("utf8"));
  const sidecar = new Uint8Array(bytes.subarray(4 + headerLength));
  return { envelope: header.envelope, sidecar };
}

function installContext(relativePath, invoke, nativeExtras = {}) {
  const context = vm.createContext({
    console,
    assert,
    setTimeout,
    clearTimeout,
    __ejs_native__: { invoke, ...nativeExtras }
  });
  const source = fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
  vm.runInContext(source, context, { filename: relativePath });
  return context;
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function testWorkerParentWrapper() {
  const parentInbox = new Map();
  let nextMessageID = 1;
  let createResolve = null;
  const createPromise = new Promise((resolve) => {
    createResolve = resolve;
  });

  const context = installContext("modules/worker/js/worker_parent.js", async (moduleID, methodID, payload, transferBuffer) => {
    assert.strictEqual(moduleID, "ejs.worker");
    const request = payload ? JSON.parse(payload) : {};
    if (methodID === "create") {
      assert.strictEqual(request.specifier, "echo");
      return createPromise;
    }
    if (methodID === "start") {
      assert.strictEqual(request.workerID, "w-parent");
      return jsonBytes({ started: true });
    }
    if (methodID === "postMessage") {
      assert.strictEqual(request.direction, "toChild");
      const messageID = `m-${nextMessageID++}`;
      parentInbox.set(messageID, encodeFrame(request.envelope, transferBuffer ? new Uint8Array(transferBuffer) : new Uint8Array(0)));
      context.__EJSWorkerDispatch(request.workerID, messageID);
      return jsonBytes({ messageID });
    }
    if (methodID === "takeMessage") {
      const frame = parentInbox.get(request.messageID);
      parentInbox.delete(request.messageID);
      return frame || new Uint8Array(0);
    }
    if (methodID === "terminate") {
      return jsonBytes({ terminated: true });
    }
    throw new Error(`unexpected worker method: ${methodID}`);
  });

  vm.runInContext(
    "globalThis.__parentEvents = []; const w = new Worker('echo'); " +
      "w.onmessage = (event) => __parentEvents.push(['message', event.data]); " +
      "w.onerror = (event) => __parentEvents.push(['error', event.message]); " +
      "w.onmessageerror = (event) => __parentEvents.push(['messageerror', event.message]); " +
      "globalThis.__workerRef = w;",
    context
  );

  vm.runInContext(
    "const buffer = new ArrayBuffer(8);" +
      "new Uint8Array(buffer).set([9,8,1,2,3,7,6,5]);" +
      "const view = new Uint8Array(buffer, 2, 3);" +
      "const dataView = new DataView(buffer, 3, 2);" +
      "__workerRef.postMessage({ op: 'queued', buffer, again: buffer, view, dataView }, [buffer]);" +
      "globalThis.__queuedDetached = buffer.byteLength;",
    context
  );
  assert([0, 3].includes(vm.runInContext("__queuedDetached", context)));

  createResolve(jsonBytes({ workerID: "w-parent", maxQueuedMessages: 8 }));
  await tick();
  await tick();

  const parentEvents = vm.runInContext("__parentEvents", context);
  assert.strictEqual(parentEvents.length, 1);
  assert.strictEqual(parentEvents[0][0], "message");
  assert.strictEqual(parentEvents[0][1].op, "queued");
  assert.strictEqual(parentEvents[0][1].buffer, parentEvents[0][1].again);
  assert.strictEqual(parentEvents[0][1].view.buffer, parentEvents[0][1].buffer);
  assert.strictEqual(parentEvents[0][1].view.byteOffset, 2);
  assert.strictEqual(parentEvents[0][1].view.byteLength, 3);
  assert.strictEqual(parentEvents[0][1].dataView.buffer, parentEvents[0][1].buffer);
  assert.strictEqual(parentEvents[0][1].dataView.byteOffset, 3);
  assert.strictEqual(parentEvents[0][1].dataView.byteLength, 2);
  assert.strictEqual(parentEvents[0][1].buffer.byteLength, 8);
  assert.deepStrictEqual(Array.from(new Uint8Array(parentEvents[0][1].buffer)), [9, 8, 1, 2, 3, 7, 6, 5]);
  assert.deepStrictEqual(Array.from(parentEvents[0][1].view), [1, 2, 3]);

  vm.runInContext(
    "globalThis.__transferError = null;" +
      "try { const external = new ArrayBuffer(1); __workerRef.postMessage({ op: 'bad' }, [external]); }" +
      "catch (error) { __transferError = String(error.message || error); }",
    context
  );
  assert.match(vm.runInContext("__transferError", context), /transferList/);

  parentInbox.set("m-close", encodeFrame({ kind: "close" }, new Uint8Array(0)));
  context.__EJSWorkerDispatch("w-parent", "m-close");
  await tick();
  assert.strictEqual(vm.runInContext("__EJSWorkerInternalActiveCount()", context), 0);
  vm.runInContext(
    "globalThis.__postAfterCloseError = null;" +
      "try { __workerRef.postMessage({ op: 'late' }); }" +
      "catch (error) { __postAfterCloseError = String(error.message || error); }",
    context
  );
  assert.match(vm.runInContext("__postAfterCloseError", context), /terminated/);

  vm.runInContext("__workerRef.terminate(); __workerRef.terminate();", context);
  await tick();
}

async function testWorkerParentStartupDispatchRace() {
  const parentInbox = new Map();
  let startResolve = null;
  const startPromise = new Promise((resolve) => {
    startResolve = resolve;
  });
  let tookStartupMessage = false;

  const context = installContext("modules/worker/js/worker_parent.js", async (moduleID, methodID, payload) => {
    assert.strictEqual(moduleID, "ejs.worker");
    const request = payload ? JSON.parse(payload) : {};
    if (methodID === "create") {
      return jsonBytes({ workerID: "w-race", maxQueuedMessages: 8 });
    }
    if (methodID === "start") {
      assert.strictEqual(request.workerID, "w-race");
      parentInbox.set("m-ready", encodeFrame({
        kind: "message",
        version: 1,
        buffers: [],
        payload: {
          kind: "object",
          value: [["ready", { kind: "boolean", value: true }]]
        }
      }, new Uint8Array(0)));
      context.__EJSWorkerDispatch("w-race", "m-ready");
      return startPromise;
    }
    if (methodID === "takeMessage") {
      tookStartupMessage = true;
      const frame = parentInbox.get(request.messageID);
      parentInbox.delete(request.messageID);
      return frame || new Uint8Array(0);
    }
    if (methodID === "terminate") {
      return jsonBytes({ terminated: true });
    }
    throw new Error(`unexpected worker method: ${methodID}`);
  });

  vm.runInContext(
    "globalThis.__startupRaceEvents = [];" +
      "const w = new Worker('race');" +
      "w.onmessage = (event) => __startupRaceEvents.push(['message', event.data]);" +
      "w.onerror = (event) => __startupRaceEvents.push(['error', event.message]);" +
      "globalThis.__startupRaceWorker = w;",
    context
  );

  await tick();
  assert.strictEqual(vm.runInContext("__startupRaceEvents.length", context), 0);
  assert.strictEqual(tookStartupMessage, false);
  startResolve(jsonBytes({ started: true }));
  await tick();
  await tick();

  const events = vm.runInContext("__startupRaceEvents", context);
  assert.strictEqual(events.length, 1);
  assert.strictEqual(events[0][0], "message");
  assert.strictEqual(events[0][1].ready, true);
  assert.strictEqual(tookStartupMessage, true);
  assert.strictEqual(parentInbox.size, 0);

  vm.runInContext("__startupRaceWorker.terminate();", context);
  await tick();
}

async function testWorkerParentTerminateDuringStartup() {
  let createResolve = null;
  const createPromise = new Promise((resolve) => {
    createResolve = resolve;
  });
  let startCalls = 0;
  let terminateCalls = 0;

  const context = installContext("modules/worker/js/worker_parent.js", async (moduleID, methodID, payload) => {
    assert.strictEqual(moduleID, "ejs.worker");
    const request = payload ? JSON.parse(payload) : {};
    if (methodID === "create") {
      return createPromise;
    }
    if (methodID === "start") {
      startCalls += 1;
      return jsonBytes({ started: true });
    }
    if (methodID === "terminate") {
      assert.strictEqual(request.workerID, "w-terminate");
      terminateCalls += 1;
      return jsonBytes({ terminated: true });
    }
    throw new Error(`unexpected worker method: ${methodID}`);
  });

  vm.runInContext(
    "globalThis.__terminateDuringStartup = { calls: 0 };" +
      "const w = new Worker('slow-start');" +
      "const originalTerminateNow = w._terminateNow;" +
      "w._terminateNow = function() { __terminateDuringStartup.calls += 1; return originalTerminateNow.apply(this, arguments); };" +
      "w.terminate();" +
      "globalThis.__terminatingWorker = w;",
    context
  );

  assert.strictEqual(vm.runInContext("__terminateDuringStartup.calls", context), 0);
  createResolve(jsonBytes({ workerID: "w-terminate", maxQueuedMessages: 8 }));
  await tick();
  await tick();

  assert.strictEqual(startCalls, 0);
  assert.strictEqual(terminateCalls, 1);
  assert.strictEqual(vm.runInContext("__terminateDuringStartup.calls", context), 1);
  assert.strictEqual(vm.runInContext("__EJSWorkerInternalActiveCount()", context), 0);
}

async function testWorkerChildWrapper() {
  let postedEnvelope = null;
  let postedSidecar = null;
  const reportedErrors = [];
  let rejectionTracker = null;
  const childInbox = new Map();

  const context = installContext("modules/worker/js/worker_child.js", async (moduleID, methodID, payload, transferBuffer) => {
    assert.strictEqual(moduleID, "ejs.worker");
    const request = payload ? JSON.parse(payload) : {};
    if (methodID === "postMessage") {
      postedEnvelope = request.envelope;
      postedSidecar = transferBuffer ? new Uint8Array(transferBuffer) : null;
      return jsonBytes({ ok: true });
    }
    if (methodID === "takeMessage") {
      const frame = childInbox.get(request.messageID);
      childInbox.delete(request.messageID);
      return frame || new Uint8Array(0);
    }
    if (methodID === "reportError") {
      reportedErrors.push(request);
      return jsonBytes({ ok: true });
    }
    if (methodID === "close") {
      return jsonBytes({ ok: true });
    }
    throw new Error(`unexpected child worker method: ${methodID}`);
  }, {
    events: {
      setPromiseRejectionTracker(callback) {
        rejectionTracker = callback;
      }
    }
  });

  vm.runInContext(
    "__EJSWorkerBootstrap({ workerID: 'w-child', maxQueuedMessages: 8 });" +
      "globalThis.__childEvents = [];" +
      "onmessage = (event) => __childEvents.push(['message', event.data]);" +
      "onmessageerror = (event) => __childEvents.push(['messageerror', event.message]);" +
      "onerror = (event) => __childEvents.push(['error', event.message]);" +
      "onunhandledrejection = (event) => __childEvents.push(['unhandled', event.reason && event.reason.message]);",
    context
  );
  assert.strictEqual(vm.runInContext("self === globalThis", context), true);

  const inboundEnvelope = {
    kind: "message",
    version: 1,
    buffers: [{ offset: 0, length: 5, transfer: false }],
    payload: {
      kind: "object",
      value: [
        ["hello", { kind: "string", value: "child" }],
        ["buffer", { kind: "arraybuffer", buffer: 0 }],
        ["again", { kind: "arraybuffer", buffer: 0 }],
        ["bytes", { kind: "view", ctor: "Uint8Array", buffer: 0, byteOffset: 1, byteLength: 3, elements: 3, transfer: false }],
        ["dataView", { kind: "view", ctor: "DataView", buffer: 0, byteOffset: 2, byteLength: 2, elements: null, transfer: false }]
      ]
    }
  };
  childInbox.set("m1", encodeFrame(inboundEnvelope, new Uint8Array([9, 1, 2, 3, 8])));

  context.__EJSWorkerDispatch("w-child", "m1");
  await tick();

  const childEvents = vm.runInContext("__childEvents", context);
  assert.strictEqual(childEvents.length, 1);
  assert.strictEqual(childEvents[0][0], "message");
  assert.strictEqual(childEvents[0][1].hello, "child");
  assert.strictEqual(childEvents[0][1].buffer, childEvents[0][1].again);
  assert.strictEqual(childEvents[0][1].bytes.buffer, childEvents[0][1].buffer);
  assert.strictEqual(childEvents[0][1].bytes.byteOffset, 1);
  assert.strictEqual(childEvents[0][1].dataView.buffer, childEvents[0][1].buffer);
  assert.strictEqual(childEvents[0][1].dataView.byteOffset, 2);
  assert.strictEqual(childEvents[0][1].dataView.byteLength, 2);
  assert.strictEqual(childEvents[0][1].buffer.byteLength, 5);
  assert.deepStrictEqual(Array.from(childEvents[0][1].bytes), [1, 2, 3]);

  vm.runInContext(
    "const buffer = new ArrayBuffer(2);" +
      "new Uint8Array(buffer).set([5, 6]);" +
      "postMessage({ op: 'from-child', buffer }, [buffer]);",
    context
  );
  await tick();

  assert(postedEnvelope != null);
  const decoded = decodeFrame(encodeFrame(postedEnvelope, postedSidecar || new Uint8Array(0)));
  assert.strictEqual(decoded.envelope.kind, "message");
  assert.strictEqual(decoded.envelope.buffers.length, 1);

  assert.strictEqual(typeof rejectionTracker, "function");
  vm.runInContext("globalThis.__promiseBoom = new Error('promise-boom');", context);
  rejectionTracker("unhandled", {}, vm.runInContext("__promiseBoom", context));
  await tick();
  const rejectionEvents = vm.runInContext("__childEvents", context);
  assert.strictEqual(rejectionEvents[rejectionEvents.length - 1][0], "unhandled");
  assert.strictEqual(rejectionEvents[rejectionEvents.length - 1][1], "promise-boom");
  assert.strictEqual(reportedErrors[reportedErrors.length - 1].message, "promise-boom");

  vm.runInContext("close();", context);
}

async function testWorkerChildCloseFlushesOutgoing() {
  const order = [];
  let postResolve = null;
  const postPromise = new Promise((resolve) => {
    postResolve = resolve;
  });

  const context = installContext("modules/worker/js/worker_child.js", async (moduleID, methodID) => {
    assert.strictEqual(moduleID, "ejs.worker");
    if (methodID === "postMessage") {
      order.push("post");
      return postPromise;
    }
    if (methodID === "close") {
      order.push("close");
      return jsonBytes({ ok: true });
    }
    if (methodID === "reportError") {
      order.push("error");
      return jsonBytes({ ok: true });
    }
    throw new Error(`unexpected child worker method: ${methodID}`);
  });

  vm.runInContext(
    "__EJSWorkerBootstrap({ workerID: 'w-close-flush', maxQueuedMessages: 8 });" +
      "postMessage({ op: 'before-close' });" +
      "close();",
    context
  );

  await tick();
  assert.deepStrictEqual(order, ["post"]);
  postResolve(jsonBytes({ ok: true }));
  await tick();
  await tick();
  assert.deepStrictEqual(order, ["post", "close"]);
}

async function main() {
  await testWorkerParentWrapper();
  await testWorkerParentStartupDispatchRace();
  await testWorkerParentTerminateDuringStartup();
  await testWorkerChildWrapper();
  await testWorkerChildCloseFlushesOutgoing();
  console.log("worker_js_test PASS");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
