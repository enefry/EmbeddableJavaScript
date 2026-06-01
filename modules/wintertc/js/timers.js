(function() {
    function getNativeTimersOrThrow() {
        const timers = globalThis.__ejs_native__ && globalThis.__ejs_native__.timers;
        if (!timers || typeof timers.create !== "function" || typeof timers.destroy !== "function") {
            throw new Error("EJS native timers are not available.");
        }
        return timers;
    }

    function normalizeDelay(delay) {
        const value = Number(delay);
        if (!Number.isFinite(value) || value < 0) {
            return 0;
        }
        return value;
    }

    globalThis.setTimeout = function(callback, delay, ...args) {
        if (typeof callback !== 'function') {
            throw new TypeError('Callback must be a function');
        }
        const delayMs = normalizeDelay(delay);
        
        const timers = getNativeTimersOrThrow();
        return timers.create(delayMs, 0, function() {
            callback(...args);
        });
    };

    globalThis.clearTimeout = function(id) {
        if (id !== undefined && id !== null) {
            const timers = globalThis.__ejs_native__ && globalThis.__ejs_native__.timers;
            if (timers && typeof timers.destroy === "function") {
                timers.destroy(id);
            }
        }
    };

    globalThis.setInterval = function(callback, delay, ...args) {
        if (typeof callback !== 'function') {
            throw new TypeError('Callback must be a function');
        }
        const delayMs = normalizeDelay(delay);
        const repeatMs = delayMs > 0 ? delayMs : 1;
        
        const timers = getNativeTimersOrThrow();
        return timers.create(delayMs, repeatMs, function() {
            callback(...args);
        });
    };

    globalThis.clearInterval = function(id) {
        if (id !== undefined && id !== null) {
            const timers = globalThis.__ejs_native__ && globalThis.__ejs_native__.timers;
            if (timers && typeof timers.destroy === "function") {
                timers.destroy(id);
            }
        }
    };

    globalThis.queueMicrotask = function(callback) {
        if (typeof callback !== 'function') {
            throw new TypeError('Callback must be a function');
        }
        Promise.resolve().then(callback);
    };
})();
