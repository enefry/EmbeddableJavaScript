(function() {
    const moduleID = "ejs.hashing";

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function encodeUtf8(input) {
        const text = String(input);
        if (typeof globalThis.TextEncoder === "function") {
            return new globalThis.TextEncoder().encode(text);
        }
        const bytes = [];
        for (let i = 0; i < text.length; i++) {
            let codePoint = text.charCodeAt(i);
            if (codePoint >= 0xd800 && codePoint <= 0xdbff) {
                const trail = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
                if (trail >= 0xdc00 && trail <= 0xdfff) {
                    codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (trail - 0xdc00);
                    i += 1;
                } else {
                    codePoint = 0xfffd;
                }
            }
            if (codePoint <= 0x7f) {
                bytes.push(codePoint);
            } else if (codePoint <= 0x7ff) {
                bytes.push(0xc0 | (codePoint >> 6), 0x80 | (codePoint & 0x3f));
            } else if (codePoint <= 0xffff) {
                bytes.push(0xe0 | (codePoint >> 12), 0x80 | ((codePoint >> 6) & 0x3f), 0x80 | (codePoint & 0x3f));
            } else {
                bytes.push(0xf0 | (codePoint >> 18), 0x80 | ((codePoint >> 12) & 0x3f), 0x80 | ((codePoint >> 6) & 0x3f), 0x80 | (codePoint & 0x3f));
            }
        }
        return new Uint8Array(bytes);
    }

    function decodeUtf8(input) {
        const bytes = new Uint8Array(input);
        if (typeof globalThis.TextDecoder === "function") {
            return new globalThis.TextDecoder().decode(bytes);
        }
        const chunks = [];
        for (let i = 0; i < bytes.length; i += 4096) {
            chunks.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 4096)));
        }
        return chunks.join("");
    }

    function bytesFromData(data) {
        if (typeof data === "string") return encodeUtf8(data);
        if (data instanceof ArrayBuffer) return data;
        if (ArrayBuffer.isView(data)) return data;
        throw new TypeError("hash data must be a string, ArrayBuffer, or ArrayBufferView");
    }

    async function digest(algorithm, data, options) {
        const encoding = options && typeof options === "object" && options.encoding != null
            ? String(options.encoding).toLowerCase()
            : "hex";
        if (encoding !== "hex" && encoding !== "base64") {
            throw new TypeError("hash encoding must be hex or base64");
        }
        const request = { algorithm: String(algorithm).toLowerCase(), encoding };
        const result = await nativeInvoke()(moduleID, "digest", JSON.stringify(request), bytesFromData(data));
        return JSON.parse(decodeUtf8(result)).digest;
    }

    globalThis.EJSHashing = {
        digest,
        sha256(data, options) {
            return digest("sha256", data, options);
        },
        sha512(data, options) {
            return digest("sha512", data, options);
        }
    };
})();
