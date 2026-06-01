(function() {
    const moduleID = "ejs.ws";
    const stateValues = Object.freeze({
        CONNECTING: 0,
        OPEN: 1,
        CLOSING: 2,
        CLOSED: 3
    });
    const eventNames = Object.freeze([
        "open",
        "message",
        "error",
        "close"
    ]);
    const nativeCodeMap = Object.freeze({
        1: "EINVAL",
        2: "ECANCELLED",
        3: "ENETWORK",
        4: "ETLS",
        5: "ETIMEOUT",
        6: "ENOTSUP",
        7: "EPERM",
        8: "EINTERNAL"
    });
    const base64DecodeLookup = (() => {
        const map = new Map();
        const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (let i = 0; i < chars.length; i++) {
            map.set(chars[i], i);
        }
        return map;
    })();
    const protocolTokenPattern = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
    let nextSocketID = 1;

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function closeSocketRequest(payload, suppressErrors) {
        try {
            const promise = nativeInvoke()(moduleID, "close", JSON.stringify(payload), null);
            if (suppressErrors && promise && typeof promise.catch === "function") {
                promise.catch(() => {});
            }
            return promise;
        } catch (error) {
            if (suppressErrors) {
                return Promise.resolve();
            }
            return Promise.reject(error);
        }
    }

    const wsRegistry = typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(socketID => {
        closeSocketRequest({ socketID: socketID }, true);
    }) : null;

    function decodeUtf8(input) {
        const bytes = input instanceof ArrayBuffer
            ? new Uint8Array(input)
            : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        if (typeof globalThis.TextDecoder === "function") {
            return new globalThis.TextDecoder("utf-8").decode(bytes);
        }
        const chunks = [];
        let chunk = [];

        function pushCodeUnit(value) {
            chunk.push(value);
            if (chunk.length >= 4096) {
                chunks.push(String.fromCharCode.apply(null, chunk));
                chunk = [];
            }
        }

        function pushCodePoint(value) {
            if (value <= 0xffff) {
                pushCodeUnit(value);
            } else {
                value -= 0x10000;
                pushCodeUnit(0xd800 | (value >> 10));
                pushCodeUnit(0xdc00 | (value & 0x3ff));
            }
        }

        for (let i = 0; i < bytes.length;) {
            const first = bytes[i++];
            if (first < 0x80) {
                pushCodeUnit(first);
                continue;
            }
            if (first >= 0xc2 && first < 0xe0 && i < bytes.length) {
                const second = bytes[i++];
                pushCodeUnit(((first & 0x1f) << 6) | (second & 0x3f));
                continue;
            }
            if (first >= 0xe0 && first < 0xf0 && i + 1 < bytes.length) {
                const second = bytes[i++];
                const third = bytes[i++];
                pushCodeUnit(((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f));
                continue;
            }
            if (first >= 0xf0 && first < 0xf5 && i + 2 < bytes.length) {
                const second = bytes[i++];
                const third = bytes[i++];
                const fourth = bytes[i++];
                let codePoint = ((first & 0x07) << 18) | ((second & 0x3f) << 12) | ((third & 0x3f) << 6) | (fourth & 0x3f);
                pushCodePoint(codePoint);
                continue;
            }
            pushCodeUnit(0xfffd);
        }
        if (chunk.length > 0) {
            chunks.push(String.fromCharCode.apply(null, chunk));
        }
        return chunks.join("");
    }

    function encodeUtf8(value) {
        if (typeof globalThis.TextEncoder === "function") {
            return new globalThis.TextEncoder().encode(value);
        }
        const bytes = [];
        for (let i = 0; i < value.length; i++) {
            let codePoint = value.charCodeAt(i);
            if (codePoint >= 0xd800 && codePoint <= 0xdbff && i + 1 < value.length) {
                const tail = value.charCodeAt(i + 1);
                if (tail >= 0xdc00 && tail <= 0xdfff) {
                    codePoint = ((codePoint - 0xd800) << 10) + (tail - 0xdc00) + 0x10000;
                    i++;
                }
            }
            if (codePoint < 0x80) {
                bytes.push(codePoint);
            } else if (codePoint < 0x800) {
                bytes.push(0xc0 | (codePoint >> 6), 0x80 | (codePoint & 0x3f));
            } else if (codePoint < 0x10000) {
                bytes.push(
                    0xe0 | (codePoint >> 12),
                    0x80 | ((codePoint >> 6) & 0x3f),
                    0x80 | (codePoint & 0x3f)
                );
            } else {
                bytes.push(
                    0xf0 | (codePoint >> 18),
                    0x80 | ((codePoint >> 12) & 0x3f),
                    0x80 | ((codePoint >> 6) & 0x3f),
                    0x80 | (codePoint & 0x3f)
                );
            }
        }
        return new Uint8Array(bytes);
    }

    function parseJSON(raw) {
        return JSON.parse(decodeUtf8(raw));
    }

    function normalizeURL(value) {
        const text = String(value == null ? "" : value).trim();
        if (text.length === 0) {
            throw new TypeError("WebSocket url must be a non-empty string");
        }
        if (text.indexOf("#") >= 0) {
            throw new TypeError("WebSocket url must not include a fragment");
        }
        if (typeof URL === "function") {
            let parsed;
            try {
                parsed = new URL(text);
            } catch (_) {
                throw new TypeError("WebSocket url is invalid");
            }
            const scheme = parsed.protocol.toLowerCase();
            if (scheme !== "ws:" && scheme !== "wss:") {
                throw new TypeError("WebSocket url must use ws: or wss:");
            }
            if (parsed.hash !== "") {
                throw new TypeError("WebSocket url must not include a fragment");
            }
            if (parsed.hostname.length === 0) {
                throw new TypeError("WebSocket url host is required");
            }
            return parsed.toString();
        }
        if (!/^wss?:\/\//i.test(text)) {
            throw new TypeError("WebSocket url must use ws: or wss:");
        }
        const hostText = text.replace(/^wss?:\/\//i, "").split(/[/?#]/, 1)[0] || "";
        if (hostText.length === 0) {
            throw new TypeError("WebSocket url host is required");
        }
        return text;
    }

    function normalizeProtocols(protocols) {
        if (protocols == null) {
            return [];
        }
        const values = typeof protocols === "string" ? [protocols] : Array.isArray(protocols) ? protocols : null;
        if (values == null) {
            throw new TypeError("WebSocket protocols must be a string or string[]");
        }
        const seen = new Set();
        const output = [];
        for (const item of values) {
            const token = String(item == null ? "" : item).trim();
            if (token.length === 0 || !protocolTokenPattern.test(token)) {
                throw new TypeError("WebSocket protocol is invalid");
            }
            const lower = token.toLowerCase();
            if (seen.has(lower)) {
                throw new TypeError("WebSocket protocols contain duplicates");
            }
            seen.add(lower);
            output.push(token);
        }
        return output;
    }

    function normalizeCloseCode(code) {
        if (code === undefined) {
            return undefined;
        }
        const value = Number(code);
        if (!Number.isInteger(value)) {
            throw new TypeError("WebSocket close code must be an integer");
        }
        if (value !== 1000 && (value < 3000 || value > 4999)) {
            throw new TypeError("WebSocket close code must be 1000 or 3000-4999");
        }
        return value;
    }

    function normalizeCloseReason(reason) {
        if (reason === undefined) {
            return "";
        }
        const text = String(reason);
        const bytes = encodeUtf8(text);
        if (bytes.length > 123) {
            throw new TypeError("WebSocket close reason must be <= 123 UTF-8 bytes");
        }
        return text;
    }

    function makeWSError(error, operation) {
        const codeNumber = error && Number.isInteger(error.code) ? error.code : 8;
        const message = error && typeof error.message === "string" && error.message.length > 0
            ? error.message
            : "websocket " + operation + " failed";
        const shaped = new Error(message);
        shaped.name = "EJSWebSocketError";
        shaped.code = nativeCodeMap[codeNumber] || "EINTERNAL";
        shaped.module = "ws";
        shaped.operation = operation;
        if (error && typeof error.platform_domain === "string") shaped.nativeDomain = error.platform_domain;
        if (error && Number.isInteger(error.platform_code)) shaped.nativeCode = error.platform_code;
        return shaped;
    }

    function createEvent(type, target, extra) {
        const event = {
            type: type,
            target: target,
            currentTarget: target
        };
        if (extra && typeof extra === "object") {
            for (const key of Object.keys(extra)) {
                event[key] = extra[key];
            }
        }
        return Object.freeze(event);
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
                    bytes[i] = raw.charCodeAt(i) & 0xff;
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
                values.push((buffer >>> bits) & 0xff);
            }
        }
        return new Uint8Array(values);
    }

    function decodeBinaryMessage(bytes) {
        if (!Array.isArray(bytes)) {
            throw new TypeError("WebSocket binary payload is invalid");
        }
        const output = new Uint8Array(bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            const value = Number(bytes[i]);
            if (!Number.isInteger(value) || value < 0 || value > 255) {
                throw new TypeError("WebSocket binary payload is invalid");
            }
            output[i] = value;
        }
        return output.buffer.slice(output.byteOffset, output.byteOffset + output.byteLength);
    }

    class WebSocketImpl {
        constructor(url, protocols) {
            this.url = normalizeURL(url);
            this.protocol = "";
            this.readyState = stateValues.CONNECTING;
            this.bufferedAmount = 0;
            this._binaryType = "arraybuffer";
            this._listeners = Object.create(null);
            this._socketID = "ws-" + String(nextSocketID++);
            this._lastError = null;
            this._terminalDispatched = false;
            this._connectResolved = false;
            if (wsRegistry) {
                wsRegistry.register(this, this._socketID, this);
            }

            this.onopen = null;
            this.onmessage = null;
            this.onerror = null;
            this.onclose = null;

            const normalizedProtocols = normalizeProtocols(protocols);
            this._connect(normalizedProtocols);
        }

        get binaryType() {
            return this._binaryType;
        }

        set binaryType(value) {
            const text = String(value == null ? "" : value).toLowerCase();
            if (text !== "arraybuffer") {
                throw new TypeError("WebSocket binaryType supports only \"arraybuffer\" in phase 5A");
            }
            this._binaryType = text;
        }

        addEventListener(type, listener) {
            if (!eventNames.includes(type) || typeof listener !== "function") {
                return;
            }
            const bucket = this._listeners[type] || (this._listeners[type] = new Set());
            bucket.add(listener);
        }

        removeEventListener(type, listener) {
            const bucket = this._listeners[type];
            if (!bucket || typeof listener !== "function") {
                return;
            }
            bucket.delete(listener);
        }

        send(data) {
            if (this.readyState !== stateValues.OPEN) {
                throw new Error("WebSocket send requires OPEN state");
            }
            const payload = { socketID: this._socketID };
            let transfer = null;

            if (typeof data === "string") {
                payload.messageType = "text";
                payload.data = data;
            } else if (data instanceof ArrayBuffer) {
                payload.messageType = "binary";
                transfer = new Uint8Array(data);
            } else if (ArrayBuffer.isView(data)) {
                payload.messageType = "binary";
                transfer = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            } else {
                throw new TypeError("WebSocket send data must be string, ArrayBuffer, or ArrayBufferView");
            }

            nativeInvoke()(moduleID, "send", JSON.stringify(payload), transfer)
                .catch((error) => {
                    if (this.readyState === stateValues.CLOSED) {
                        return;
                    }
                    this._emitError(makeWSError(error, "send"));
                    this._finalizeClose(1006, "", false);
                });
        }

        close(code, reason) {
            if (this.readyState === stateValues.CLOSING || this.readyState === stateValues.CLOSED) {
                return;
            }
            const normalizedCode = normalizeCloseCode(code);
            const normalizedReason = normalizeCloseReason(reason);
            const payload = { socketID: this._socketID };
            if (normalizedCode !== undefined) {
                payload.code = normalizedCode;
            }
            if (reason !== undefined || normalizedCode !== undefined) {
                payload.reason = normalizedReason;
            }

            if (this.readyState === stateValues.CONNECTING || this.readyState === stateValues.OPEN) {
                this.readyState = stateValues.CLOSING;
            }
            closeSocketRequest(payload, false)
                .catch((error) => {
                    if (this.readyState === stateValues.CLOSED) {
                        return;
                    }
                    this._emitError(makeWSError(error, "close"));
                    this._finalizeClose(1006, "", false);
                });
        }

        _connect(protocols) {
            const payload = {
                socketID: this._socketID,
                url: this.url,
                protocols: protocols
            };

            nativeInvoke()(moduleID, "connect", JSON.stringify(payload), null)
                .then(() => {
                    this._connectResolved = true;
                    this._pollEvents();
                })
                .catch((error) => {
                    this._emitError(makeWSError(error, "connect"));
                    this._finalizeClose(1006, "", false);
                });
        }

        _pollEvents() {
            if (!this._connectResolved || this.readyState === stateValues.CLOSED) {
                return;
            }
            nativeInvoke()(moduleID, "nextEvent", JSON.stringify({ socketID: this._socketID }), null)
                .then((raw) => {
                    if (this.readyState === stateValues.CLOSED) {
                        return;
                    }
                    const event = parseJSON(raw);
                    this._handleNativeEvent(event);
                    if (this.readyState !== stateValues.CLOSED) {
                        this._pollEvents();
                    }
                })
                .catch((error) => {
                    if (this.readyState === stateValues.CLOSED) {
                        return;
                    }
                    this._emitError(makeWSError(error, "nextEvent"));
                    this._finalizeClose(1006, "", false);
                });
        }

        _handleNativeEvent(nativeEvent) {
            const kind = nativeEvent && typeof nativeEvent.event === "string"
                ? nativeEvent.event
                : "";
            if (kind === "open") {
                if (this.readyState !== stateValues.CONNECTING) {
                    return;
                }
                this.protocol = typeof nativeEvent.protocol === "string" ? nativeEvent.protocol : "";
                this.readyState = stateValues.OPEN;
                this._dispatchEvent("open");
                return;
            }
            if (kind === "message") {
                if (this.readyState !== stateValues.OPEN) {
                    return;
                }
                let data = null;
                if (nativeEvent.messageType === "text") {
                    data = typeof nativeEvent.data === "string" ? nativeEvent.data : "";
                } else if (nativeEvent.messageType === "binary") {
                    if (typeof nativeEvent.dataBase64 === "string") {
                        const bytes = decodeBase64ToBytes(nativeEvent.dataBase64);
                        if (bytes == null) {
                            throw new TypeError("WebSocket binary payload is invalid");
                        }
                        data = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
                    } else {
                        data = decodeBinaryMessage(nativeEvent.bytes);
                    }
                } else {
                    throw new TypeError("WebSocket message type is invalid");
                }
                this._dispatchEvent("message", { data: data });
                return;
            }
            if (kind === "error") {
                this._emitError(makeWSError(nativeEvent.error || nativeEvent, "event"));
                return;
            }
            if (kind === "close") {
                const closeCode = Number(nativeEvent.code);
                const code = Number.isInteger(closeCode) ? closeCode : 1005;
                const reason = typeof nativeEvent.reason === "string" ? nativeEvent.reason : "";
                const wasClean = !!nativeEvent.wasClean;
                this._finalizeClose(code, reason, wasClean);
            }
        }

        _emitError(error) {
            this._lastError = error;
            this._dispatchEvent("error", { error: error, message: error.message || "" });
        }

        _finalizeClose(code, reason, wasClean) {
            if (this._terminalDispatched) {
                return;
            }
            this._terminalDispatched = true;
            this.readyState = stateValues.CLOSED;
            if (wsRegistry) {
                wsRegistry.unregister(this);
            }
            this._dispatchEvent("close", {
                code: code,
                reason: reason,
                wasClean: !!wasClean
            });
        }

        _dispatchEvent(type, extra) {
            const event = createEvent(type, this, extra);
            const handler = this["on" + type];
            if (typeof handler === "function") {
                try {
                    handler.call(this, event);
                } catch (_) {}
            }
            const listeners = this._listeners[type];
            if (!listeners || listeners.size === 0) {
                return;
            }
            for (const listener of Array.from(listeners)) {
                try {
                    listener.call(this, event);
                } catch (_) {}
            }
        }
    }

    class WebSocket extends WebSocketImpl {}

    Object.defineProperties(WebSocket, {
        CONNECTING: { value: stateValues.CONNECTING, enumerable: true },
        OPEN: { value: stateValues.OPEN, enumerable: true },
        CLOSING: { value: stateValues.CLOSING, enumerable: true },
        CLOSED: { value: stateValues.CLOSED, enumerable: true }
    });

    Object.defineProperties(WebSocket.prototype, {
        CONNECTING: { value: stateValues.CONNECTING, enumerable: true },
        OPEN: { value: stateValues.OPEN, enumerable: true },
        CLOSING: { value: stateValues.CLOSING, enumerable: true },
        CLOSED: { value: stateValues.CLOSED, enumerable: true }
    });

    function EJSWebSocketError(message) {
        const error = new Error(message || "websocket error");
        error.name = "EJSWebSocketError";
        return error;
    }

    Object.defineProperty(globalThis, "WebSocket", {
        configurable: true,
        enumerable: false,
        writable: true,
        value: WebSocket
    });
    Object.defineProperty(globalThis, "EJSWebSocketError", {
        configurable: true,
        enumerable: false,
        writable: true,
        value: EJSWebSocketError
    });
    Object.defineProperty(globalThis, "EJSWebSocket", {
        configurable: true,
        enumerable: false,
        writable: true,
        value: Object.freeze({
            installed: true,
            moduleID: moduleID,
            events: Object.freeze(eventNames.slice()),
            supportedBinaryTypes: Object.freeze(["arraybuffer"])
        })
    });
})();
