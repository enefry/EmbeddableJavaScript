(function() {
    const moduleID = "ejs.worker";

    const state = {
        workerID: "",
        closed: false,
        maxQueuedMessages: 64,
        queuedOutgoingCount: 0,
        listeners: {
            message: new Set(),
            error: new Set(),
            messageerror: new Set(),
            unhandledrejection: new Set(),
            rejectionhandled: new Set()
        },
        sendChain: Promise.resolve(),
        onmessage: null,
        onerror: null,
        onmessageerror: null,
        onunhandledrejection: null,
        onrejectionhandled: null
    };

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function hasSharedArrayBuffer(value) {
        return typeof SharedArrayBuffer !== "undefined" && value instanceof SharedArrayBuffer;
    }

    function asUint8Array(value) {
        if (value == null) {
            return new Uint8Array(0);
        }
        if (value instanceof Uint8Array) {
            return value;
        }
        if (value instanceof ArrayBuffer) {
            return new Uint8Array(value);
        }
        if (ArrayBuffer.isView(value)) {
            return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        }
        throw new TypeError("expected ArrayBuffer or ArrayBufferView");
    }

    function encodeUtf8(input) {
        const text = String(input);
        if (typeof TextEncoder !== "undefined") {
            return new TextEncoder().encode(text);
        }
        const bytes = [];
        for (let i = 0; i < text.length; i++) {
            let codePoint = text.charCodeAt(i);
            if (codePoint >= 0xd800 && codePoint <= 0xdbff) {
                if (i + 1 < text.length) {
                    const trail = text.charCodeAt(i + 1);
                    if (trail >= 0xdc00 && trail <= 0xdfff) {
                        codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (trail - 0xdc00);
                        i += 1;
                    } else {
                        codePoint = 0xfffd;
                    }
                } else {
                    codePoint = 0xfffd;
                }
            } else if (codePoint >= 0xdc00 && codePoint <= 0xdfff) {
                codePoint = 0xfffd;
            }

            if (codePoint <= 0x7f) {
                bytes.push(codePoint);
            } else if (codePoint <= 0x7ff) {
                bytes.push(0xc0 | (codePoint >> 6));
                bytes.push(0x80 | (codePoint & 0x3f));
            } else if (codePoint <= 0xffff) {
                bytes.push(0xe0 | (codePoint >> 12));
                bytes.push(0x80 | ((codePoint >> 6) & 0x3f));
                bytes.push(0x80 | (codePoint & 0x3f));
            } else {
                bytes.push(0xf0 | (codePoint >> 18));
                bytes.push(0x80 | ((codePoint >> 12) & 0x3f));
                bytes.push(0x80 | ((codePoint >> 6) & 0x3f));
                bytes.push(0x80 | (codePoint & 0x3f));
            }
        }
        return new Uint8Array(bytes);
    }

    function decodeUtf8(input) {
        const bytes = asUint8Array(input);
        if (typeof TextDecoder !== "undefined") {
            return new TextDecoder("utf-8").decode(bytes);
        }
        let output = "";
        function isContinuation(byte) {
            return byte >= 0x80 && byte <= 0xbf;
        }
        for (let i = 0; i < bytes.length;) {
            const first = bytes[i++];
            let codePoint = first;
            if (first <= 0x7f) {
                codePoint = first;
            } else if (first >= 0xc2 && first <= 0xdf) {
                if (i < bytes.length && isContinuation(bytes[i])) {
                    const second = bytes[i++];
                    codePoint = ((first & 0x1f) << 6) | (second & 0x3f);
                } else {
                    codePoint = 0xfffd;
                }
            } else if (first >= 0xe0 && first <= 0xef) {
                if (i + 1 < bytes.length && isContinuation(bytes[i]) && isContinuation(bytes[i + 1])) {
                    const second = bytes[i++];
                    const third = bytes[i++];
                    codePoint = ((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f);
                } else {
                    codePoint = 0xfffd;
                }
            } else if (first >= 0xf0 && first <= 0xf4) {
                if (i + 2 < bytes.length && isContinuation(bytes[i]) && isContinuation(bytes[i + 1]) && isContinuation(bytes[i + 2])) {
                    const second = bytes[i++];
                    const third = bytes[i++];
                    const fourth = bytes[i++];
                    codePoint = ((first & 0x07) << 18) | ((second & 0x3f) << 12) | ((third & 0x3f) << 6) | (fourth & 0x3f);
                } else {
                    codePoint = 0xfffd;
                }
            } else {
                codePoint = 0xfffd;
            }
            if (codePoint <= 0xffff) {
                output += String.fromCharCode(codePoint);
            } else {
                codePoint -= 0x10000;
                output += String.fromCharCode(0xd800 + (codePoint >> 10));
                output += String.fromCharCode(0xdc00 + (codePoint & 0x3ff));
            }
        }
        return output;
    }

    function decodeFrame(frameData) {
        const bytes = asUint8Array(frameData);
        if (bytes.length < 4) {
            throw new Error("Worker frame is truncated");
        }
        const headerLength = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
        const headerEnd = 4 + headerLength;
        if (headerLength < 0 || headerEnd > bytes.length) {
            throw new Error("Worker frame header is invalid");
        }
        const header = JSON.parse(decodeUtf8(bytes.subarray(4, headerEnd)));
        const payload = bytes.subarray(headerEnd).slice().buffer;
        return {
            envelope: header.envelope || {},
            sidecar: payload
        };
    }

    function isPlainObject(value) {
        if (value == null || typeof value !== "object") {
            return false;
        }
        const proto = Object.getPrototypeOf(value);
        return proto === Object.prototype || proto === null;
    }

    function normalizeTransferList(transferList) {
        if (transferList == null) {
            return [];
        }
        if (typeof transferList[Symbol.iterator] !== "function") {
            throw new TypeError("transferList must be iterable");
        }
        const seen = new Set();
        const result = [];
        for (const entry of transferList) {
            let buffer = null;
            if (entry instanceof ArrayBuffer) {
                buffer = entry;
            } else if (ArrayBuffer.isView(entry)) {
                buffer = entry.buffer;
            } else {
                throw new TypeError("transferList entries must be ArrayBuffer or ArrayBufferView");
            }
            if (hasSharedArrayBuffer(buffer)) {
                throw new TypeError("SharedArrayBuffer is not supported");
            }
            if (seen.has(buffer)) {
                throw new TypeError("transferList contains duplicate buffers");
            }
            seen.add(buffer);
            result.push(buffer);
        }
        return result;
    }

    function detachTransferredBuffer(buffer) {
        if (buffer == null) {
            return;
        }
        if (typeof buffer.transfer === "function") {
            buffer.transfer(0);
        }
    }

    function serializeForMessage(value, transferList) {
        const transferBuffers = normalizeTransferList(transferList);
        const transferSet = new Set(transferBuffers);
        const seenObjects = new Set();
        const encounteredBuffers = new Set();
        const bufferRecords = [];
        const bufferIDs = new Map();
        let totalLength = 0;

        function appendBuffer(buffer) {
            if (bufferIDs.has(buffer)) {
                return bufferRecords[bufferIDs.get(buffer)];
            }
            const copy = new Uint8Array(buffer).slice();
            const entry = {
                id: bufferRecords.length,
                bytes: copy,
                offset: totalLength,
                length: copy.length,
                transfer: transferSet.has(buffer)
            };
            bufferIDs.set(buffer, entry.id);
            bufferRecords.push(entry);
            totalLength += copy.length;
            return entry;
        }

        function encodeValue(innerValue) {
            if (innerValue === null) return { kind: "null" };
            const valueType = typeof innerValue;
            if (valueType === "boolean" || valueType === "string") {
                return { kind: valueType, value: innerValue };
            }
            if (valueType === "number") {
                if (!Number.isFinite(innerValue)) {
                    throw new TypeError("Only finite numbers are supported in worker messages");
                }
                return { kind: "number", value: innerValue };
            }
            if (valueType === "undefined") {
                return { kind: "undefined" };
            }
            if (valueType === "function" || valueType === "symbol" || valueType === "bigint") {
                throw new TypeError("Unsupported value in worker message");
            }
            if (hasSharedArrayBuffer(innerValue)) {
                throw new TypeError("SharedArrayBuffer is not supported");
            }

            if (innerValue instanceof ArrayBuffer) {
                encounteredBuffers.add(innerValue);
                const record = appendBuffer(innerValue);
                return {
                    kind: "arraybuffer",
                    buffer: record.id
                };
            }

            if (ArrayBuffer.isView(innerValue)) {
                if (hasSharedArrayBuffer(innerValue.buffer)) {
                    throw new TypeError("SharedArrayBuffer is not supported");
                }
                encounteredBuffers.add(innerValue.buffer);
                const record = appendBuffer(innerValue.buffer);
                return {
                    kind: "view",
                    ctor: innerValue.constructor ? innerValue.constructor.name : "",
                    buffer: record.id,
                    byteOffset: innerValue.byteOffset,
                    byteLength: innerValue.byteLength,
                    elements: typeof innerValue.length === "number" ? innerValue.length : null,
                    transfer: transferSet.has(innerValue.buffer)
                };
            }

            if (innerValue instanceof Date ||
                innerValue instanceof Map ||
                innerValue instanceof Set ||
                innerValue instanceof RegExp ||
                innerValue instanceof Error ||
                innerValue instanceof WeakMap ||
                innerValue instanceof WeakSet) {
                throw new TypeError("Unsupported object type in worker message");
            }

            if (seenObjects.has(innerValue)) {
                throw new TypeError("Cyclic structures are not supported in worker messages");
            }
            seenObjects.add(innerValue);
            try {
                if (Array.isArray(innerValue)) {
                    return {
                        kind: "array",
                        value: innerValue.map(encodeValue)
                    };
                }
                if (!isPlainObject(innerValue)) {
                    throw new TypeError("Unsupported object type in worker message");
                }
                const entries = [];
                const keys = Object.keys(innerValue);
                for (let i = 0; i < keys.length; i++) {
                    const key = keys[i];
                    entries.push([key, encodeValue(innerValue[key])]);
                }
                return {
                    kind: "object",
                    value: entries
                };
            } finally {
                seenObjects.delete(innerValue);
            }
        }

        const payload = encodeValue(value);
        for (let i = 0; i < transferBuffers.length; i++) {
            if (!encounteredBuffers.has(transferBuffers[i])) {
                throw new TypeError("transferList contains a buffer not present in the message");
            }
        }

        const sidecar = new Uint8Array(totalLength);
        const buffers = [];
        for (let i = 0; i < bufferRecords.length; i++) {
            const entry = bufferRecords[i];
            sidecar.set(entry.bytes, entry.offset);
            buffers.push({
                offset: entry.offset,
                length: entry.length,
                transfer: entry.transfer
            });
        }

        return {
            envelope: {
                kind: "message",
                version: 1,
                payload,
                buffers
            },
            sidecar: sidecar.buffer,
            detachers: transferBuffers
        };
    }

    function deserializeFromMessage(envelope, sidecar) {
        if (!envelope || envelope.version !== 1 || !envelope.payload) {
            throw new TypeError("Invalid worker message envelope");
        }
        const sidecarBytes = asUint8Array(sidecar);
        const bufferTable = Array.isArray(envelope.buffers) ? envelope.buffers : [];
        const decodedBuffers = new Map();

        function sliceBuffer(offset, length) {
            if (!Number.isInteger(offset) || !Number.isInteger(length) || offset < 0 || length < 0) {
                throw new TypeError("Invalid worker payload offsets");
            }
            if (offset + length > sidecarBytes.length) {
                throw new TypeError("Worker payload exceeds sidecar bounds");
            }
            return sidecarBytes.subarray(offset, offset + length).slice().buffer;
        }

        function decodeBuffer(bufferID) {
            if (!Number.isInteger(bufferID) || bufferID < 0 || bufferID >= bufferTable.length) {
                throw new TypeError("Invalid worker payload buffer reference");
            }
            if (decodedBuffers.has(bufferID)) {
                return decodedBuffers.get(bufferID);
            }
            const record = bufferTable[bufferID];
            if (!record || typeof record !== "object") {
                throw new TypeError("Invalid worker payload buffer record");
            }
            const buffer = sliceBuffer(record.offset, record.length);
            decodedBuffers.set(bufferID, buffer);
            return buffer;
        }

        function decodeValue(node) {
            if (!node || typeof node !== "object") {
                throw new TypeError("Invalid worker payload node");
            }
            if (node.kind === "null") return null;
            if (node.kind === "undefined") return undefined;
            if (node.kind === "boolean" || node.kind === "string" || node.kind === "number") return node.value;
            if (node.kind === "arraybuffer") {
                if (Number.isInteger(node.buffer)) {
                    return decodeBuffer(node.buffer);
                }
                return sliceBuffer(node.offset, node.length);
            }
            if (node.kind === "view") {
                let bytes;
                let byteOffset = 0;
                let byteLength = node.length;
                if (Number.isInteger(node.buffer)) {
                    bytes = decodeBuffer(node.buffer);
                    byteOffset = node.byteOffset;
                    byteLength = node.byteLength;
                    if (!Number.isInteger(byteOffset) || !Number.isInteger(byteLength) ||
                        byteOffset < 0 || byteLength < 0 || byteOffset + byteLength > bytes.byteLength) {
                        throw new TypeError("Invalid typed array view metadata in worker payload");
                    }
                } else {
                    bytes = sliceBuffer(node.offset, node.length);
                }
                if (node.ctor === "DataView") {
                    return new DataView(bytes, byteOffset, byteLength);
                }
                const ctor = globalThis[node.ctor];
                if (typeof ctor !== "function" || typeof ctor.BYTES_PER_ELEMENT !== "number") {
                    throw new TypeError("Unsupported typed array constructor in worker payload");
                }
                if (!Number.isInteger(node.elements) || node.elements < 0) {
                    throw new TypeError("Invalid typed array metadata in worker payload");
                }
                return new ctor(bytes, byteOffset, node.elements);
            }
            if (node.kind === "array") {
                const values = Array.isArray(node.value) ? node.value : [];
                const out = new Array(values.length);
                for (let i = 0; i < values.length; i++) {
                    out[i] = decodeValue(values[i]);
                }
                return out;
            }
            if (node.kind === "object") {
                const out = {};
                const entries = Array.isArray(node.value) ? node.value : [];
                for (let i = 0; i < entries.length; i++) {
                    const pair = entries[i];
                    if (!Array.isArray(pair) || pair.length !== 2) {
                        throw new TypeError("Invalid object entry in worker payload");
                    }
                    out[String(pair[0])] = decodeValue(pair[1]);
                }
                return out;
            }
            throw new TypeError("Unsupported worker payload kind");
        }

        return decodeValue(envelope.payload);
    }

    function makeEvent(type, data) {
        const event = {
            type,
            target: globalThis,
            currentTarget: globalThis,
            cancelable: !!(data && data.cancelable),
            defaultPrevented: false,
            preventDefault() {
                if (this.cancelable) {
                    this.defaultPrevented = true;
                }
            }
        };
        if (data && typeof data === "object") {
            const keys = Object.keys(data);
            for (let i = 0; i < keys.length; i++) {
                if (keys[i] !== "cancelable") {
                    event[keys[i]] = data[keys[i]];
                }
            }
        }
        return event;
    }

    function isSupportedEventType(type) {
        return type === "message" ||
            type === "error" ||
            type === "messageerror" ||
            type === "unhandledrejection" ||
            type === "rejectionhandled";
    }

    function dispatch(type, event) {
        const propertyName = "on" + type;
        const propertyHandler = state[propertyName];
        if (typeof propertyHandler === "function") {
            try {
                propertyHandler.call(globalThis, event);
            } catch (error) {
                globalThis.__EJSWorkerLastError = error;
                reportError(error);
            }
        }
        const listeners = Array.from(state.listeners[type] || []);
        for (let i = 0; i < listeners.length; i++) {
            try {
                listeners[i].call(globalThis, event);
            } catch (error) {
                globalThis.__EJSWorkerLastError = error;
                reportError(error);
            }
        }
    }

    function reportError(error) {
        const wrapped = error instanceof Error ? error : new Error(String(error));
        Promise.resolve(
            nativeInvoke()(moduleID, "reportError", JSON.stringify({
                message: String(wrapped.message || wrapped),
                filename: "",
                stack: typeof wrapped.stack === "string" ? wrapped.stack : "",
                error: String(wrapped)
            }), null)
        ).catch(() => {});
    }

    function installPromiseRejectionTracker() {
        const nativeEvents = globalThis.__ejs_native__ && globalThis.__ejs_native__.events;
        if (!nativeEvents || typeof nativeEvents.setPromiseRejectionTracker !== "function") {
            return;
        }
        nativeEvents.setPromiseRejectionTracker(function(kind, promise, reason) {
            const type = kind === "handled" ? "rejectionhandled" : "unhandledrejection";
            const event = makeEvent(type, {
                cancelable: type === "unhandledrejection",
                promise,
                reason
            });
            dispatch(type, event);
            if (type === "unhandledrejection" && !event.defaultPrevented) {
                reportError(reason);
            }
        });
    }

    function postMessage(value, transferList) {
        if (state.closed) {
            throw new Error("Worker global scope has been closed");
        }
        const encoded = serializeForMessage(value, transferList);
        if (state.queuedOutgoingCount >= state.maxQueuedMessages) {
            throw new Error("Worker outgoing queue exceeds maxQueuedMessages");
        }
        for (let i = 0; i < encoded.detachers.length; i++) {
            detachTransferredBuffer(encoded.detachers[i]);
        }
        state.queuedOutgoingCount += 1;
        state.sendChain = state.sendChain.then(() => {
            return Promise.resolve(
                nativeInvoke()(moduleID, "postMessage", JSON.stringify({
                    direction: "toParent",
                    envelope: encoded.envelope
                }), encoded.sidecar)
            ).catch((error) => {
                dispatch("error", makeEvent("error", {
                    message: String(error && error.message ? error.message : error),
                    error
                }));
                reportError(error);
            });
        }).finally(() => {
            state.queuedOutgoingCount -= 1;
        });
    }

    function close() {
        if (state.closed) {
            return;
        }
        state.closed = true;
        state.sendChain = state.sendChain
            .catch(() => {})
            .then(() => nativeInvoke()(moduleID, "close", JSON.stringify({}), null))
            .catch(() => {});
    }

    function addEventListener(type, handler) {
        if (!isSupportedEventType(type)) {
            return;
        }
        if (typeof handler !== "function") {
            throw new TypeError("Event listener must be a function");
        }
        state.listeners[type].add(handler);
    }

    function removeEventListener(type, handler) {
        if (!isSupportedEventType(type)) {
            return;
        }
        if (typeof handler !== "function") {
            return;
        }
        state.listeners[type].delete(handler);
    }

    globalThis.__EJSWorkerBootstrap = function(config) {
        const value = config && typeof config === "object" ? config : {};
        state.workerID = typeof value.workerID === "string" ? value.workerID : "";
        if (Number.isFinite(value.maxQueuedMessages) && value.maxQueuedMessages > 0) {
            state.maxQueuedMessages = Math.floor(value.maxQueuedMessages);
        }
    };

    globalThis.__EJSWorkerDispatch = function(workerID, messageID) {
        if (state.closed) {
            return;
        }
        if (state.workerID.length > 0 && String(workerID) !== state.workerID) {
            return;
        }
        Promise.resolve(
            nativeInvoke()(moduleID, "takeMessage", JSON.stringify({
                direction: "toChild",
                messageID: String(messageID)
            }), null)
        ).then((raw) => {
            const decoded = decodeFrame(raw);
            if (decoded.envelope.kind === "error") {
                const errorData = decoded.envelope.error || {};
                dispatch("error", makeEvent("error", {
                    message: String(errorData.message || "Worker error"),
                    filename: String(errorData.filename || ""),
                    stack: String(errorData.stack || ""),
                    error: errorData.error || new Error(String(errorData.message || "Worker error"))
                }));
                return;
            }

            try {
                const data = deserializeFromMessage(decoded.envelope, decoded.sidecar);
                dispatch("message", makeEvent("message", { data }));
            } catch (error) {
                dispatch("messageerror", makeEvent("messageerror", {
                    message: String(error && error.message ? error.message : error),
                    error
                }));
                reportError(error);
            }
        }).catch((error) => {
            dispatch("error", makeEvent("error", {
                message: String(error && error.message ? error.message : error),
                error
            }));
            reportError(error);
        });
    };

    Object.defineProperty(globalThis, "onmessage", {
        configurable: true,
        enumerable: true,
        get() { return state.onmessage; },
        set(value) { state.onmessage = typeof value === "function" ? value : null; }
    });

    Object.defineProperty(globalThis, "onerror", {
        configurable: true,
        enumerable: true,
        get() { return state.onerror; },
        set(value) { state.onerror = typeof value === "function" ? value : null; }
    });

    Object.defineProperty(globalThis, "onmessageerror", {
        configurable: true,
        enumerable: true,
        get() { return state.onmessageerror; },
        set(value) { state.onmessageerror = typeof value === "function" ? value : null; }
    });

    Object.defineProperty(globalThis, "onunhandledrejection", {
        configurable: true,
        enumerable: true,
        get() { return state.onunhandledrejection; },
        set(value) { state.onunhandledrejection = typeof value === "function" ? value : null; }
    });

    Object.defineProperty(globalThis, "onrejectionhandled", {
        configurable: true,
        enumerable: true,
        get() { return state.onrejectionhandled; },
        set(value) { state.onrejectionhandled = typeof value === "function" ? value : null; }
    });

    if (globalThis.self === undefined) {
        Object.defineProperty(globalThis, "self", {
            configurable: true,
            writable: true,
            value: globalThis
        });
    }

    globalThis.postMessage = postMessage;
    globalThis.addEventListener = addEventListener;
    globalThis.removeEventListener = removeEventListener;
    globalThis.close = close;
    installPromiseRejectionTracker();
})();
