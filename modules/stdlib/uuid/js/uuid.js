(function() {
    const moduleID = "ejs.uuid";
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
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

    function validate(value) {
        return typeof value === "string" && uuidPattern.test(value);
    }

    async function v4() {
        const result = await nativeInvoke()(moduleID, "v4", "{}", null);
        return JSON.parse(decodeUtf8(result)).uuid;
    }

    globalThis.EJSUUID = {
        v4,
        randomUUID: v4,
        validate
    };
})();
