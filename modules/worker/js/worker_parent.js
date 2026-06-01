(function() {
    const moduleID = "ejs.worker";
    const DEFAULT_MAX_QUEUED_MESSAGES = 64;
    const workerTable = new Map();

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
                if (i + 1 < bytes.length &&
                    isContinuation(bytes[i]) &&
                    isContinuation(bytes[i + 1]) &&
                    (first !== 0xe0 || bytes[i] >= 0xa0) &&
                    (first !== 0xed || bytes[i] <= 0x9f)) {
                    const second = bytes[i++];
                    const third = bytes[i++];
                    codePoint = ((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f);
                } else {
                    codePoint = 0xfffd;
                }
            } else if (first >= 0xf0 && first <= 0xf4) {
                if (i + 2 < bytes.length &&
                    isContinuation(bytes[i]) &&
                    isContinuation(bytes[i + 1]) &&
                    isContinuation(bytes[i + 2]) &&
                    (first !== 0xf0 || bytes[i] >= 0x90) &&
                    (first !== 0xf4 || bytes[i] <= 0x8f)) {
                    const second = bytes[i++];
                    const third = bytes[i++];
                    const fourth = bytes[i++];
                    codePoint = ((first & 0x07) << 18) |
                        ((second & 0x3f) << 12) |
                        ((third & 0x3f) << 6) |
                        (fourth & 0x3f);
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

    function parseJSONBytes(data) {
        const bytes = asUint8Array(data);
        if (bytes.length === 0) {
            return {};
        }
        return JSON.parse(decodeUtf8(bytes));
    }

    function encodeFrame(envelope, sidecar) {
        const envelopeBytes = encodeUtf8(JSON.stringify({ envelope }));
        const sidecarBytes = asUint8Array(sidecar);
        const output = new Uint8Array(4 + envelopeBytes.length + sidecarBytes.length);
        output[0] = envelopeBytes.length & 0xff;
        output[1] = (envelopeBytes.length >>> 8) & 0xff;
        output[2] = (envelopeBytes.length >>> 16) & 0xff;
        output[3] = (envelopeBytes.length >>> 24) & 0xff;
        output.set(envelopeBytes, 4);
        output.set(sidecarBytes, 4 + envelopeBytes.length);
        return output.buffer;
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
            if (innerValue === null) {
                return { kind: "null" };
            }
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
            if (node.kind === "null") {
                return null;
            }
            if (node.kind === "undefined") {
                return undefined;
            }
            if (node.kind === "boolean" || node.kind === "string" || node.kind === "number") {
                return node.value;
            }
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

    function normalizeWorkerOptions(options) {
        if (options == null) {
            return {};
        }
        if (typeof options !== "object") {
            throw new TypeError("Worker options must be an object");
        }
        const out = {};
        if (options.root != null) {
            if (typeof options.root !== "string" || options.root.length === 0) {
                throw new TypeError("Worker options.root must be a non-empty string");
            }
            out.root = options.root;
        }
        if (options.type != null) {
            const type = String(options.type);
            if (type !== "classic" && type !== "module") {
                throw new TypeError("Worker options.type must be 'classic' or 'module'");
            }
            out.type = type;
        }
        if (options.name != null) {
            out.name = String(options.name);
        }
        return out;
    }

    function makeEvent(target, type, data) {
        const event = {
            type,
            target,
            currentTarget: target
        };
        if (data && typeof data === "object") {
            const keys = Object.keys(data);
            for (let i = 0; i < keys.length; i++) {
                event[keys[i]] = data[keys[i]];
            }
        }
        return event;
    }

    function makeErrorEvent(target, error) {
        const wrapped = error instanceof Error ? error : new Error(String(error));
        return makeEvent(target, "error", {
            message: String(wrapped.message || wrapped),
            filename: "",
            stack: typeof wrapped.stack === "string" ? wrapped.stack : "",
            error: wrapped
        });
    }

    function Worker(specifier, options) {
        if (!(this instanceof Worker)) {
            throw new TypeError("Worker constructor must be called with new");
        }
        if (typeof specifier !== "string" || specifier.length === 0) {
            throw new TypeError("Worker specifier must be a non-empty string");
        }

        this._listeners = {
            message: new Set(),
            error: new Set(),
            messageerror: new Set()
        };
        this._state = "starting";
        this._workerID = "";
        this._maxQueuedMessages = DEFAULT_MAX_QUEUED_MESSAGES;
        this._pendingOutgoing = [];
        this._pendingIncoming = [];
        this._queuedOutgoingCount = 0;
        this._sendChain = Promise.resolve();
        this._specifier = specifier;
        this._name = "";
        this._terminatedPromise = null;
        this.onmessage = null;
        this.onerror = null;
        this.onmessageerror = null;

        const request = {
            specifier,
            options: normalizeWorkerOptions(options)
        };

        this._createPromise = Promise.resolve(
            nativeInvoke()(moduleID, "create", JSON.stringify(request), null)
        ).then((raw) => {
            const response = parseJSONBytes(raw);
            if (typeof response.workerID !== "string" || response.workerID.length === 0) {
                throw new Error("Worker create response is missing workerID");
            }
            this._workerID = response.workerID;
            this._name = typeof response.name === "string" ? response.name : "";
            if (Number.isFinite(response.maxQueuedMessages) && response.maxQueuedMessages > 0) {
                this._maxQueuedMessages = Math.floor(response.maxQueuedMessages);
            }
            workerTable.set(this._workerID, this);

            if (this._state === "terminating" || this._state === "terminated") {
                return this._terminateNow();
            }

            return Promise.resolve(
                nativeInvoke()(moduleID, "start", JSON.stringify({ workerID: this._workerID }), null)
            );
        }).then(() => {
            if (this._state === "terminated") {
                return undefined;
            }
            if (this._state === "terminating") {
                return this._terminateNow();
            }

            this._state = "running";
            const incoming = this._pendingIncoming;
            this._pendingIncoming = [];
            for (let i = 0; i < incoming.length; i++) {
                this._onDispatch(incoming[i]);
            }

            const queued = this._pendingOutgoing;
            this._pendingOutgoing = [];
            for (let i = 0; i < queued.length; i++) {
                this._enqueueOutgoing(queued[i]);
            }
            return undefined;
        }).catch((error) => {
            if (this._workerID.length > 0) {
                const failedWorkerID = this._workerID;
                workerTable.delete(failedWorkerID);
                Promise.resolve(
                    nativeInvoke()(moduleID, "terminate", JSON.stringify({ workerID: failedWorkerID }), null)
                ).catch(() => {});
            }
            this._state = "terminated";
            this._pendingOutgoing = [];
            this._pendingIncoming = [];
            this._dispatch("error", makeErrorEvent(this, error));
        });
    }

    Worker.prototype.addEventListener = function(type, handler) {
        if (type !== "message" && type !== "error" && type !== "messageerror") {
            return;
        }
        if (typeof handler !== "function") {
            throw new TypeError("Event listener must be a function");
        }
        this._listeners[type].add(handler);
    };

    Worker.prototype.removeEventListener = function(type, handler) {
        if (type !== "message" && type !== "error" && type !== "messageerror") {
            return;
        }
        if (typeof handler !== "function") {
            return;
        }
        this._listeners[type].delete(handler);
    };

    Worker.prototype._dispatch = function(type, event) {
        const propertyName = type === "message" ? "onmessage" : (type === "error" ? "onerror" : "onmessageerror");
        const propertyHandler = this[propertyName];
        if (typeof propertyHandler === "function") {
            try {
                propertyHandler.call(this, event);
            } catch (error) {
                globalThis.__EJSWorkerLastError = error;
            }
        }
        const listeners = Array.from(this._listeners[type]);
        for (let i = 0; i < listeners.length; i++) {
            try {
                listeners[i].call(this, event);
            } catch (error) {
                globalThis.__EJSWorkerLastError = error;
            }
        }
    };

    Worker.prototype._enqueueOutgoing = function(message) {
        if (this._state === "terminated" || this._state === "terminating") {
            return;
        }
        if (this._queuedOutgoingCount >= this._maxQueuedMessages) {
            throw new Error("Worker outgoing queue exceeds maxQueuedMessages");
        }
        this._queuedOutgoingCount += 1;
        this._sendChain = this._sendChain.then(() => {
            if (this._state === "terminated" || this._state === "terminating") {
                return;
            }
            return Promise.resolve(
                nativeInvoke()(moduleID, "postMessage", JSON.stringify({
                    workerID: this._workerID,
                    direction: "toChild",
                    envelope: message.envelope
                }), message.sidecar)
            ).catch((error) => {
                this._dispatch("error", makeErrorEvent(this, error));
            });
        }).finally(() => {
            this._queuedOutgoingCount -= 1;
        });
    };

    Worker.prototype.postMessage = function(value, transferList) {
        if (this._state === "terminated" || this._state === "terminating") {
            throw new Error("Worker has already been terminated");
        }

        let encoded;
        try {
            encoded = serializeForMessage(value, transferList);
        } catch (error) {
            const event = makeEvent(this, "messageerror", {
                error,
                message: String(error && error.message ? error.message : error)
            });
            this._dispatch("messageerror", event);
            throw error;
        }

        if (this._state === "starting" && this._pendingOutgoing.length >= this._maxQueuedMessages) {
            throw new Error("Worker startup queue exceeds maxQueuedMessages");
        }
        if (this._state === "running" && this._queuedOutgoingCount >= this._maxQueuedMessages) {
            throw new Error("Worker outgoing queue exceeds maxQueuedMessages");
        }

        for (let i = 0; i < encoded.detachers.length; i++) {
            detachTransferredBuffer(encoded.detachers[i]);
        }

        if (this._state === "starting") {
            this._pendingOutgoing.push(encoded);
            return;
        }

        this._enqueueOutgoing(encoded);
    };

    Worker.prototype._onDispatch = function(messageID) {
        if (this._workerID.length === 0 ||
            this._state === "terminated" ||
            this._state === "terminating") {
            return;
        }
        if (this._state === "starting") {
            this._pendingIncoming.push(String(messageID));
            return;
        }
        Promise.resolve(
            nativeInvoke()(moduleID, "takeMessage", JSON.stringify({
                workerID: this._workerID,
                direction: "toParent",
                messageID: String(messageID)
            }), null)
        ).then((raw) => {
            const decoded = decodeFrame(raw);
            if (decoded.envelope.kind === "close") {
                workerTable.delete(this._workerID);
                this._pendingOutgoing = [];
                this._pendingIncoming = [];
                this._state = "terminated";
                return;
            }
            if (decoded.envelope.kind === "error") {
                const errorData = decoded.envelope.error || {};
                const event = makeEvent(this, "error", {
                    message: String(errorData.message || "Worker error"),
                    filename: String(errorData.filename || ""),
                    stack: String(errorData.stack || ""),
                    error: errorData.error || new Error(String(errorData.message || "Worker error"))
                });
                this._dispatch("error", event);
                return;
            }

            try {
                const data = deserializeFromMessage(decoded.envelope, decoded.sidecar);
                this._dispatch("message", makeEvent(this, "message", { data }));
            } catch (error) {
                this._dispatch("messageerror", makeEvent(this, "messageerror", {
                    error,
                    message: String(error && error.message ? error.message : error)
                }));
            }
        }).catch((error) => {
            this._dispatch("error", makeErrorEvent(this, error));
        });
    };

    Worker.prototype._terminateNow = function() {
        if (this._state === "terminated") {
            return Promise.resolve();
        }
        this._state = "terminating";

        if (this._workerID.length === 0) {
            this._state = "terminated";
            return Promise.resolve();
        }

        return Promise.resolve(
            nativeInvoke()(moduleID, "terminate", JSON.stringify({ workerID: this._workerID }), null)
        ).catch((error) => {
            this._dispatch("error", makeErrorEvent(this, error));
        }).finally(() => {
            workerTable.delete(this._workerID);
            this._pendingOutgoing = [];
            this._pendingIncoming = [];
            this._state = "terminated";
        });
    };

    Worker.prototype.terminate = function() {
        if (this._state === "terminated") {
            return;
        }
        if (this._state === "terminating") {
            return;
        }
        this._state = "terminating";

        if (this._workerID.length > 0) {
            this._terminatedPromise = this._terminateNow();
            return;
        }

        this._terminatedPromise = Promise.resolve(this._createPromise);
    };

    globalThis.__EJSWorkerDispatch = function(workerID, messageID) {
        const worker = workerTable.get(String(workerID));
        if (!worker) {
            return;
        }
        worker._onDispatch(String(messageID));
    };

    globalThis.Worker = Worker;
    globalThis.EJSWorker = Object.freeze({
        moduleID: "ejs.worker",
        version: 1
    });

    globalThis.__EJSWorkerInternalFrameEncode = encodeFrame;
    globalThis.__EJSWorkerInternalActiveCount = function() {
        return workerTable.size;
    };
})();
