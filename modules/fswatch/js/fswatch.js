(function() {
    const moduleID = "ejs.fswatch";
    const handlers = new Map();

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function decodeUtf8(input) {
        if (typeof TextDecoder !== "undefined") {
            return new TextDecoder().decode(input);
        }
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

    function normalizePath(path) {
        if (typeof path !== "string" || path.length === 0) {
            throw new TypeError("watch path must be a non-empty string");
        }
        return path;
    }

    function requestFromOptions(path, options) {
        const request = { path: normalizePath(path) };
        if (options && typeof options === "object") {
            if (options.root != null) request.root = String(options.root);
            if (options.recursive != null) {
                if (typeof options.recursive !== "boolean") {
                    throw new TypeError("watch options.recursive must be a boolean");
                }
                request.recursive = options.recursive;
            }
        }
        return request;
    }

    function closeWatcherID(watcherID, suppressErrors) {
        try {
            const promise = nativeInvoke()(moduleID, "close", JSON.stringify({ watcherID }), null);
            if (suppressErrors && promise && typeof promise.catch === "function") {
                promise.catch(() => {});
            }
            return promise;
        } catch (error) {
            if (suppressErrors) {
                return Promise.resolve();
            }
            return Promise.reject(error);
        }
    }

    const fswatchRegistry = typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(watcherID => {
        handlers.delete(watcherID);
        closeWatcherID(watcherID, true);
    }) : null;

    globalThis.__EJSFSWatchDispatch = function(id, eventType, path) {
        const handler = handlers.get(String(id));
        if (typeof handler !== "function") {
            return;
        }
        try {
            handler(String(eventType), String(path));
        } catch (error) {
            globalThis.__EJSFSWatchLastError = error;
        }
    };

    async function watch(path, handler, options) {
        if (typeof handler !== "function") {
            throw new TypeError("watch handler must be a function");
        }
        const result = await nativeInvoke()(moduleID, "watch", JSON.stringify(requestFromOptions(path, options)), null);
        const response = JSON.parse(decodeUtf8(result));
        const id = String(response.watcherID);
        handlers.set(id, handler);
        let closed = false;
        let closePromise = null;
        const watcher = {
            id,
            recursive: Boolean(response.recursive),
            close: async function() {
                if (closed) return closePromise || Promise.resolve();
                closed = true;
                if (fswatchRegistry) {
                    fswatchRegistry.unregister(watcher);
                }
                handlers.delete(id);
                closePromise = closeWatcherID(id, false);
                await closePromise;
                return undefined;
            }
        };
        if (fswatchRegistry) {
            fswatchRegistry.register(watcher, id, watcher);
        }
        return watcher;
    }

    globalThis.EJSFSWatch = {
        watch
    };
})();
