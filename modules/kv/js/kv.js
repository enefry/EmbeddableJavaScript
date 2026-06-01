(function() {
    const moduleID = "ejs.kv";

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function normalizeKey(key) {
        if (typeof key !== "string") {
            throw new TypeError("kv key must be a string");
        }
        if (key.length === 0) {
            throw new TypeError("kv key must not be empty");
        }
        return key;
    }

    function requestFromOptions(key, options) {
        const request = {};
        if (key != null) {
            request.key = normalizeKey(key);
        }
        if (options && typeof options === "object") {
            if (options.store != null) {
                if (typeof options.store !== "string" || options.store.length === 0) {
                    throw new TypeError("kv store must be a non-empty string");
                }
                request.store = options.store;
            }
        }
        return request;
    }

    function encodeUtf8(input) {
        const text = String(input);
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
        const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
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

    function bytesFromValue(value) {
        if (typeof value === "string") {
            return encodeUtf8(value);
        }
        if (value instanceof ArrayBuffer) {
            return value;
        }
        if (ArrayBuffer.isView(value)) {
            return value;
        }
        throw new TypeError("kv value must be a string, ArrayBuffer, or ArrayBufferView");
    }

    function jsonFromBuffer(buffer) {
        if (buffer == null) {
            return null;
        }
        return JSON.parse(decodeUtf8(buffer));
    }

    async function get(key, options) {
        const result = await nativeInvoke()(moduleID, "get", JSON.stringify(requestFromOptions(key, options)), null);
        return result == null ? null : result;
    }

    async function set(key, value, options) {
        await nativeInvoke()(moduleID, "set", JSON.stringify(requestFromOptions(key, options)), bytesFromValue(value));
        return undefined;
    }

    async function deleteKey(key, options) {
        const result = await nativeInvoke()(moduleID, "delete", JSON.stringify(requestFromOptions(key, options)), null);
        return Boolean(jsonFromBuffer(result).deleted);
    }

    async function has(key, options) {
        const result = await nativeInvoke()(moduleID, "has", JSON.stringify(requestFromOptions(key, options)), null);
        return Boolean(jsonFromBuffer(result).exists);
    }

    async function keys(options) {
        const result = await nativeInvoke()(moduleID, "keys", JSON.stringify(requestFromOptions(null, options)), null);
        const response = jsonFromBuffer(result);
        return Array.isArray(response.keys) ? response.keys : [];
    }

    async function clear(options) {
        await nativeInvoke()(moduleID, "clear", JSON.stringify(requestFromOptions(null, options)), null);
        return undefined;
    }

    async function getJSON(key, options) {
        return jsonFromBuffer(await get(key, options));
    }

    async function setJSON(key, value, options) {
        await set(key, JSON.stringify(value), options);
        return undefined;
    }

    globalThis.EJSKV = {
        get,
        set,
        delete: deleteKey,
        has,
        keys,
        clear,
        getJSON,
        setJSON
    };
})();
