(function() {
    function bytesToString(value) {
        if (typeof value === "string") {
            return value;
        }
        if (!(value instanceof ArrayBuffer)) {
            throw new Error("wintertc.clock.now returned a non-buffer result.");
        }

        const bytes = new Uint8Array(value);
        let output = "";
        for (let i = 0; i < bytes.length; i++) {
            output += String.fromCharCode(bytes[i]);
        }
        return output;
    }

    let cachedTimeOrigin = undefined;

    function readClock() {
        const nativeInvokeSync = globalThis.__ejs_native__ && globalThis.__ejs_native__.invokeSync;
        if (typeof nativeInvokeSync !== "function") {
            throw new Error("EJS native sync dispatcher is not available.");
        }

        const raw = nativeInvokeSync("wintertc.clock", "now", "{}", null);
        const record = JSON.parse(bytesToString(raw));
        const timeOriginEpochMs = Number(record.timeOriginEpochMs);
        const nowMs = Number(record.nowMs);

        if (!Number.isFinite(timeOriginEpochMs) || !Number.isFinite(nowMs)) {
            throw new Error("wintertc.clock.now returned invalid clock values.");
        }

        if (cachedTimeOrigin === undefined) {
            cachedTimeOrigin = timeOriginEpochMs;
        }

        return {
            timeOriginEpochMs,
            nowMs
        };
    }

    const performance = {};

    Object.defineProperty(performance, "timeOrigin", {
        configurable: true,
        enumerable: true,
        get() {
            if (cachedTimeOrigin === undefined) {
                readClock();
            }
            return cachedTimeOrigin;
        }
    });

    performance.now = function() {
        return readClock().nowMs;
    };

    globalThis.performance = performance;
})();
