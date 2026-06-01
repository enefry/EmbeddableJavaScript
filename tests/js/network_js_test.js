const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const errnoTable = os.constants && os.constants.errno ? os.constants.errno : {};
const POSIX_ERRNO = Object.freeze({
  ECONNREFUSED: Number.isInteger(errnoTable.ECONNREFUSED) ? errnoTable.ECONNREFUSED : 61,
  ECONNRESET: Number.isInteger(errnoTable.ECONNRESET) ? errnoTable.ECONNRESET : 54,
  EHOSTUNREACH: Number.isInteger(errnoTable.EHOSTUNREACH) ? errnoTable.EHOSTUNREACH : 65,
  ENETUNREACH: Number.isInteger(errnoTable.ENETUNREACH) ? errnoTable.ENETUNREACH : 51,
  ETIMEOUT: Number.isInteger(errnoTable.ETIMEOUT) ? errnoTable.ETIMEOUT : 60
});

function install(relativePath, invoke, globals = {}) {
  const context = vm.createContext({
    assert,
    URL,
    ...globals,
    __ejs_native__: invoke ? { invoke } : undefined
  });
  const source = fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
  vm.runInContext(source, context, { filename: relativePath });
  return context;
}

function createFinalizationRegistryHarness() {
  const instances = [];
  const records = [];
  class FakeFinalizationRegistry {
    constructor(callback) {
      this.callback = callback;
      this.records = [];
      instances.push(this);
    }

    register(target, heldValue, unregisterToken) {
      const record = { type: "register", target, heldValue, unregisterToken };
      this.records.push(record);
      records.push(record);
    }

    unregister(token) {
      const record = { type: "unregister", token };
      this.records.push(record);
      records.push(record);
      return true;
    }
  }
  return { FakeFinalizationRegistry, instances, records };
}

function runInContext(context, source) {
  return vm.runInContext(source, context);
}

function testIPAddr() {
  const context = install("modules/stdlib/ipaddr/js/ipaddr.js");

  runInContext(context, `
    assert.strictEqual(EJSIPAddr.isValidIPv4("127.0.0.1"), true);
    assert.strictEqual(EJSIPAddr.isValidIPv4("01.0.0.1"), false);
    assert.strictEqual(EJSIPAddr.isValidIPv4("256.0.0.1"), false);
    assert.strictEqual(EJSIPAddr.isValidIPv4("127.1"), false);

    assert.strictEqual(EJSIPAddr.isValidIPv6("::1"), true);
    assert.strictEqual(EJSIPAddr.isValidIPv6("2001:0db8:0:0:0:0:0:1"), true);
    assert.strictEqual(EJSIPAddr.isValidIPv6("::ffff:192.0.2.128"), true);
    assert.strictEqual(EJSIPAddr.isValidIPv6("fe80::1%lo0"), true);
    assert.strictEqual(EJSIPAddr.isValidIPv6("1::2::3"), false);
    assert.strictEqual(EJSIPAddr.isValid("192.0.2.1"), true);
    assert.strictEqual(EJSIPAddr.isValid("2001:db8::1"), true);
    assert.strictEqual(EJSIPAddr.isValid("not an address"), false);
    assert.strictEqual(EJSIPAddr.isValidCIDR("192.0.2.0/24"), true);
    assert.strictEqual(EJSIPAddr.isValidCIDR("2001:db8::/32"), true);
    assert.strictEqual(EJSIPAddr.isValidCIDR("192.0.2.0/33"), false);
    assert.strictEqual(EJSIPAddr.isValidCIDR(42), false);

    const ipv4 = EJSIPAddr.parse("192.0.2.1");
    assert.strictEqual(ipv4.address, "192.0.2.1");
    assert.strictEqual(ipv4.family, 4);
    assert.strictEqual(ipv4.normalized, "192.0.2.1");
    assert.strictEqual(ipv4.bytes.join(","), "192,0,2,1");

    const ipv6 = EJSIPAddr.parse("2001:0db8:0:0:0:0:0:1");
    assert.strictEqual(ipv6.address, "2001:db8::1");
    assert.strictEqual(ipv6.family, 6);
    assert.strictEqual(ipv6.bytes.length, 16);

    const scoped = EJSIPAddr.parse("fe80::1%lo0");
    assert.strictEqual(scoped.address, "fe80::1%lo0");
    assert.strictEqual(scoped.normalized, "fe80::1%lo0");
    assert.strictEqual(scoped.scopeId, "lo0");

    assert.strictEqual(EJSIPAddr.normalize("::ffff:192.0.2.128"), "::ffff:c000:280");

    const privateV4 = EJSIPAddr.parseCIDR("10.0.0.0/8");
    assert.strictEqual(privateV4.normalized, "10.0.0.0/8");
    assert.strictEqual(EJSIPAddr.contains(privateV4, "10.25.1.1"), true);
    assert.strictEqual(EJSIPAddr.contains(privateV4, "11.0.0.1"), false);

    assert.strictEqual(EJSIPAddr.contains("2001:db8::/32", "2001:db8::42"), true);
    assert.strictEqual(EJSIPAddr.contains("2001:db8::/32", "2001:db9::1"), false);
    assert.strictEqual(EJSIPAddr.contains("127.0.0.0/8", "::1"), false);

    assert.throws(() => EJSIPAddr.parse("not an address"), /invalid IP address/);
    assert.throws(() => EJSIPAddr.parseCIDR("127.0.0.0/33"), /prefix length/);
    assert.throws(() => EJSIPAddr.parseCIDR("::1/129"), /prefix length/);
    assert.throws(() => EJSIPAddr.contains({ family: 4, prefixLength: 32, bytes: [127] }, "127.0.0.1"), /cidr object is invalid/);
    assert.throws(() => EJSIPAddr.contains({ family: 4, prefixLength: 33, bytes: [127, 0, 0, 1] }, "127.0.0.1"), /cidr object is invalid/);
    assert.throws(() => EJSIPAddr.contains({ family: 4, prefixLength: 32, bytes: [127, 0, 0, 256] }, "127.0.0.1"), /cidr object is invalid/);
  `);
}

async function testNetLookupWrapper() {
  const calls = [];
  const context = install("modules/net/js/net.js", async (moduleID, methodID, payload) => {
    calls.push({ moduleID, methodID, payload: JSON.parse(payload || "{}") });
    assert.strictEqual(moduleID, "ejs.net");
    assert.strictEqual(methodID, "lookup");
    return new Uint8Array(Buffer.from(JSON.stringify({
      addresses: [
        { address: "127.0.0.1", family: 4, canonicalName: "localhost" },
        { address: "::1", family: 6 }
      ]
    }), "utf8"));
  });

  await vm.runInContext(`
    (async function() {
      const one = await EJSNet.lookup("localhost", { family: 4 });
      assert.strictEqual(one.address, "127.0.0.1");
      assert.strictEqual(one.family, 4);
      assert.strictEqual(one.canonicalName, "localhost");

      const all = await EJSNet.lookup("localhost", { all: true });
      assert.strictEqual(all.length, 2);
      assert.strictEqual(all[1].address, "::1");
    })()
  `, context);

  assert.deepStrictEqual(calls.map((call) => call.payload), [
    { family: 4, all: false, host: "localhost" },
    { family: 0, all: true, host: "localhost" }
  ]);

  await assert.rejects(
    () => vm.runInContext("EJSNet.lookup('', {})", context),
    /net host/
  );
  await assert.rejects(
    () => vm.runInContext("EJSNet.lookup('localhost', { family: 5 })", context),
    /family/
  );
}

async function testNetLookupErrorShape() {
  const context = install("modules/net/js/net.js", async () => {
    const error = new Error("lookup blocked");
    error.code = 7;
    error.platform_domain = "EJSProviderErrorDomain";
    error.platform_code = 7;
    throw error;
  });

  await vm.runInContext(`
    (async function() {
      try {
        await EJSNet.lookup("blocked.test", { family: 6 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "EPERM");
        assert.strictEqual(error.module, "net");
        assert.strictEqual(error.operation, "lookup");
        assert.strictEqual(error.syscall, "getaddrinfo");
        assert.strictEqual(error.host, "blocked.test");
        assert.strictEqual(error.family, 6);
        assert.strictEqual(error.nativeDomain, "EJSProviderErrorDomain");
        assert.strictEqual(error.nativeCode, 7);
        return;
      }
      throw new Error("lookup should have failed");
    })()
  `, context);
}

async function testNetTCPWrapper() {
  const calls = [];
  const context = install("modules/net/js/net.js", async (moduleID, methodID, payload, transfer) => {
    const decoded = payload ? JSON.parse(payload) : {};
    const transferBytes = transfer == null
      ? []
      : Array.from(new Uint8Array(transfer.buffer || transfer, transfer.byteOffset || 0, transfer.byteLength || transfer.length));
    calls.push({ moduleID, methodID, payload: decoded, transferBytes });
    assert.strictEqual(moduleID, "ejs.net");

    if (methodID === "tcpConnect") {
      assert.deepStrictEqual(decoded, {
        host: "127.0.0.1",
        port: 1234,
        family: 4,
        noDelay: true,
        keepAlive: { enabled: true, initialDelayMs: 250 },
        timeoutMs: 1000
      });
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "sock-1",
        localAddress: { address: "127.0.0.1", port: 51000, family: 4 },
        remoteAddress: { address: "127.0.0.1", port: 1234, family: 4 }
      }), "utf8"));
    }
    if (methodID === "tcpWrite") {
      assert.deepStrictEqual(decoded, { socketID: "sock-1" });
      assert.deepStrictEqual(transferBytes, [112, 105, 110, 103]);
      return new Uint8Array(Buffer.from(JSON.stringify({ bytesWritten: 4 }), "utf8"));
    }
    if (methodID === "tcpRead") {
      assert.deepStrictEqual(decoded, { socketID: "sock-1", maxBytes: 4 });
      return new Uint8Array([112, 111, 110, 103]);
    }
    if (methodID === "tcpShutdown") {
      assert.deepStrictEqual(decoded, { socketID: "sock-1" });
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    if (methodID === "tcpClose") {
      assert.deepStrictEqual(decoded, { socketID: "sock-1" });
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.tcp.connect({
        host: "127.0.0.1",
        port: 1234,
        family: 4,
        noDelay: true,
        keepAlive: { enabled: true, initialDelayMs: 250 },
        timeoutMs: 1000
      });
      assert.strictEqual(socket.localAddress.port, 51000);
      assert.strictEqual(socket.remoteAddress.address, "127.0.0.1");

      await socket.write(new Uint8Array([112, 105, 110, 103]));
      const response = await socket.read({ maxBytes: 4 });
      assert.strictEqual(Array.from(response).join(","), "112,111,110,103");
      await socket.shutdown();
      await socket.close();
      await socket.close();

      let closedError = null;
      try {
        await socket.read({ maxBytes: 1 });
      } catch (error) {
        closedError = error;
      }
      assert.strictEqual(closedError.name, "EJSNetworkError");
      assert.strictEqual(closedError.code, "ECANCELLED");
      assert.strictEqual(closedError.operation, "read");
    })()
  `, context);

  assert.deepStrictEqual(calls.map((call) => call.methodID), [
    "tcpConnect",
    "tcpWrite",
    "tcpRead",
    "tcpShutdown",
    "tcpClose"
  ]);

  await assert.rejects(
    () => vm.runInContext("EJSNet.tcp.connect({ host: '127.0.0.1', port: 0 })", context),
    /net port/
  );
  await assert.rejects(
    () => vm.runInContext("EJSNet.tcp.connect({ host: '127.0.0.1', port: 1234, family: 7 })", context),
    /family/
  );
}

async function testNetTCPErrorShape() {
  const context = install("modules/net/js/net.js", async () => {
    const error = new Error("connect refused");
    error.code = 3;
    error.platform_domain = "EJSProviderErrorDomain";
    error.platform_code = 3;
    throw error;
  });

  await vm.runInContext(`
    (async function() {
      try {
        await EJSNet.tcp.connect({ host: "127.0.0.1", port: 65535, family: 4 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "ENETWORK");
        assert.strictEqual(error.module, "net");
        assert.strictEqual(error.operation, "connect");
        assert.strictEqual(error.syscall, "connect");
        assert.strictEqual(error.host, "127.0.0.1");
        assert.strictEqual(error.port, 65535);
        assert.strictEqual(error.family, 4);
        assert.strictEqual(error.nativeDomain, "EJSProviderErrorDomain");
        assert.strictEqual(error.nativeCode, 3);
        return;
      }
      throw new Error("connect should have failed");
    })()
  `, context);
}

async function testNetTCPPOSIXErrorMapping() {
  const mappings = [
    { nativeCode: POSIX_ERRNO.ECONNREFUSED, expected: "ECONNREFUSED" },
    { nativeCode: POSIX_ERRNO.ECONNRESET, expected: "ECONNRESET" },
    { nativeCode: POSIX_ERRNO.EHOSTUNREACH, expected: "EHOSTUNREACH" },
    { nativeCode: POSIX_ERRNO.ENETUNREACH, expected: "ENETUNREACH" },
    { nativeCode: POSIX_ERRNO.ETIMEOUT, expected: "ETIMEOUT" }
  ];

  for (const mapping of mappings) {
    const context = install("modules/net/js/net.js", async () => {
      const error = new Error("connect failed");
      error.code = 3;
      error.platform_domain = "NSPOSIXErrorDomain";
      error.platform_code = mapping.nativeCode;
      throw error;
    });

    await vm.runInContext(`
      (async function() {
        try {
          await EJSNet.tcp.connect({ host: "127.0.0.1", port: 65535, family: 4 });
        } catch (error) {
          assert.strictEqual(error.code, "${mapping.expected}");
          assert.strictEqual(error.operation, "connect");
          assert.strictEqual(error.syscall, "connect");
          assert.strictEqual(error.host, "127.0.0.1");
          assert.strictEqual(error.port, 65535);
          assert.strictEqual(error.family, 4);
          assert.strictEqual(error.nativeDomain, "NSPOSIXErrorDomain");
          assert.strictEqual(error.nativeCode, ${mapping.nativeCode});
          return;
        }
        throw new Error("connect should have failed");
      })()
    `, context);
  }
}

async function testNetResolverErrorMapping() {
  const context = install("modules/net/js/net.js", async () => {
    const error = new Error("connect lookup failed");
    error.code = 3;
    error.platform_domain = "EJSNetGetAddrInfoErrorDomain";
    error.platform_code = -2;
    throw error;
  });

  await vm.runInContext(`
    (async function() {
      try {
        await EJSNet.tcp.connect({ host: "resolver.invalid", port: 443, family: 4 });
      } catch (error) {
        assert.strictEqual(error.code, "EDNS");
        assert.strictEqual(error.operation, "connect");
        assert.strictEqual(error.syscall, "connect");
        assert.strictEqual(error.host, "resolver.invalid");
        assert.strictEqual(error.port, 443);
        assert.strictEqual(error.family, 4);
        assert.strictEqual(error.nativeDomain, "EJSNetGetAddrInfoErrorDomain");
        assert.strictEqual(error.nativeCode, -2);
        return;
      }
      throw new Error("connect should have failed");
    })()
  `, context);
}

async function testNetTCPServerWrapper() {
  const calls = [];
  let closed = false;
  let acceptCount = 0;
  const context = install("modules/net/js/net.js", async (moduleID, methodID, payload) => {
    const decoded = payload ? JSON.parse(payload) : {};
    calls.push({ moduleID, methodID, payload: decoded });
    assert.strictEqual(moduleID, "ejs.net");

    if (methodID === "tcpListen") {
      assert.deepStrictEqual(decoded, {
        host: "127.0.0.1",
        port: 0,
        family: 4,
        backlog: 64,
        reuseAddress: true
      });
      return new Uint8Array(Buffer.from(JSON.stringify({
        listenerID: "listener-1",
        localAddress: { address: "127.0.0.1", port: 51432, family: 4 }
      }), "utf8"));
    }
    if (methodID === "tcpAccept") {
      if (closed) {
        const error = new Error("listener closed");
        error.code = 2;
        error.platform_domain = "EJSProviderErrorDomain";
        error.platform_code = 2;
        throw error;
      }
      if (acceptCount === 1) {
        assert.deepStrictEqual(decoded, { listenerID: "listener-1", timeoutMs: 1 });
        acceptCount++;
        const error = new Error("accept timed out");
        error.code = 5;
        error.platform_domain = "EJSProviderErrorDomain";
        error.platform_code = 5;
        throw error;
      }
      assert.deepStrictEqual(decoded, { listenerID: "listener-1", timeoutMs: 2500 });
      acceptCount++;
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "sock-accepted-1",
        localAddress: { address: "127.0.0.1", port: 51432, family: 4 },
        remoteAddress: { address: "127.0.0.1", port: 60400, family: 4 }
      }), "utf8"));
    }
    if (methodID === "tcpClose") {
      assert.deepStrictEqual(decoded, { socketID: "sock-accepted-1" });
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    if (methodID === "tcpListenerClose") {
      closed = true;
      assert.deepStrictEqual(decoded, { listenerID: "listener-1" });
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const listener = await EJSNet.tcp.listen({
        host: "127.0.0.1",
        port: 0,
        family: 4,
        backlog: 64,
        reuseAddress: true
      });
      assert.strictEqual(listener.localAddress.address, "127.0.0.1");
      assert.strictEqual(listener.localAddress.port, 51432);

      const accepted = await listener.accept({ timeoutMs: 2500 });
      assert.strictEqual(accepted.remoteAddress.port, 60400);
      await accepted.close();

      let timeoutError = null;
      try {
        await listener.accept({ timeoutMs: 1 });
      } catch (error) {
        timeoutError = error;
      }
      assert.strictEqual(timeoutError.name, "EJSNetworkError");
      assert.strictEqual(timeoutError.code, "ETIMEOUT");
      assert.strictEqual(timeoutError.operation, "accept");

      await listener.close();
      await listener.close();

      let closedError = null;
      try {
        await listener.accept({ timeoutMs: 1 });
      } catch (error) {
        closedError = error;
      }
      assert.strictEqual(closedError.name, "EJSNetworkError");
      assert.strictEqual(closedError.code, "ECANCELLED");
      assert.strictEqual(closedError.operation, "accept");
    })()
  `, context);

  assert.deepStrictEqual(calls.map((call) => call.methodID), [
    "tcpListen",
    "tcpAccept",
    "tcpClose",
    "tcpAccept",
    "tcpListenerClose"
  ]);

  await assert.rejects(
    () => vm.runInContext("EJSNet.tcp.listen({ host: '127.0.0.1', port: -1 })", context),
    /net port/
  );
  await assert.rejects(
    () => vm.runInContext("EJSNet.tcp.listen({ host: '127.0.0.1', port: 0, backlog: 0 })", context),
    /backlog/
  );
}

async function testNetUDPWrapper() {
  const calls = [];
  const context = install("modules/net/js/net.js", async (moduleID, methodID, payload, transfer) => {
    const decoded = payload ? JSON.parse(payload) : {};
    const transferBytes = transfer == null
      ? []
      : Array.from(new Uint8Array(transfer.buffer || transfer, transfer.byteOffset || 0, transfer.byteLength || transfer.length));
    calls.push({ moduleID, methodID, payload: decoded, transferBytes });
    assert.strictEqual(moduleID, "ejs.net");

    if (methodID === "udpBind") {
      assert.strictEqual(decoded.host, "127.0.0.1");
      assert.strictEqual(decoded.port, 0);
      assert.strictEqual(decoded.ipv6Only, false);
      assert.ok(decoded.family === 0 || decoded.family === 4);
      assert.ok(decoded.reuseAddress === false || decoded.reuseAddress === true);
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "udp-1",
        localAddress: { address: "127.0.0.1", port: 51001, family: 4 }
      }), "utf8"));
    }
    if (methodID === "udpSend") {
      assert.deepStrictEqual(decoded, {
        socketID: "udp-1",
        host: "127.0.0.1",
        port: 9001,
        family: 4
      });
      assert.deepStrictEqual(transferBytes, [112, 105, 110, 103]);
      return new Uint8Array(Buffer.from(JSON.stringify({ bytesSent: 4 }), "utf8"));
    }
    if (methodID === "udpRecv") {
      assert.deepStrictEqual(decoded, { socketID: "udp-1", maxBytes: 8, timeoutMs: 10 });
      return new Uint8Array(Buffer.from(JSON.stringify({
        remoteAddress: { address: "127.0.0.1", port: 9001, family: 4 },
        data: [112, 111, 110, 103]
      }), "utf8"));
    }
    if (methodID === "udpClose") {
      assert.deepStrictEqual(decoded, { socketID: "udp-1" });
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.udp.bind({
        host: "127.0.0.1",
        port: 0,
        family: 4,
        reuseAddress: true
      });
      assert.strictEqual(socket.localAddress.port, 51001);
      await socket.send(new Uint8Array([112, 105, 110, 103]), { host: "127.0.0.1", port: 9001, family: 4 });
      const packet = await socket.recv({ maxBytes: 8, timeoutMs: 10 });
      assert.strictEqual(Array.from(packet.data).join(","), "112,111,110,103");
      assert.strictEqual(packet.remoteAddress.address, "127.0.0.1");
      assert.strictEqual(packet.remoteAddress.port, 9001);
      assert.strictEqual(packet.remoteAddress.family, 4);
      await socket.close();
      await socket.close();

      let sendError = null;
      try {
        await socket.send(new Uint8Array([1]), { host: "127.0.0.1", port: 9001, family: 4 });
      } catch (error) {
        sendError = error;
      }
      assert.strictEqual(sendError.name, "EJSNetworkError");
      assert.strictEqual(sendError.code, "ECANCELLED");
      assert.strictEqual(sendError.operation, "send");

      let recvError = null;
      try {
        await socket.recv({ maxBytes: 1, timeoutMs: 1 });
      } catch (error) {
        recvError = error;
      }
      assert.strictEqual(recvError.name, "EJSNetworkError");
      assert.strictEqual(recvError.code, "ECANCELLED");
      assert.strictEqual(recvError.operation, "recv");
    })()
  `, context);

  assert.deepStrictEqual(calls.map((call) => call.methodID), [
    "udpBind",
    "udpSend",
    "udpRecv",
    "udpClose"
  ]);

  await assert.rejects(
    () => vm.runInContext("EJSNet.udp.bind({ host: '', port: 0 })", context),
    /net host/
  );
  await assert.rejects(
    () => vm.runInContext("EJSNet.udp.bind({ host: '127.0.0.1', port: 0, family: 7 })", context),
    /family/
  );
  await assert.rejects(
    () => vm.runInContext("EJSNet.udp.bind({ host: '127.0.0.1', port: 0 }).then((s) => s.send('x', { host: '127.0.0.1', port: 1 }))", context),
    /udp data/
  );
}

async function testNetUDPWrapperBase64Payload() {
  const calls = [];
  const baseBytes = [0, 255, 34, 10, 228, 189, 160];
  const rawPayload = Buffer.from(baseBytes).toString("base64");
  const noisyPayload = `${rawPayload.slice(0, 4)} ${rawPayload.slice(4)}`;
  const emptyPayload = "";
  const callData = new Map();

  const context = install("modules/net/js/net.js", async (moduleID, methodID, payload) => {
    const decoded = payload ? JSON.parse(payload) : {};
    calls.push({ moduleID, methodID, payload: decoded });
    assert.strictEqual(moduleID, "ejs.net");

    if (methodID === "udpBind") {
      assert.strictEqual(decoded.host, "127.0.0.1");
      assert.strictEqual(decoded.port, 0);
      assert.strictEqual(decoded.family, 4);
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "udp-base64",
        localAddress: { address: "127.0.0.1", port: 51003, family: 4 }
      }), "utf8"));
    }
    if (methodID === "udpRecv") {
      const count = (callData.get("udpRecv") || 0) + 1;
      callData.set("udpRecv", count);
      const payloadByCall = count === 1 ? noisyPayload : emptyPayload;
      return new Uint8Array(Buffer.from(JSON.stringify({
        remoteAddress: { address: "127.0.0.1", port: 9001, family: 4 },
        data: payloadByCall
      }), "utf8"));
    }
    if (methodID === "udpClose") {
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.udp.bind({ host: "127.0.0.1", port: 0, family: 4 });
      const packet = await socket.recv({ maxBytes: 16, timeoutMs: 10 });
      assert.deepStrictEqual(Array.from(packet.data), ${JSON.stringify(baseBytes)});
      const empty = await socket.recv({ maxBytes: 16, timeoutMs: 10 });
      assert.strictEqual(empty.data.length, 0);
      await socket.close();
    })()
  `, context);

  assert.deepStrictEqual(calls.map((call) => call.methodID), [
    "udpBind",
    "udpRecv",
    "udpRecv",
    "udpClose"
  ]);
}

async function testNetUDPWrapperArrayPayload() {
  const calls = [];
  const callData = new Map();
  const nonEmptyPayload = [5, 6, 7, 8];
  const context = install("modules/net/js/net.js", async (moduleID, methodID, payload) => {
    const decoded = payload ? JSON.parse(payload) : {};
    calls.push({ moduleID, methodID, payload: decoded });
    assert.strictEqual(moduleID, "ejs.net");

    if (methodID === "udpBind") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "udp-array",
        localAddress: { address: "127.0.0.1", port: 51005, family: 4 }
      }), "utf8"));
    }
    if (methodID === "udpRecv") {
      const count = (callData.get("udpRecv") || 0) + 1;
      callData.set("udpRecv", count);
      const payloadByCall = count === 1 ? nonEmptyPayload : [];
      return new Uint8Array(Buffer.from(JSON.stringify({
        remoteAddress: { address: "127.0.0.1", port: 9001, family: 4 },
        data: payloadByCall
      }), "utf8"));
    }
    if (methodID === "udpClose") {
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.udp.bind({ host: "127.0.0.1", port: 0, family: 4 });
      const packet = await socket.recv({ maxBytes: 16, timeoutMs: 10 });
      assert.deepStrictEqual(Array.from(packet.data), [5, 6, 7, 8]);
      const empty = await socket.recv({ maxBytes: 16, timeoutMs: 10 });
      assert.strictEqual(empty.data.length, 0);
      await socket.close();
    })()
  `, context);

  assert.deepStrictEqual(calls.map((call) => call.methodID), [
    "udpBind",
    "udpRecv",
    "udpRecv",
    "udpClose"
  ]);
}

async function testNetUDPMalformedBase64Shape() {
  const context = install("modules/net/js/net.js", async (moduleID, methodID) => {
    assert.strictEqual(moduleID, "ejs.net");
    if (methodID === "udpBind") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "udp-malformed-base64",
        localAddress: { address: "127.0.0.1", port: 51004, family: 4 }
      }), "utf8"));
    }
    if (methodID === "udpRecv") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        remoteAddress: { address: "127.0.0.1", port: 9001, family: 4 },
        data: "not-a-valid-base64$$$"
      }), "utf8"));
    }
    if (methodID === "udpClose") {
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.udp.bind({ host: "127.0.0.1", port: 0, family: 4 });
      try {
        await socket.recv({ maxBytes: 8, timeoutMs: 10 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "EINVAL");
        assert.strictEqual(error.operation, "recv");
        await socket.close();
        return;
      }
      throw new Error("udp recv malformed base64 should have failed");
    })()
  `, context);
}

async function testNetUDPMalformedRecvDataValue() {
  const context = install("modules/net/js/net.js", async (moduleID, methodID) => {
    assert.strictEqual(moduleID, "ejs.net");
    if (methodID === "udpBind") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "udp-malformed-array-value",
        localAddress: { address: "127.0.0.1", port: 51006, family: 4 }
      }), "utf8"));
    }
    if (methodID === "udpRecv") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        remoteAddress: { address: "127.0.0.1", port: 9001, family: 4 },
        data: [0, 1, -1]
      }), "utf8"));
    }
    if (methodID === "udpClose") {
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.udp.bind({ host: "127.0.0.1", port: 0, family: 4 });
      try {
        await socket.recv({ maxBytes: 8, timeoutMs: 10 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "EINVAL");
        assert.strictEqual(error.operation, "recv");
        await socket.close();
        return;
      }
      throw new Error("udp recv malformed data bytes should have failed");
    })()
  `, context);
}

async function testNetUDPMalformedRecvShape() {
  const context = install("modules/net/js/net.js", async (moduleID, methodID) => {
    assert.strictEqual(moduleID, "ejs.net");
    if (methodID === "udpBind") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        socketID: "udp-malformed",
        localAddress: { address: "127.0.0.1", port: 51002, family: 4 }
      }), "utf8"));
    }
    if (methodID === "udpRecv") {
      return new Uint8Array(Buffer.from(JSON.stringify({
        data: [1, 2, 3]
      }), "utf8"));
    }
    if (methodID === "udpClose") {
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const socket = await EJSNet.udp.bind({ host: "127.0.0.1", port: 0, family: 4 });
      try {
        await socket.recv({ maxBytes: 3, timeoutMs: 1 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "EINVAL");
        assert.strictEqual(error.operation, "recv");
        await socket.close();
        return;
      }
      throw new Error("udp recv should have failed");
      })()
    `, context);
}

async function testNetUDPMalformedBindShape() {
  const context = install("modules/net/js/net.js", async (moduleID, methodID) => {
    assert.strictEqual(moduleID, "ejs.net");
    assert.strictEqual(methodID, "udpBind");
    return new Uint8Array(Buffer.from(JSON.stringify({
      socketID: "udp-malformed-bind",
      localAddress: { address: "", port: 0, family: 0 }
    }), "utf8"));
  });

  await vm.runInContext(`
    (async function() {
      try {
        await EJSNet.udp.bind({ host: "127.0.0.1", port: 0, family: 4 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "EINVAL");
        assert.strictEqual(error.operation, "bind");
        return;
      }
      throw new Error("udp bind should have failed");
    })()
  `, context);
}

async function testNetTCPListenErrorShape() {
  const context = install("modules/net/js/net.js", async () => {
    const error = new Error("listen denied");
    error.code = 7;
    error.platform_domain = "EJSProviderErrorDomain";
    error.platform_code = 7;
    throw error;
  });

  await vm.runInContext(`
    (async function() {
      try {
        await EJSNet.tcp.listen({ host: "127.0.0.1", port: 8080, family: 4 });
      } catch (error) {
        assert.strictEqual(error.name, "EJSNetworkError");
        assert.strictEqual(error.code, "EPERM");
        assert.strictEqual(error.module, "net");
        assert.strictEqual(error.operation, "listen");
        assert.strictEqual(error.syscall, "listen");
        assert.strictEqual(error.host, "127.0.0.1");
        assert.strictEqual(error.port, 8080);
        assert.strictEqual(error.family, 4);
        assert.strictEqual(error.nativeDomain, "EJSProviderErrorDomain");
        assert.strictEqual(error.nativeCode, 7);
        return;
      }
      throw new Error("listen should have failed");
    })()
  `, context);
}

function testXHRConstructorState() {
  const context = install("modules/xhr/js/xhr.js");
  runInContext(context, `
    assert.strictEqual(typeof XMLHttpRequest, "function");
    assert.strictEqual(EJSXHR.installed, true);
    assert.strictEqual(EJSXHR.moduleID, "ejs.xhr");
    assert.strictEqual(Array.isArray(EJSXHR.events), true);

    const xhr = new XMLHttpRequest();
    assert.strictEqual(xhr.readyState, 0);
    assert.strictEqual(xhr.status, 0);
    assert.strictEqual(xhr.statusText, "");
    assert.strictEqual(xhr.responseURL, "");
    assert.strictEqual(xhr.responseType, "");
    assert.strictEqual(xhr.responseText, "");
    assert.strictEqual(xhr.response, "");
    assert.strictEqual(xhr.getAllResponseHeaders(), "");
    assert.strictEqual(xhr.getResponseHeader("x-test"), null);

    xhr.responseType = "arraybuffer";
    assert.strictEqual(xhr.responseType, "arraybuffer");
    xhr.responseType = "json";
    assert.strictEqual(xhr.responseType, "json");
    xhr.responseType = "";
    assert.throws(() => xhr.open("GET", "https://example.test/", false), /async/);
    assert.throws(() => xhr.setRequestHeader("x-test", "1"), /OPENED/);

    xhr.open("GET", "https://example.test/");
    xhr.setRequestHeader("x-one", "1");
    xhr.setRequestHeader("x-one", "2");
    assert.throws(() => xhr.send({}), /xhr body/);
  `);
}

async function testXHRSuccessAndHeaderAccess() {
  const calls = [];
  const context = install("modules/xhr/js/xhr.js", async (moduleID, methodID, payload, transfer) => {
    const request = payload ? JSON.parse(payload) : {};
    const transferBytes = transfer == null
      ? []
      : Array.from(new Uint8Array(transfer.buffer || transfer, transfer.byteOffset || 0, transfer.byteLength || transfer.length));
    calls.push({ moduleID, methodID, request, transferBytes });
    assert.strictEqual(moduleID, "ejs.xhr");

    if (methodID === "send") {
      const bodyText = "ok:" + (request.bodyText || request.url.split("/").pop());
      const bodyBytes = Buffer.byteLength(bodyText, "utf8");
      if (request.url.endsWith("/bytes")) {
        assert.deepStrictEqual(transferBytes, [1, 2, 3, 4]);
      }
      if (request.url.endsWith("/view")) {
        assert.deepStrictEqual(transferBytes, [5, 6]);
      }
      if (request.url.endsWith("/empty")) {
        assert.deepStrictEqual(transferBytes, []);
      }
      return new Uint8Array(Buffer.from(JSON.stringify({
        status: 201,
        statusText: "created",
        responseURL: request.url,
        headers: [
          { name: "Content-Type", value: "text/plain" },
          { name: "X-Reply", value: "ok" }
        ],
        bodyText,
        loaded: bodyBytes,
        total: bodyBytes,
        lengthComputable: true
      }), "utf8"));
    }
    if (methodID === "abort") {
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      async function request(url, body) {
        const xhr = new XMLHttpRequest();
        xhr.responseType = "text";
        const states = [];
        const events = [];
        const progress = [];
        const terminalEvents = [];
        xhr.onreadystatechange = function() { states.push(xhr.readyState); };
        xhr.addEventListener("loadstart", function() { events.push("loadstart"); });
        xhr.addEventListener("progress", function(event) {
          events.push("progress");
          progress.push({
            loaded: event.loaded,
            total: event.total,
            lengthComputable: event.lengthComputable,
            readyState: xhr.readyState
          });
        });
        xhr.addEventListener("load", function() { events.push("load"); });
        xhr.addEventListener("error", function() { terminalEvents.push("error"); });
        xhr.addEventListener("abort", function() { terminalEvents.push("abort"); });
        xhr.addEventListener("timeout", function() { terminalEvents.push("timeout"); });
        xhr.addEventListener("loadend", function() { events.push("loadend"); });
        xhr.open("POST", url);
        xhr.setRequestHeader("X-Test", "a");
        xhr.setRequestHeader("X-Test", "b");
        await new Promise((resolve, reject) => {
          xhr.onerror = () => reject(new Error("unexpected error"));
          xhr.onload = () => resolve();
          xhr.send(body);
        });
        assert.strictEqual(xhr.status, 201);
        assert.strictEqual(xhr.statusText, "created");
        assert.strictEqual(xhr.responseURL, url);
        assert.strictEqual(xhr.responseType, "text");
        assert.strictEqual(xhr.response, xhr.responseText);
        assert.strictEqual(xhr.getResponseHeader("content-type"), "text/plain");
        assert.strictEqual(xhr.getResponseHeader("X-Reply"), "ok");
        assert.ok(xhr.getAllResponseHeaders().toLowerCase().indexOf("x-reply: ok") >= 0);
        assert.deepStrictEqual(states, [1, 2, 3, 4]);
        assert.strictEqual(events.join(","), "loadstart,progress,load,loadend");
        assert.strictEqual(progress.length, 1);
        assert.strictEqual(progress[0].loaded > 0, true);
        assert.strictEqual(progress[0].loaded, progress[0].total);
        assert.strictEqual(progress[0].lengthComputable, true);
        assert.strictEqual(progress[0].readyState, 3);
        assert.deepStrictEqual(terminalEvents, []);
      }

      await request("https://example.test/text", "payload");
      await request("https://example.test/bytes", new Uint8Array([1, 2, 3, 4]).buffer);
      await request("https://example.test/view", new Uint8Array([5, 6]));
      await request("https://example.test/empty", null);
    })()
  `, context);

  assert.strictEqual(calls.filter((entry) => entry.methodID === "send").length, 4);
  assert.strictEqual(calls.every((entry) => entry.moduleID === "ejs.xhr"), true);
}

async function testXHRResponseTypesAndInvalidJSON() {
  const context = install("modules/xhr/js/xhr.js", async (moduleID, methodID, payload) => {
    const request = payload ? JSON.parse(payload) : {};
    assert.strictEqual(moduleID, "ejs.xhr");
    assert.strictEqual(methodID, "send");
    if (request.url.endsWith("/arraybuffer")) {
      return new Uint8Array(Buffer.from(JSON.stringify({
        status: 200,
        statusText: "ok",
        responseURL: request.url,
        headers: [{ name: "Content-Type", value: "application/octet-stream" }],
        bodyBase64: Buffer.from([0, 255, 34, 10]).toString("base64"),
        loaded: 4,
        total: 4,
        lengthComputable: true
      }), "utf8"));
    }
    if (request.url.endsWith("/json")) {
      const bodyText = "{\"ok\":true,\"count\":2}";
      return new Uint8Array(Buffer.from(JSON.stringify({
        status: 200,
        statusText: "ok",
        responseURL: request.url,
        headers: [{ name: "Content-Type", value: "application/json" }],
        bodyText,
        loaded: Buffer.byteLength(bodyText, "utf8"),
        total: Buffer.byteLength(bodyText, "utf8"),
        lengthComputable: true
      }), "utf8"));
    }
    if (request.url.endsWith("/invalid-json")) {
      const bodyText = "{broken";
      return new Uint8Array(Buffer.from(JSON.stringify({
        status: 200,
        statusText: "ok",
        responseURL: request.url,
        headers: [{ name: "Content-Type", value: "application/json" }],
        bodyText,
        loaded: Buffer.byteLength(bodyText, "utf8"),
        total: Buffer.byteLength(bodyText, "utf8"),
        lengthComputable: true
      }), "utf8"));
    }
    throw new Error("unexpected url " + request.url);
  });

  await vm.runInContext(`
    (async function() {
      const arrayXHR = new XMLHttpRequest();
      const arrayEvents = [];
      let arrayProgress = null;
      arrayXHR.responseType = "arraybuffer";
      arrayXHR.addEventListener("loadstart", function() { arrayEvents.push("loadstart"); });
      arrayXHR.addEventListener("progress", function(event) {
        arrayEvents.push("progress");
        arrayProgress = {
          loaded: event.loaded,
          total: event.total,
          lengthComputable: event.lengthComputable,
          readyState: arrayXHR.readyState
        };
      });
      arrayXHR.addEventListener("load", function() { arrayEvents.push("load"); });
      arrayXHR.addEventListener("loadend", function() { arrayEvents.push("loadend"); });
      arrayXHR.open("GET", "https://example.test/arraybuffer");
      await new Promise((resolve, reject) => {
        arrayXHR.onerror = function() { reject(new Error("unexpected arraybuffer error")); };
        arrayXHR.onload = function() { resolve(); };
        arrayXHR.send();
      });
      assert.strictEqual(arrayXHR.response instanceof ArrayBuffer, true);
      assert.strictEqual(arrayXHR.responseText, "");
      assert.strictEqual(Array.from(new Uint8Array(arrayXHR.response)).join(","), "0,255,34,10");
      assert.strictEqual(arrayEvents.join(","), "loadstart,progress,load,loadend");
      assert.deepStrictEqual(arrayProgress, { loaded: 4, total: 4, lengthComputable: true, readyState: 3 });

      const jsonXHR = new XMLHttpRequest();
      jsonXHR.responseType = "json";
      jsonXHR.open("GET", "https://example.test/json");
      await new Promise((resolve, reject) => {
        jsonXHR.onerror = function() { reject(new Error("unexpected json error")); };
        jsonXHR.onload = function() { resolve(); };
        jsonXHR.send();
      });
      assert.strictEqual(jsonXHR.responseText, '{"ok":true,"count":2}');
      assert.deepStrictEqual(jsonXHR.response, { ok: true, count: 2 });

      const invalidXHR = new XMLHttpRequest();
      const invalidEvents = [];
      const invalidStates = [];
      invalidXHR.responseType = "json";
      invalidXHR.onreadystatechange = function() { invalidStates.push(invalidXHR.readyState); };
      invalidXHR.addEventListener("loadstart", function() { invalidEvents.push("loadstart"); });
      invalidXHR.addEventListener("error", function() { invalidEvents.push("error"); });
      invalidXHR.addEventListener("load", function() { invalidEvents.push("load"); });
      await new Promise((resolve) => {
        invalidXHR.onloadend = function() {
          invalidEvents.push("loadend");
          resolve();
        };
        invalidXHR.open("GET", "https://example.test/invalid-json");
        invalidXHR.send();
      });
      assert.strictEqual(invalidXHR.readyState, 4);
      assert.strictEqual(invalidXHR.status, 0);
      assert.strictEqual(invalidXHR._lastError.name, "EJSXHRError");
      assert.deepStrictEqual(invalidStates, [1, 2, 3, 4]);
      assert.strictEqual(invalidEvents.join(","), "loadstart,error,loadend");
    })()
  `, context);
}

async function testXHRAbortAndOpenCancellationBehavior() {
  const pendingRejectByRequestID = new Map();
  const abortedRequestIDs = [];
  const context = install("modules/xhr/js/xhr.js", async (moduleID, methodID, payload) => {
    const request = payload ? JSON.parse(payload) : {};
    assert.strictEqual(moduleID, "ejs.xhr");
    if (methodID === "send") {
      return new Promise((resolve, reject) => {
        pendingRejectByRequestID.set(request.requestID, reject);
      });
    }
    if (methodID === "abort") {
      abortedRequestIDs.push(request.requestID);
      const reject = pendingRejectByRequestID.get(request.requestID);
      if (reject) {
        const error = new Error("aborted");
        error.code = 2;
        error.platform_domain = "EJSProviderErrorDomain";
        error.platform_code = 2;
        reject(error);
        pendingRejectByRequestID.delete(request.requestID);
      }
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  });

  await vm.runInContext(`
    (async function() {
      const openedXHR = new XMLHttpRequest();
      const openedEvents = [];
      openedXHR.addEventListener("abort", () => openedEvents.push("abort"));
      openedXHR.addEventListener("loadend", () => openedEvents.push("loadend"));
      openedXHR.open("GET", "https://example.test/opened");
      openedXHR.abort();
      assert.strictEqual(openedXHR.readyState, 0);
      assert.strictEqual(openedEvents.join(","), "");

      const xhr = new XMLHttpRequest();
      const events = [];
      xhr.addEventListener("abort", () => events.push("abort"));
      xhr.addEventListener("loadend", () => events.push("loadend"));
      xhr.addEventListener("load", () => events.push("load"));
      xhr.open("GET", "https://example.test/slow");
      xhr.send();
      xhr.abort();
      await Promise.resolve();
      await Promise.resolve();
      assert.strictEqual(xhr.readyState, 0);
      assert.strictEqual(xhr.status, 0);
      assert.strictEqual(xhr.responseText, "");
      assert.strictEqual(events.join(","), "abort,loadend");

      xhr.abort();
      await Promise.resolve();
      assert.strictEqual(events.join(","), "abort,loadend");

      const xhr2 = new XMLHttpRequest();
      xhr2.open("GET", "https://example.test/first");
      xhr2.send();
      xhr2.open("GET", "https://example.test/second");
      await Promise.resolve();
      await Promise.resolve();
      assert.strictEqual(xhr2.readyState, 1);
    })()
  `, context);
  assert.strictEqual(abortedRequestIDs.length, 2);
}

async function testXHRFinalizerAbortCleanup() {
  const pendingByRequestID = new Set();
  const abortCalls = [];
  const harness = createFinalizationRegistryHarness();
  const context = install("modules/xhr/js/xhr.js", async (moduleID, methodID, payload) => {
    const request = payload ? JSON.parse(payload) : {};
    assert.strictEqual(moduleID, "ejs.xhr");
    if (methodID === "send") {
      pendingByRequestID.add(request.requestID);
      return new Promise(() => {});
    }
    if (methodID === "abort") {
      abortCalls.push(request.requestID);
      pendingByRequestID.delete(request.requestID);
      return new Uint8Array(Buffer.from(JSON.stringify({ ok: true }), "utf8"));
    }
    throw new Error("unexpected method " + methodID);
  }, { FinalizationRegistry: harness.FakeFinalizationRegistry });

  await vm.runInContext(`
    (async function() {
      const xhr = new XMLHttpRequest();
      xhr.open("GET", "https://example.test/finalizer");
      xhr.send();
      await Promise.resolve();
    })()
  `, context);
  const registerRecord = harness.records.find((record) => record.type === "register");
  assert(registerRecord);
  const finalizerRequestID = registerRecord.heldValue;
  assert.strictEqual(pendingByRequestID.has(finalizerRequestID), true);
  await harness.instances[0].callback(finalizerRequestID);
  assert.deepStrictEqual(abortCalls, [finalizerRequestID]);

  await vm.runInContext(`
    (async function() {
      const xhr = new XMLHttpRequest();
      xhr.open("GET", "https://example.test/explicit");
      xhr.send();
      xhr.abort();
      await Promise.resolve();
    })()
  `, context);
  assert.strictEqual(harness.records.some((record) => record.type === "unregister"), true);
  assert.strictEqual(abortCalls.length, 2);
}

async function testXHRPolicyAndNativeErrorPath() {
  const context = install("modules/xhr/js/xhr.js", async (moduleID, methodID, payload) => {
    const request = payload ? JSON.parse(payload) : {};
    assert.strictEqual(moduleID, "ejs.xhr");
    assert.strictEqual(methodID, "send");
    const error = new Error("xhr failed");
    if (request.url.endsWith("/policy")) {
      error.code = 7;
    } else if (request.url.endsWith("/timeout")) {
      error.code = 5;
    } else {
      error.code = 3;
    }
    error.platform_domain = "EJSProviderErrorDomain";
    error.platform_code = error.code;
    throw error;
  });

  await vm.runInContext(`
    (async function() {
      async function expectFailure(url, expectedEvent, expectedCode) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url);
        const events = [];
        xhr.addEventListener("loadstart", () => events.push("loadstart"));
        xhr.addEventListener("load", () => events.push("load"));
        xhr.addEventListener("error", () => events.push("error"));
        xhr.addEventListener("timeout", () => events.push("timeout"));
        xhr.addEventListener("abort", () => events.push("abort"));
        await new Promise((resolve) => {
          let done = false;
          function settle() {
            if (!done) {
              done = true;
              resolve();
            }
          }
          xhr.onloadend = () => {
            events.push("loadend");
            settle();
          };
          xhr.send();
        });
        assert.strictEqual(xhr.readyState, 4);
        assert.strictEqual(xhr.status, 0);
        assert.strictEqual(xhr._lastError.name, "EJSXHRError");
        assert.strictEqual(xhr._lastError.code, expectedCode);
        assert.strictEqual(xhr._lastError.module, "xhr");
        assert.deepStrictEqual(events, ["loadstart", expectedEvent, "loadend"]);
      }

      await expectFailure("https://example.test/policy", "error", "EPERM");
      await expectFailure("https://example.test/network", "error", "ENETWORK");
      await expectFailure("https://example.test/timeout", "timeout", "ETIMEOUT");
    })()
  `, context);
}

function wsEventPayloadToBytes(payload) {
  return new Uint8Array(Buffer.from(JSON.stringify(payload), "utf8"));
}

function makeWSMockInvoke() {
  const sockets = new Map();
  const sendCalls = [];
  const closeCalls = [];

  function pushEvent(socketID, event) {
    const socket = sockets.get(socketID);
    if (!socket) return;
    if (socket.pendingResolve) {
      const resolve = socket.pendingResolve;
      socket.pendingResolve = null;
      resolve(wsEventPayloadToBytes(event));
      return;
    }
    socket.events.push(event);
  }

  return {
    sendCalls,
    closeCalls,
    invoke: async (moduleID, methodID, payload, transfer) => {
      assert.strictEqual(moduleID, "ejs.ws");
      const request = payload ? JSON.parse(payload) : {};
      if (methodID === "connect") {
        if (request.url.includes("fail-connect")) {
          const error = new Error("connect denied");
          error.code = 7;
          error.platform_domain = "EJSProviderErrorDomain";
          error.platform_code = 7;
          throw error;
        }
        const socket = {
          events: [],
          pendingResolve: null
        };
        sockets.set(request.socketID, socket);
        pushEvent(request.socketID, { event: "open", protocol: "chat" });
        if (request.url.includes("error-close")) {
          pushEvent(request.socketID, { event: "error", error: { code: 3, message: "native fail" } });
          pushEvent(request.socketID, { event: "close", code: 1006, reason: "", wasClean: false });
          pushEvent(request.socketID, { event: "close", code: 1000, reason: "ignored", wasClean: true });
        }
        return wsEventPayloadToBytes({ socketID: request.socketID });
      }
      if (methodID === "nextEvent") {
        const socket = sockets.get(request.socketID);
        if (!socket) {
          const error = new Error("unknown socket");
          error.code = 1;
          throw error;
        }
        if (socket.events.length > 0) {
          return wsEventPayloadToBytes(socket.events.shift());
        }
        return new Promise((resolve) => {
          socket.pendingResolve = resolve;
        });
      }
      if (methodID === "send") {
        const transferBytes = transfer == null
          ? []
          : Array.from(new Uint8Array(transfer.buffer || transfer, transfer.byteOffset || 0, transfer.byteLength || transfer.length));
        sendCalls.push({
          socketID: request.socketID,
          messageType: request.messageType,
          data: request.data || null,
          transferBytes
        });
        if (request.messageType === "text") {
          pushEvent(request.socketID, { event: "message", messageType: "text", data: request.data || "" });
        } else {
          pushEvent(request.socketID, {
            event: "message",
            messageType: "binary",
            dataBase64: Buffer.from(transferBytes).toString("base64")
          });
          pushEvent(request.socketID, { event: "message", messageType: "binary", bytes: [4, 5] });
        }
        return wsEventPayloadToBytes({ ok: true });
      }
      if (methodID === "close") {
        closeCalls.push({
          socketID: request.socketID,
          code: request.code,
          reason: request.reason
        });
        pushEvent(request.socketID, {
          event: "close",
          code: Number.isInteger(request.code) ? request.code : 1000,
          reason: typeof request.reason === "string" ? request.reason : "",
          wasClean: true
        });
        return wsEventPayloadToBytes({ ok: true });
      }
      throw new Error("unexpected method " + methodID);
    }
  };
}

function testWSConstructorAndValidation() {
  const context = install("modules/ws/js/ws.js");
  runInContext(context, `
    assert.strictEqual(typeof WebSocket, "function");
    assert.strictEqual(EJSWebSocket.installed, true);
    assert.strictEqual(EJSWebSocket.moduleID, "ejs.ws");
    assert.strictEqual(Array.isArray(EJSWebSocket.events), true);
    assert.strictEqual(WebSocket.CONNECTING, 0);
    assert.strictEqual(WebSocket.OPEN, 1);
    assert.strictEqual(WebSocket.CLOSING, 2);
    assert.strictEqual(WebSocket.CLOSED, 3);

    assert.throws(() => new WebSocket("http://example.test"), /invalid|ws:/);
    assert.throws(() => new WebSocket("ws://example.test/#fragment"), /fragment/);
    assert.throws(() => new WebSocket("ws://example.test", ["chat", "CHAT", "chat"]), /duplicates/);
    assert.throws(() => new WebSocket("ws://example.test", [""]), /protocol/);
  `);
}

async function testWSLifecycleAndMessages() {
  const wsMock = makeWSMockInvoke();
  const context = install("modules/ws/js/ws.js", wsMock.invoke);

  await vm.runInContext(`
    (async function() {
      const ws = new WebSocket("ws://example.test/socket", ["chat"]);
      const events = [];
      const messages = [];
      ws.addEventListener("open", () => events.push("open"));
      ws.addEventListener("message", (event) => {
        events.push("message");
        messages.push(event.data);
      });
      ws.addEventListener("close", () => events.push("close"));
      ws.addEventListener("error", () => events.push("error"));

      assert.strictEqual(ws.readyState, WebSocket.CONNECTING);
      assert.strictEqual(ws.protocol, "");
      assert.strictEqual(ws.binaryType, "arraybuffer");
      assert.throws(() => { ws.binaryType = "blob"; }, /arraybuffer/);
      assert.throws(() => ws.send("before-open"), /OPEN state/);
      assert.throws(() => ws.close(1001, "bad"), /close code/);
      assert.throws(() => ws.close(1000, "x".repeat(124)), /123 UTF-8 bytes/);

      await new Promise((resolve) => ws.addEventListener("open", resolve));
      assert.strictEqual(ws.readyState, WebSocket.OPEN);
      assert.strictEqual(ws.protocol, "chat");

      ws.send("hello");
      ws.send(new Uint8Array([1, 2, 3]));

      for (let i = 0; i < 16 && messages.length < 3; i++) {
        await Promise.resolve();
      }
      assert.strictEqual(messages.length >= 3, true);
      assert.strictEqual(messages[0], "hello");
      assert.strictEqual(messages[1] instanceof ArrayBuffer, true);
      assert.strictEqual(Array.from(new Uint8Array(messages[1])).join(","), "1,2,3");
      assert.strictEqual(messages[2] instanceof ArrayBuffer, true);
      assert.strictEqual(Array.from(new Uint8Array(messages[2])).join(","), "4,5");

      ws.close(1000, "done");
      await new Promise((resolve) => ws.addEventListener("close", resolve));
      assert.strictEqual(ws.readyState, WebSocket.CLOSED);
      assert.throws(() => ws.send("after-close"), /OPEN state/);

      const closeCount = events.filter((value) => value === "close").length;
      assert.strictEqual(closeCount, 1);
      assert.strictEqual(events.includes("error"), false);
    })()
  `, context);

  assert.strictEqual(wsMock.sendCalls.length, 2);
  assert.strictEqual(wsMock.sendCalls[0].messageType, "text");
  assert.strictEqual(wsMock.sendCalls[0].data, "hello");
  assert.deepStrictEqual(wsMock.sendCalls[0].transferBytes, []);
  assert.strictEqual(wsMock.sendCalls[1].messageType, "binary");
  assert.strictEqual(wsMock.sendCalls[1].data, null);
  assert.deepStrictEqual(wsMock.sendCalls[1].transferBytes, [1, 2, 3]);
  assert.strictEqual(wsMock.closeCalls.length, 1);
  assert.strictEqual(wsMock.closeCalls[0].code, 1000);
  assert.strictEqual(wsMock.closeCalls[0].reason, "done");
}

async function testWSFinalizerAndCloseCleanup() {
  const wsMock = makeWSMockInvoke();
  const harness = createFinalizationRegistryHarness();
  const context = install("modules/ws/js/ws.js", wsMock.invoke, {
    FinalizationRegistry: harness.FakeFinalizationRegistry
  });

  await vm.runInContext(`
    (async function() {
      const ws = new WebSocket("ws://example.test/finalizer");
      await new Promise((resolve) => ws.addEventListener("open", resolve));
      await Promise.resolve();
    })()
  `, context);
  const firstRegister = harness.records.find((record) => record.type === "register");
  assert(firstRegister);
  await harness.instances[0].callback(firstRegister.heldValue);
  assert.strictEqual(wsMock.closeCalls.length, 1);
  assert.strictEqual(wsMock.closeCalls[0].socketID, firstRegister.heldValue);
  assert.strictEqual(wsMock.closeCalls[0].code, undefined);
  assert.strictEqual(wsMock.closeCalls[0].reason, undefined);

  await vm.runInContext(`
    (async function() {
      const ws = new WebSocket("ws://example.test/explicit");
      await new Promise((resolve) => ws.addEventListener("open", resolve));
      ws.close(3001, "cleanup");
      await new Promise((resolve) => ws.addEventListener("close", resolve));
    })()
  `, context);
  assert.strictEqual(harness.records.some((record) => record.type === "unregister"), true);
  assert.strictEqual(wsMock.closeCalls.length, 2);
  assert.strictEqual(wsMock.closeCalls[1].code, 3001);
  assert.strictEqual(wsMock.closeCalls[1].reason, "cleanup");
}

async function testWSErrorAndTerminalEventOnce() {
  const wsMock = makeWSMockInvoke();
  const context = install("modules/ws/js/ws.js", wsMock.invoke);

  await vm.runInContext(`
    (async function() {
      const ws = new WebSocket("ws://example.test/error-close");
      const events = [];
      await new Promise((resolve) => ws.addEventListener("open", resolve));
      ws.addEventListener("error", () => events.push("error"));
      ws.addEventListener("close", () => events.push("close"));
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      assert.strictEqual(ws.readyState, WebSocket.CLOSED);
      assert.strictEqual(ws._lastError.name, "EJSWebSocketError");
      assert.strictEqual(ws._lastError.code, "ENETWORK");
      assert.strictEqual(events.filter((item) => item === "error").length, 1);
      assert.strictEqual(events.filter((item) => item === "close").length, 1);
    })()
  `, context);
}

async function testWSCloseDuringConnectingIgnoresLateOpen() {
  const wsMock = makeWSMockInvoke();
  const context = install("modules/ws/js/ws.js", wsMock.invoke);

  await vm.runInContext(`
    (async function() {
      const ws = new WebSocket("ws://example.test/socket", ["chat"]);
      const events = [];
      ws.addEventListener("open", () => events.push("open"));
      ws.addEventListener("close", () => events.push("close"));
      ws.close(1000, "during-connect");
      for (let i = 0; i < 16 && ws.readyState !== WebSocket.CLOSED; i++) {
        await Promise.resolve();
      }
      assert.strictEqual(ws.readyState, WebSocket.CLOSED);
      assert.deepStrictEqual(events, ["close"]);
    })()
  `, context);
}

(async function main() {
  testIPAddr();
  await testNetLookupWrapper();
  await testNetLookupErrorShape();
  await testNetTCPWrapper();
  await testNetTCPErrorShape();
  await testNetTCPPOSIXErrorMapping();
  await testNetResolverErrorMapping();
  await testNetTCPServerWrapper();
  await testNetUDPWrapper();
  await testNetUDPWrapperBase64Payload();
  await testNetUDPWrapperArrayPayload();
  await testNetUDPMalformedRecvShape();
  await testNetUDPMalformedBindShape();
  await testNetUDPMalformedBase64Shape();
  await testNetUDPMalformedRecvDataValue();
  await testNetTCPListenErrorShape();
  testXHRConstructorState();
  await testXHRSuccessAndHeaderAccess();
  await testXHRResponseTypesAndInvalidJSON();
  await testXHRAbortAndOpenCancellationBehavior();
  await testXHRFinalizerAbortCleanup();
  await testXHRPolicyAndNativeErrorPath();
  testWSConstructorAndValidation();
  await testWSLifecycleAndMessages();
  await testWSFinalizerAndCloseCleanup();
  await testWSErrorAndTerminalEventOnce();
  await testWSCloseDuringConnectingIgnoresLateOpen();
  console.log("network_js_test PASS");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
