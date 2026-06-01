(function() {
    const base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const base64Lookup = Object.create(null);
    for (let i = 0; i < base64Alphabet.length; i++) {
        base64Lookup[base64Alphabet[i]] = i;
    }
    const hexAlphabet = "0123456789abcdef";

    function normalizeEncoding(encoding) {
        if (encoding == null) {
            return "utf8";
        }
        const normalized = String(encoding).toLowerCase();
        if (normalized === "utf8" || normalized === "utf-8") {
            return "utf8";
        }
        if (normalized === "base64" || normalized === "hex") {
            return normalized;
        }
        throw new TypeError("encoding must be utf8, base64, or hex");
    }

    function bytesView(bytes) {
        if (bytes instanceof ArrayBuffer) {
            return new Uint8Array(bytes);
        }
        if (ArrayBuffer.isView(bytes)) {
            return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        }
        throw new TypeError("bytes must be an ArrayBuffer or ArrayBufferView");
    }

    function encodeUtf8(value) {
        const text = String(value);
        if (typeof globalThis.TextEncoder === "function") {
            return new globalThis.TextEncoder().encode(text);
        }
        const bytes = [];

        for (let i = 0; i < text.length; i++) {
            let codePoint = text.charCodeAt(i);
            if (codePoint >= 0xd800 && codePoint <= 0xdbff) {
                if (i + 1 < text.length) {
                    const trail = text.charCodeAt(i + 1);
                    if (trail >= 0xdc00 && trail <= 0xdfff) {
                        codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (trail - 0xdc00);
                        i++;
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

    function decodeUtf8(bytesInput) {
        const bytes = bytesView(bytesInput);
        if (typeof globalThis.TextDecoder === "function") {
            return new globalThis.TextDecoder().decode(bytes);
        }

        const chunks = [];
        let chunk = [];

        function isContinuation(byte) {
            return byte >= 0x80 && byte <= 0xbf;
        }

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
                pushCodeUnit(0xd800 + (value >> 10));
                pushCodeUnit(0xdc00 + (value & 0x3ff));
            }
        }

        for (let i = 0; i < bytes.length;) {
            const first = bytes[i++];
            let codePoint = first;

            if (first <= 0x7f) {
                codePoint = first;
            } else if (first >= 0xc2 && first <= 0xdf && i < bytes.length && isContinuation(bytes[i])) {
                codePoint = ((first & 0x1f) << 6) | (bytes[i++] & 0x3f);
            } else if (first >= 0xe0 && first <= 0xef &&
                       i + 1 < bytes.length &&
                       isContinuation(bytes[i]) &&
                       isContinuation(bytes[i + 1]) &&
                       (first !== 0xe0 || bytes[i] >= 0xa0) &&
                       (first !== 0xed || bytes[i] <= 0x9f)) {
                const second = bytes[i++];
                const third = bytes[i++];
                codePoint = ((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f);
            } else if (first >= 0xf0 && first <= 0xf4 &&
                       i + 2 < bytes.length &&
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
                if (first >= 0xe0 && first <= 0xef && i + 1 >= bytes.length) {
                    while (i < bytes.length && isContinuation(bytes[i])) {
                        i++;
                    }
                } else if (first >= 0xf0 && first <= 0xf4 && i + 2 >= bytes.length) {
                    while (i < bytes.length && isContinuation(bytes[i])) {
                        i++;
                    }
                }
                codePoint = 0xfffd;
            }

            pushCodePoint(codePoint);
        }

        if (chunk.length > 0) {
            chunks.push(String.fromCharCode.apply(null, chunk));
        }
        return chunks.join("");
    }

    function hexNibble(code) {
        if (code >= 48 && code <= 57) return code - 48;
        if (code >= 65 && code <= 70) return code - 55;
        if (code >= 97 && code <= 102) return code - 87;
        return -1;
    }

    function fromHex(value) {
        const text = String(value).replace(/\s+/g, "");
        if (text.length % 2 !== 0) {
            throw new TypeError("hex input must have an even length");
        }

        const bytes = new Uint8Array(text.length / 2);
        for (let i = 0; i < text.length; i += 2) {
            const high = hexNibble(text.charCodeAt(i));
            const low = hexNibble(text.charCodeAt(i + 1));
            if (high < 0 || low < 0) {
                throw new TypeError("hex input contains invalid characters");
            }
            bytes[i / 2] = (high << 4) | low;
        }
        return bytes;
    }

    function toHex(bytesInput) {
        const bytes = bytesView(bytesInput);
        const output = new Array(bytes.length);
        for (let i = 0; i < bytes.length; i++) {
            const byte = bytes[i];
            output[i] = hexAlphabet[byte >> 4] + hexAlphabet[byte & 0x0f];
        }
        return output.join("");
    }

    function fromBase64(value) {
        let text = String(value).replace(/\s+/g, "");
        if (text.length === 0) {
            return new Uint8Array(0);
        }
        const remainder = text.length % 4;
        if (remainder === 1) {
            throw new TypeError("base64 input length is invalid");
        }
        if (remainder === 2) {
            text += "==";
        } else if (remainder === 3) {
            text += "=";
        }

        let padding = 0;
        if (text.endsWith("==")) {
            padding = 2;
        } else if (text.endsWith("=")) {
            padding = 1;
        }

        const output = new Uint8Array((text.length / 4) * 3 - padding);
        let offset = 0;
        for (let i = 0; i < text.length; i += 4) {
            const c1 = text[i];
            const c2 = text[i + 1];
            const c3 = text[i + 2];
            const c4 = text[i + 3];
            if (base64Lookup[c1] == null || base64Lookup[c2] == null ||
                (c3 !== "=" && base64Lookup[c3] == null) ||
                (c4 !== "=" && base64Lookup[c4] == null)) {
                throw new TypeError("base64 input contains invalid characters");
            }
            if ((c3 === "=" && c4 !== "=") || (i + 4 < text.length && (c3 === "=" || c4 === "="))) {
                throw new TypeError("base64 padding is invalid");
            }

            const triple = (base64Lookup[c1] << 18) |
                (base64Lookup[c2] << 12) |
                ((c3 === "=" ? 0 : base64Lookup[c3]) << 6) |
                (c4 === "=" ? 0 : base64Lookup[c4]);
            if (offset < output.length) output[offset++] = (triple >> 16) & 0xff;
            if (offset < output.length) output[offset++] = (triple >> 8) & 0xff;
            if (offset < output.length) output[offset++] = triple & 0xff;
        }
        return output;
    }

    function toBase64(bytesInput) {
        const bytes = bytesView(bytesInput);
        const output = [];
        let offset = 0;
        for (let i = 0; i < bytes.length; i += 3) {
            const a = bytes[i];
            const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
            const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
            const triple = (a << 16) | (b << 8) | c;
            output[offset++] = base64Alphabet[(triple >> 18) & 0x3f];
            output[offset++] = base64Alphabet[(triple >> 12) & 0x3f];
            output[offset++] = i + 1 < bytes.length ? base64Alphabet[(triple >> 6) & 0x3f] : "=";
            output[offset++] = i + 2 < bytes.length ? base64Alphabet[triple & 0x3f] : "=";
        }
        return output.join("");
    }

    function fromString(value, encoding) {
        switch (normalizeEncoding(encoding)) {
        case "utf8":
            return encodeUtf8(value);
        case "base64":
            return fromBase64(value);
        case "hex":
            return fromHex(value);
        default:
            throw new TypeError("unsupported encoding");
        }
    }

    function toString(bytes, encoding) {
        switch (normalizeEncoding(encoding)) {
        case "utf8":
            return decodeUtf8(bytes);
        case "base64":
            return toBase64(bytes);
        case "hex":
            return toHex(bytes);
        default:
            throw new TypeError("unsupported encoding");
        }
    }

    function concat(chunks) {
        if (!Array.isArray(chunks)) {
            throw new TypeError("chunks must be an array");
        }

        let length = 0;
        const views = chunks.map(function(chunk) {
            const view = bytesView(chunk);
            length += view.byteLength;
            return view;
        });

        const output = new Uint8Array(length);
        let offset = 0;
        for (let i = 0; i < views.length; i++) {
            output.set(views[i], offset);
            offset += views[i].byteLength;
        }
        return output;
    }

    function compare(a, b) {
        const left = bytesView(a);
        const right = bytesView(b);
        const length = Math.min(left.byteLength, right.byteLength);
        for (let i = 0; i < length; i++) {
            if (left[i] !== right[i]) {
                return left[i] < right[i] ? -1 : 1;
            }
        }
        if (left.byteLength === right.byteLength) {
            return 0;
        }
        return left.byteLength < right.byteLength ? -1 : 1;
    }

    function equals(a, b) {
        return compare(a, b) === 0;
    }

    Object.defineProperty(globalThis, "EJSBinary", {
        configurable: true,
        writable: true,
        value: Object.freeze({
            fromString: fromString,
            toString: toString,
            fromBase64: fromBase64,
            toBase64: toBase64,
            fromHex: fromHex,
            toHex: toHex,
            concat: concat,
            equals: equals,
            compare: compare
        })
    });
})();
