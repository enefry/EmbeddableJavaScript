(function() {
    if (!globalThis.EJSKV) {
        throw new Error("EJSStorage requires EJSKV to be installed first.");
    }

    function requireKV() {
        if (!globalThis.EJSKV) {
            throw new Error("EJSStorage requires EJSKV.");
        }
        return globalThis.EJSKV;
    }

    function keyName(key) {
        return String(key);
    }

    function localOptions(options) {
        return options && typeof options === "object" ? options : undefined;
    }

    async function length(options) {
        return (await requireKV().keys(localOptions(options))).length;
    }

    async function key(index, options) {
        const keys = await requireKV().keys(localOptions(options));
        const n = Number(index);
        if (!Number.isFinite(n) || n < 0) {
            return null;
        }
        return keys[Math.floor(n)] || null;
    }

    async function getItem(key, options) {
        const data = await requireKV().get(keyName(key), localOptions(options));
        if (data == null) {
            return null;
        }
        return decodeUtf8(data);
    }

    async function setItem(key, value, options) {
        await requireKV().set(keyName(key), String(value), localOptions(options));
        return undefined;
    }

    async function removeItem(key, options) {
        await requireKV().delete(keyName(key), localOptions(options));
        return undefined;
    }

    async function clear(options) {
        await requireKV().clear(localOptions(options));
        return undefined;
    }

    async function getJSON(key, options) {
        return requireKV().getJSON(keyName(key), localOptions(options));
    }

    async function setJSON(key, value, options) {
        await requireKV().setJSON(keyName(key), value, localOptions(options));
        return undefined;
    }

    async function removeJSON(key, options) {
        await requireKV().delete(keyName(key), localOptions(options));
        return undefined;
    }

    function decodeUtf8(input) {
        if (typeof TextDecoder !== "undefined") {
            return new TextDecoder().decode(input);
        }
        const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        let output = "";
        for (let i = 0; i < bytes.length;) {
            const first = bytes[i++];
            if (first <= 0x7f) {
                output += String.fromCharCode(first);
            } else if (first >= 0xc2 && first <= 0xdf && i < bytes.length) {
                const second = bytes[i++];
                output += String.fromCharCode(((first & 0x1f) << 6) | (second & 0x3f));
            } else if (first >= 0xe0 && first <= 0xef && i + 1 < bytes.length) {
                const second = bytes[i++];
                const third = bytes[i++];
                output += String.fromCharCode(((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f));
            } else if (first >= 0xf0 && first <= 0xf4 && i + 2 < bytes.length) {
                const second = bytes[i++];
                const third = bytes[i++];
                const fourth = bytes[i++];
                let codePoint = ((first & 0x07) << 18) | ((second & 0x3f) << 12) | ((third & 0x3f) << 6) | (fourth & 0x3f);
                codePoint -= 0x10000;
                output += String.fromCharCode(0xd800 + (codePoint >> 10));
                output += String.fromCharCode(0xdc00 + (codePoint & 0x3ff));
            } else {
                output += "\ufffd";
            }
        }
        return output;
    }

    globalThis.EJSStorage = {
        local: {
            length,
            key,
            getItem,
            setItem,
            removeItem,
            clear
        },
        json: {
            get: getJSON,
            set: setJSON,
            remove: removeJSON
        }
    };
})();
