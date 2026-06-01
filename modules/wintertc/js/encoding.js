(function() {
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
        let bytes;
        if (input === undefined) {
            bytes = new Uint8Array(0);
        } else if (input instanceof ArrayBuffer) {
            bytes = new Uint8Array(input);
        } else if (ArrayBuffer.isView(input)) {
            bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        } else {
            throw new TypeError("TextDecoder.decode input must be an ArrayBuffer or ArrayBufferView");
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

    if (typeof globalThis.TextEncoder !== "function") {
        globalThis.TextEncoder = class TextEncoder {
            get encoding() {
                return "utf-8";
            }

            encode(input = "") {
                return encodeUtf8(input);
            }
        };
    }

    if (typeof globalThis.TextDecoder !== "function") {
        globalThis.TextDecoder = class TextDecoder {
            constructor(label = "utf-8") {
                const normalized = String(label).trim().toLowerCase();
                if (normalized !== "utf-8" && normalized !== "utf8") {
                    throw new RangeError("Only utf-8 TextDecoder is supported");
                }
                this.encoding = "utf-8";
                this.fatal = false;
                this.ignoreBOM = false;
            }

            decode(input = new Uint8Array(0)) {
                return decodeUtf8(input);
            }
        };
    }
})();
