(function() {
    const moduleID = "ejs.net";

    const nativeCodeMap = {
        1: "EINVAL",
        2: "ECANCELLED",
        3: "ENETWORK",
        4: "ETLS",
        5: "ETIMEOUT",
        6: "ENOTSUP",
        7: "EPERM",
        8: "EINTERNAL"
    };
    const resolverNativeDomains = Object.freeze({
        EJSNetGetAddrInfoErrorDomain: true
    });
    const posixErrorMap = Object.freeze({
        ECONNREFUSED: [61, 111],
        ECONNRESET: [32, 54, 104],
        EHOSTUNREACH: [65, 113],
        ENETUNREACH: [51, 101],
        ETIMEOUT: [60, 110]
    });

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    const sharedTextDecoder = typeof TextDecoder === "function" ? new TextDecoder("utf-8") : null;
    const base64DecodeLookup = (() => {
        const map = new Map();
        const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (let i = 0; i < chars.length; i++) {
            map.set(chars[i], i);
        }
        return map;
    })();

    function decodeUtf8(input) {
        const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        if (sharedTextDecoder != null) {
            return sharedTextDecoder.decode(bytes);
        }

        let output = "";
        for (let i = 0; i < bytes.length; i++) {
            const first = bytes[i];

            if (first < 0x80) {
                output += String.fromCharCode(first);
                continue;
            }

            let codePoint = null;
            let need = 0;
            let minCodePoint = 0;

            if ((first & 0xE0) === 0xC0) {
                codePoint = first & 0x1F;
                need = 1;
                minCodePoint = 0x80;
            } else if ((first & 0xF0) === 0xE0) {
                codePoint = first & 0x0F;
                need = 2;
                minCodePoint = 0x800;
            } else if ((first & 0xF8) === 0xF0) {
                codePoint = first & 0x07;
                need = 3;
                minCodePoint = 0x10000;
            } else {
                output += "\uFFFD";
                continue;
            }

            if (i + need >= bytes.length) {
                output += "\uFFFD";
                break;
            }

            for (let n = 0; n < need; n++) {
                const next = bytes[++i];
                if ((next & 0xC0) !== 0x80) {
                    codePoint = null;
                    break;
                }
                codePoint = (codePoint << 6) | (next & 0x3F);
            }

            if (codePoint == null || codePoint < minCodePoint || codePoint > 0x10FFFF || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
                output += "\uFFFD";
                continue;
            }

            if (codePoint <= 0xFFFF) {
                output += String.fromCharCode(codePoint);
            } else {
                const normalized = codePoint - 0x10000;
                output += String.fromCharCode(0xD800 + (normalized >>> 10));
                output += String.fromCharCode(0xDC00 + (normalized & 0x3FF));
            }
        }
        return output;
    }

    function decodeBase64ToBytes(data) {
        if (typeof data !== "string" || data.length === 0) {
            return new Uint8Array(0);
        }
        if (typeof atob === "function") {
            try {
                const raw = atob(data);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) {
                    bytes[i] = raw.charCodeAt(i) & 0xFF;
                }
                return bytes;
            } catch (_error) {
            }
        }
        if (typeof Buffer === "function" && typeof Buffer.from === "function") {
            try {
                return new Uint8Array(Buffer.from(data, "base64"));
            } catch (_error) {
            }
        }

        let validLength = data.length;
        while (validLength > 0 && data.charCodeAt(validLength - 1) === 61) {
            validLength--;
        }
        const values = [];
        let buffer = 0;
        let bits = 0;
        for (let i = 0; i < validLength; i++) {
            const value = base64DecodeLookup.get(data[i]);
            if (value == null) {
                const code = data.charCodeAt(i);
                if ((code >= 0x09 && code <= 0x0d) || code === 0x20) {
                    continue;
                }
                return null;
            }
            buffer = (buffer << 6) | value;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                values.push((buffer >>> bits) & 0xFF);
            }
        }
        return new Uint8Array(values);
    }

    function normalizeHost(host) {
        if (typeof host !== "string" || host.length === 0) {
            throw new TypeError("net host must be a non-empty string");
        }
        return host;
    }

    function normalizeLookupOptions(options) {
        const output = {
            family: 0,
            all: false
        };

        if (options == null) {
            return output;
        }
        if (typeof options !== "object") {
            throw new TypeError("net lookup options must be an object");
        }
        if (options.family != null) {
            const family = Number(options.family);
            if (family !== 0 && family !== 4 && family !== 6) {
                throw new TypeError("net lookup family must be 0, 4, or 6");
            }
            output.family = family;
        }
        if (options.all != null) {
            if (typeof options.all !== "boolean") {
                throw new TypeError("net lookup options.all must be a boolean");
            }
            output.all = options.all;
        }
        return output;
    }

    function normalizeLookupEntry(entry) {
        if (!entry || typeof entry !== "object" || typeof entry.address !== "string") {
            throw new Error("net lookup provider returned an invalid address");
        }
        const family = Number(entry.family);
        if (family !== 4 && family !== 6) {
            throw new Error("net lookup provider returned an invalid family");
        }
        return Object.freeze({
            address: entry.address,
            family: family,
            canonicalName: typeof entry.canonicalName === "string" ? entry.canonicalName : ""
        });
    }

    function normalizePort(port, allowZero) {
        const value = Number(port);
        const minimum = allowZero ? 0 : 1;
        if (!Number.isInteger(value) || value < minimum || value > 65535) {
            throw new TypeError(allowZero
                ? "net port must be an integer between 0 and 65535"
                : "net port must be an integer between 1 and 65535");
        }
        return value;
    }

    function normalizeNonNegativeInteger(value, name, defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        const number = Number(value);
        if (!Number.isInteger(number) || number < 0) {
            throw new TypeError(name + " must be a non-negative integer");
        }
        return number;
    }

    function normalizeReadSize(value) {
        const maxBytes = normalizeNonNegativeInteger(value, "tcp.read options.maxBytes", 65536);
        if (maxBytes < 1 || maxBytes > 1048576) {
            throw new TypeError("tcp.read options.maxBytes must be an integer between 1 and 1048576");
        }
        return maxBytes;
    }

    function normalizeListenOptions(options) {
        if (!options || typeof options !== "object") {
            throw new TypeError("tcp.listen options must be an object");
        }
        const request = {
            host: normalizeHost(options.host),
            port: normalizePort(options.port, true),
            family: normalizeLookupOptions({ family: options.family }).family,
            backlog: normalizeNonNegativeInteger(options.backlog, "tcp.listen options.backlog", 128),
            reuseAddress: !!options.reuseAddress
        };
        if (request.backlog < 1 || request.backlog > 4096) {
            throw new TypeError("tcp.listen options.backlog must be an integer between 1 and 4096");
        }
        return request;
    }

    function normalizeAcceptOptions(options) {
        if (options == null) {
            return { timeoutMs: 30000 };
        }
        if (typeof options !== "object") {
            throw new TypeError("tcp.accept options must be an object");
        }
        return {
            timeoutMs: normalizeNonNegativeInteger(options.timeoutMs, "tcp.accept options.timeoutMs", 30000)
        };
    }

    function normalizeConnectOptions(options) {
        if (!options || typeof options !== "object") {
            throw new TypeError("tcp.connect options must be an object");
        }
        const request = {
            host: normalizeHost(options.host),
            port: normalizePort(options.port, false),
            family: normalizeLookupOptions({ family: options.family }).family
        };
        if (options.localAddress != null) {
            request.localAddress = normalizeHost(options.localAddress);
        }
        if (options.noDelay != null) {
            if (typeof options.noDelay !== "boolean") {
                throw new TypeError("tcp.connect options.noDelay must be a boolean");
            }
            request.noDelay = options.noDelay;
        }
        if (options.keepAlive != null) {
            if (typeof options.keepAlive !== "object") {
                throw new TypeError("tcp.connect options.keepAlive must be an object");
            }
            request.keepAlive = {
                enabled: !!options.keepAlive.enabled,
                initialDelayMs: normalizeNonNegativeInteger(options.keepAlive.initialDelayMs, "keepAlive.initialDelayMs", 0)
            };
        }
        request.timeoutMs = normalizeNonNegativeInteger(options.timeoutMs, "tcp.connect options.timeoutMs", 0);
        return request;
    }

    function normalizeUDPBindOptions(options) {
        if (!options || typeof options !== "object") {
            throw new TypeError("udp.bind options must be an object");
        }
        const request = {
            host: normalizeHost(options.host),
            port: normalizePort(options.port, true),
            family: normalizeLookupOptions({ family: options.family }).family,
            reuseAddress: !!options.reuseAddress,
            ipv6Only: !!options.ipv6Only
        };
        return request;
    }

    function normalizeUDPSendTarget(target) {
        if (!target || typeof target !== "object") {
            throw new TypeError("udp.send target must be an object");
        }
        return {
            host: normalizeHost(target.host),
            port: normalizePort(target.port, false),
            family: normalizeLookupOptions({ family: target.family }).family
        };
    }

    function normalizeUDPRecvOptions(options) {
        if (options == null) {
            return { maxBytes: 65507, timeoutMs: 30000 };
        }
        if (typeof options !== "object") {
            throw new TypeError("udp.recv options must be an object");
        }
        const maxBytes = normalizeNonNegativeInteger(options.maxBytes, "udp.recv options.maxBytes", 65507);
        if (maxBytes < 1 || maxBytes > 65507) {
            throw new TypeError("udp.recv options.maxBytes must be an integer between 1 and 65507");
        }
        return {
            maxBytes: maxBytes,
            timeoutMs: normalizeNonNegativeInteger(options.timeoutMs, "udp.recv options.timeoutMs", 30000)
        };
    }

    function normalizeSocketAddress(value) {
        if (!value || typeof value !== "object" || typeof value.address !== "string") {
            return Object.freeze({ address: "", port: 0, family: 0 });
        }
        return Object.freeze({
            address: value.address,
            port: Number(value.port || 0),
            family: Number(value.family || 0)
        });
    }

    function normalizeRequiredSocketAddress(value, fields, label) {
        const address = normalizeSocketAddress(value);
        if (address.address.length === 0 ||
            !Number.isInteger(address.port) ||
            address.port < 1 ||
            address.port > 65535 ||
            (address.family !== 4 && address.family !== 6)) {
            throw makeNetworkError({ code: 1, message: label + " provider returned an invalid local address" }, fields);
        }
        return address;
    }

    function bytesFromData(data, scopeName) {
        if (data instanceof ArrayBuffer) {
            return data;
        }
        if (ArrayBuffer.isView(data)) {
            return data;
        }
        throw new TypeError(scopeName + " data must be an ArrayBuffer or ArrayBufferView");
    }

    function ensureSocketRecord(record, fields, operation, scopeName) {
        if (!record || typeof record.socketID !== "string") {
            throw makeNetworkError({ code: 8, message: scopeName + " " + operation + " provider returned an invalid socket" }, fields);
        }
        return record;
    }

    function normalizeUDPRecvResult(result, fields) {
        const fallback = {
            operation: fields.operation,
            syscall: fields.syscall,
            address: fields.address,
            port: fields.port,
            family: fields.family
        };
        if (!result || typeof result !== "object") {
            throw makeNetworkError({ code: 1, message: "udp recv provider returned an invalid result" }, fallback);
        }
        const remoteAddress = normalizeSocketAddress(result.remoteAddress);
        if (remoteAddress.family !== 4 && remoteAddress.family !== 6) {
            throw makeNetworkError({ code: 1, message: "udp recv provider returned an invalid remote address" }, fallback);
        }
        if (remoteAddress.address.length === 0 || !Number.isInteger(remoteAddress.port) || remoteAddress.port < 1 || remoteAddress.port > 65535) {
            throw makeNetworkError({ code: 1, message: "udp recv provider returned an invalid remote endpoint" }, fallback);
        }
        if (result.data == null) {
            throw makeNetworkError({ code: 1, message: "udp recv provider returned malformed data" }, fallback);
        }

        let bytes;
        if (typeof result.data === "string") {
            bytes = decodeBase64ToBytes(result.data);
            if (bytes == null) {
                throw makeNetworkError({ code: 1, message: "udp recv provider returned malformed data" }, fallback);
            }
        } else if (Array.isArray(result.data) || ArrayBuffer.isView(result.data) || result.data instanceof ArrayBuffer) {
            if (Array.isArray(result.data)) {
                bytes = new Uint8Array(result.data.length);
                for (let i = 0; i < result.data.length; i++) {
                    const value = Number(result.data[i]);
                    if (!Number.isInteger(value) || value < 0 || value > 255) {
                        throw makeNetworkError({ code: 1, message: "udp recv provider returned malformed data bytes" }, fallback);
                    }
                    bytes[i] = value;
                }
            } else {
                const data = bytesFromData(result.data, "udp.recv result");
                bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            }
        } else {
            throw makeNetworkError({ code: 1, message: "udp recv provider returned malformed data" }, fallback);
        }

        return Object.freeze({
            data: bytes instanceof Uint8Array
                ? bytes
                : new Uint8Array(bytes),
            remoteAddress: Object.freeze(remoteAddress)
        });
    }

    function providerCodeToString(error, operation) {
        const numeric = error && Number.isInteger(error.code) ? error.code : 8;
        const nativeDomain = error && typeof error.platform_domain === "string"
            ? error.platform_domain
            : "";
        const nativeCode = error && Number.isInteger(error.platform_code)
            ? error.platform_code
            : null;

        if (operation === "lookup" && numeric === 3) {
            return "EDNS";
        }
        if (numeric === 3) {
            if (resolverNativeDomains[nativeDomain]) {
                return "EDNS";
            }
            if (nativeDomain === "NSPOSIXErrorDomain" && nativeCode != null) {
                if (posixErrorMap.ECONNREFUSED.indexOf(nativeCode) >= 0) return "ECONNREFUSED";
                if (posixErrorMap.ECONNRESET.indexOf(nativeCode) >= 0) return "ECONNRESET";
                if (posixErrorMap.EHOSTUNREACH.indexOf(nativeCode) >= 0) return "EHOSTUNREACH";
                if (posixErrorMap.ENETUNREACH.indexOf(nativeCode) >= 0) return "ENETUNREACH";
                if (posixErrorMap.ETIMEOUT.indexOf(nativeCode) >= 0) return "ETIMEOUT";
            }
        }
        return nativeCodeMap[numeric] || "EINTERNAL";
    }

    function makeNetworkError(error, fields) {
        const jsCode = providerCodeToString(error, fields.operation);
        const message = (error && typeof error.message === "string" && error.message.length > 0)
            ? error.message
            : fields.operation + " failed";
        const shaped = new Error(message);
        shaped.name = "EJSNetworkError";
        shaped.code = jsCode;
        shaped.module = "net";
        shaped.operation = fields.operation;
        shaped.syscall = fields.syscall;
        if (fields.host != null) shaped.host = fields.host;
        if (fields.address != null) shaped.address = fields.address;
        if (fields.port != null) shaped.port = fields.port;
        if (fields.family != null) shaped.family = fields.family;
        if (error && typeof error.platform_domain === "string") shaped.nativeDomain = error.platform_domain;
        if (error && Number.isInteger(error.platform_code)) shaped.nativeCode = error.platform_code;
        return shaped;
    }

    async function invokeJSON(method, request, errorFields, transfer) {
        try {
            const data = await nativeInvoke()(moduleID, method, JSON.stringify(request), transfer || null);
            return JSON.parse(decodeUtf8(data));
        } catch (error) {
            throw makeNetworkError(error, errorFields);
        }
    }

    async function invokeRaw(method, request, transfer, errorFields) {
        try {
            return await nativeInvoke()(moduleID, method, JSON.stringify(request), transfer || null);
        } catch (error) {
            throw makeNetworkError(error, errorFields);
        }
    }

    async function lookup(host, options) {
        const request = normalizeLookupOptions(options);
        request.host = normalizeHost(host);

        const result = await invokeJSON("lookup", request, {
            operation: "lookup",
            syscall: "getaddrinfo",
            host: request.host,
            family: request.family
        });

        const addresses = Array.isArray(result && result.addresses)
            ? result.addresses.map(normalizeLookupEntry)
            : [];
        if (addresses.length === 0) {
            throw makeNetworkError({ code: 3, message: "lookup returned no addresses" }, {
                operation: "lookup",
                syscall: "getaddrinfo",
                host: request.host,
                family: request.family
            });
        }
        return request.all ? Object.freeze(addresses.slice()) : addresses[0];
    }

    class EJSTCPSocket {
        constructor(record) {
            this._id = String(record.socketID || "");
            this._closed = false;
            this.localAddress = normalizeSocketAddress(record.localAddress);
            this.remoteAddress = normalizeSocketAddress(record.remoteAddress);
            Object.freeze(this.localAddress);
            Object.freeze(this.remoteAddress);
        }

        _request(operation, extra) {
            if (this._closed && operation !== "close") {
                throw makeNetworkError({ code: 2, message: "tcp socket is closed" }, {
                    operation: operation,
                    syscall: operation,
                    address: this.remoteAddress.address,
                    port: this.remoteAddress.port,
                    family: this.remoteAddress.family
                });
            }
            const request = Object.assign({ socketID: this._id }, extra || {});
            return request;
        }

        async read(options) {
            const request = this._request("read", {
                maxBytes: normalizeReadSize(options && options.maxBytes)
            });
            const result = await invokeRaw("tcpRead", request, null, {
                operation: "read",
                syscall: "recv",
                address: this.remoteAddress.address,
                port: this.remoteAddress.port,
                family: this.remoteAddress.family
            });
            return result instanceof Uint8Array ? result : new Uint8Array(result);
        }

        async write(data) {
            const bytes = bytesFromData(data, "tcp");
            await invokeJSON("tcpWrite", this._request("write"), {
                operation: "write",
                syscall: "send",
                address: this.remoteAddress.address,
                port: this.remoteAddress.port,
                family: this.remoteAddress.family
            }, bytes);
        }

        async shutdown() {
            await invokeJSON("tcpShutdown", this._request("shutdown"), {
                operation: "shutdown",
                syscall: "shutdown",
                address: this.remoteAddress.address,
                port: this.remoteAddress.port,
                family: this.remoteAddress.family
            });
        }

        async close() {
            if (this._closed) {
                return;
            }
            this._closed = true;
            await invokeJSON("tcpClose", { socketID: this._id }, {
                operation: "close",
                syscall: "close",
                address: this.remoteAddress.address,
                port: this.remoteAddress.port,
                family: this.remoteAddress.family
            });
        }
    }

    async function tcpConnect(options) {
        const request = normalizeConnectOptions(options);
        const result = await invokeJSON("tcpConnect", request, {
            operation: "connect",
            syscall: "connect",
            host: request.host,
            port: request.port,
            family: request.family
        });
        return new EJSTCPSocket(ensureSocketRecord(result, {
            operation: "connect",
            syscall: "connect",
            host: request.host,
            port: request.port,
            family: request.family
        }, "connect", "tcp"));
    }

    class EJSUDPSocket {
        constructor(record, fields) {
            this._id = String(record.socketID || "");
            this._closed = false;
            this.localAddress = normalizeRequiredSocketAddress(record.localAddress, fields, "udp bind");
            Object.freeze(this.localAddress);
        }

        _request(operation, extra, fields) {
            if (this._closed && operation !== "close") {
                throw makeNetworkError({ code: 2, message: "udp socket is closed" }, fields);
            }
            return Object.assign({ socketID: this._id }, extra || {});
        }

        async send(data, target) {
            const bytes = bytesFromData(data, "udp");
            const endpoint = normalizeUDPSendTarget(target);
            const fields = {
                operation: "send",
                syscall: "sendto",
                host: endpoint.host,
                port: endpoint.port,
                family: endpoint.family
            };
            await invokeJSON("udpSend", this._request("send", endpoint, fields), fields, bytes);
        }

        async recv(options) {
            const requestOptions = normalizeUDPRecvOptions(options);
            const fields = {
                operation: "recv",
                syscall: "recvfrom",
                address: this.localAddress.address,
                port: this.localAddress.port,
                family: this.localAddress.family
            };
            const result = await invokeJSON("udpRecv", this._request("recv", requestOptions, fields), fields);
            return normalizeUDPRecvResult(result, fields);
        }

        async close() {
            if (this._closed) {
                return;
            }
            this._closed = true;
            await invokeJSON("udpClose", { socketID: this._id }, {
                operation: "close",
                syscall: "close",
                address: this.localAddress.address,
                port: this.localAddress.port,
                family: this.localAddress.family
            });
        }
    }

    async function udpBind(options) {
        const request = normalizeUDPBindOptions(options);
        const result = await invokeJSON("udpBind", request, {
            operation: "bind",
            syscall: "bind",
            host: request.host,
            port: request.port,
            family: request.family
        });
        const fields = {
            operation: "bind",
            syscall: "bind",
            host: request.host,
            port: request.port,
            family: request.family
        };
        return new EJSUDPSocket(ensureSocketRecord(result, fields, "bind", "udp"), fields);
    }

    class EJSTCPListener {
        constructor(record) {
            this._id = String(record.listenerID || "");
            this._closed = false;
            this.localAddress = normalizeSocketAddress(record.localAddress);
            Object.freeze(this.localAddress);
        }

        _request(operation, extra) {
            if (this._closed && operation !== "close") {
                throw makeNetworkError({ code: 2, message: "tcp listener is closed" }, {
                    operation: operation,
                    syscall: operation,
                    address: this.localAddress.address,
                    port: this.localAddress.port,
                    family: this.localAddress.family
                });
            }
            return Object.assign({ listenerID: this._id }, extra || {});
        }

        async accept(options) {
            const request = this._request("accept", normalizeAcceptOptions(options));
            const result = await invokeJSON("tcpAccept", request, {
                operation: "accept",
                syscall: "accept",
                address: this.localAddress.address,
                port: this.localAddress.port,
                family: this.localAddress.family
            });
            return new EJSTCPSocket(ensureSocketRecord(result, {
                operation: "accept",
                syscall: "accept",
                address: this.localAddress.address,
                port: this.localAddress.port,
                family: this.localAddress.family
            }, "accept", "tcp"));
        }

        async close() {
            if (this._closed) {
                return;
            }
            this._closed = true;
            await invokeJSON("tcpListenerClose", { listenerID: this._id }, {
                operation: "close",
                syscall: "close",
                address: this.localAddress.address,
                port: this.localAddress.port,
                family: this.localAddress.family
            });
        }
    }

    async function tcpListen(options) {
        const request = normalizeListenOptions(options);
        const result = await invokeJSON("tcpListen", request, {
            operation: "listen",
            syscall: "listen",
            host: request.host,
            port: request.port,
            family: request.family
        });
        if (!result || typeof result.listenerID !== "string") {
            throw makeNetworkError({ code: 8, message: "tcp listen provider returned an invalid listener" }, {
                operation: "listen",
                syscall: "listen",
                host: request.host,
                port: request.port,
                family: request.family
            });
        }
        return new EJSTCPListener(result);
    }

    function EJSNetworkError(message) {
        const error = new Error(message || "network error");
        error.name = "EJSNetworkError";
        return error;
    }

    Object.defineProperty(globalThis, "EJSNetworkError", {
        configurable: true,
        writable: true,
        value: EJSNetworkError
    });

    Object.defineProperty(globalThis, "EJSNet", {
        configurable: true,
        writable: true,
        value: Object.freeze({
            lookup: lookup,
            tcp: Object.freeze({
                connect: tcpConnect,
                listen: tcpListen
            }),
            udp: Object.freeze({
                bind: udpBind
            })
        })
    });
})();
