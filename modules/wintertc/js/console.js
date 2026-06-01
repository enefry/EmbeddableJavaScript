(function() {
    const nativeInvoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
    const levels = ["debug", "info", "log", "warn", "error"];

    function stringify(value) {
        if (typeof value === "string") {
            return value;
        }
        if (value instanceof Error) {
            return value.stack || value.message || String(value);
        }
        try {
            const json = JSON.stringify(value);
            return json === undefined ? String(value) : json;
        } catch (error) {
            return String(value);
        }
    }

    function write(level, args) {
        if (typeof nativeInvoke !== "function") {
            return;
        }

        const payload = JSON.stringify({
            level,
            args: Array.prototype.map.call(args, stringify),
            timestampMs: Date.now(),
            contextId: ""
        });

        nativeInvoke("wintertc.console", "write", payload, null).catch(function() {});
    }

    const consoleObject = {};
    for (const level of levels) {
        consoleObject[level] = function() {
            write(level, arguments);
        };
    }

    globalThis.console = consoleObject;
})();
