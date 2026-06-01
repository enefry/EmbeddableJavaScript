(function() {
    const moduleID = "ejs.system";

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function decodeUtf8(input) {
        const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
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
                codePoint = 0xfffd;
            }
            pushCodePoint(codePoint);
        }
        if (chunk.length > 0) {
            chunks.push(String.fromCharCode.apply(null, chunk));
        }
        return chunks.join("");
    }

    function normalizeName(name) {
        if (typeof name !== "string" || name.length === 0 || name.indexOf("=") >= 0) {
            throw new TypeError("environment variable name must be a non-empty string without '='");
        }
        return name;
    }

    function normalizePath(path) {
        if (typeof path !== "string" || path.length === 0) {
            throw new TypeError("system path must be a non-empty string");
        }
        return path;
    }

    async function request(method, payload) {
        const result = await nativeInvoke()(moduleID, method, JSON.stringify(payload || {}), null);
        return JSON.parse(decodeUtf8(result));
    }

    async function cwd() {
        return (await request("cwd")).cwd;
    }

    async function chdir(path) {
        await request("chdir", { path: normalizePath(path) });
        return undefined;
    }

    async function env() {
        return (await request("env")).env;
    }

    async function getenv(name) {
        return (await request("getenv", { name: normalizeName(name) })).value;
    }

    async function setenv(name, value) {
        await request("setenv", { name: normalizeName(name), value: String(value) });
        return undefined;
    }

    async function unsetenv(name) {
        await request("unsetenv", { name: normalizeName(name) });
        return undefined;
    }

    function scalar(method, key) {
        return async function() {
            return (await request(method))[key || method];
        };
    }

    globalThis.EJSSystem = {
        cwd,
        chdir,
        env,
        getenv,
        setenv,
        unsetenv,
        pid: scalar("pid"),
        ppid: scalar("ppid"),
        homeDir: scalar("homeDir"),
        tmpDir: scalar("tmpDir"),
        exePath: scalar("exePath"),
        hostName: scalar("hostName"),
        platform: scalar("platform"),
        arch: scalar("arch"),
        uname: scalar("uname"),
        uptime: scalar("uptime"),
        loadAvg: scalar("loadAvg"),
        availableParallelism: scalar("availableParallelism"),
        cpuInfo: scalar("cpuInfo"),
        networkInterfaces: scalar("networkInterfaces"),
        userInfo: scalar("userInfo")
    };
})();
