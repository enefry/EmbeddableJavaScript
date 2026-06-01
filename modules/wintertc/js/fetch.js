(function() {
    function makeAbortError() {
        const error = new Error("The operation was aborted.");
        error.name = "AbortError";
        return error;
    }

    function normalizeAbortError(reason) {
        if (reason && typeof reason === "object" && reason.name === "AbortError") {
            return reason;
        }
        const error = makeAbortError();
        if (reason !== undefined) {
            error.cause = reason;
        }
        return error;
    }

    function assertNotAborted(signal) {
        if (signal && signal.aborted) {
            throw normalizeAbortError(signal.reason);
        }
    }

    function normalizeHeaderName(name) {
        const key = String(name).toLowerCase();
        if (key.length === 0 || /[^!#$%&'*+\-.^_`|~0-9a-z]/.test(key)) {
            throw new TypeError("Invalid header name");
        }
        return key;
    }

    function normalizeHeaderValue(value) {
        const stringValue = String(value);
        if (stringValue.indexOf("\r") !== -1 || stringValue.indexOf("\n") !== -1) {
            throw new TypeError("Invalid header value");
        }
        return stringValue.replace(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/g, "");
    }

    function normalizeRedirectMode(value) {
        const redirect = value == null ? "follow" : String(value);
        if (redirect !== "follow" && redirect !== "error" && redirect !== "manual") {
            throw new TypeError("Invalid redirect mode");
        }
        return redirect;
    }

    function copyArrayBuffer(buffer) {
        if (buffer == null) {
            return null;
        }
        return buffer.slice(0);
    }

    function viewToArrayBuffer(view) {
        return view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength);
    }

    function bytesToStream(buffer) {
        return new ReadableStream({
            start(controller) {
                if (buffer && buffer.byteLength > 0) {
                    controller.enqueue(new Uint8Array(buffer.slice(0)));
                }
                controller.close();
            }
        });
    }

    async function awaitReaderReadWithAbort(reader, signal) {
        if (!signal || typeof signal.addEventListener !== "function") {
            return reader.read();
        }
        assertNotAborted(signal);
        let settled = false;
        let detach = null;
        const readPromise = reader.read();
        readPromise.catch(function() {
            // The read may settle after an abort race winner.
        });
        const abortPromise = new Promise((resolve, reject) => {
            const onAbort = () => {
                if (settled) {
                    return;
                }
                settled = true;
                reject(normalizeAbortError(signal.reason));
            };
            signal.addEventListener("abort", onAbort, { once: true });
            detach = () => {
                if (typeof signal.removeEventListener === "function") {
                    signal.removeEventListener("abort", onAbort);
                }
            };
        });
        try {
            const result = await Promise.race([readPromise, abortPromise]);
            settled = true;
            return result;
        } finally {
            if (detach != null) {
                detach();
            }
        }
    }

    async function streamToArrayBuffer(stream, signal) {
        const reader = stream.getReader();
        const chunks = [];
        let totalLength = 0;

        try {
            while (true) {
                const result = await awaitReaderReadWithAbort(reader, signal);
                if (result.done) {
                    break;
                }

                let chunk = result.value;
                if (chunk instanceof ArrayBuffer) {
                    chunk = new Uint8Array(chunk);
                } else if (ArrayBuffer.isView(chunk)) {
                    chunk = new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
                } else {
                    chunk = new TextEncoder().encode(String(chunk));
                }

                chunks.push(chunk);
                totalLength += chunk.byteLength;
            }
        } catch (error) {
            if (signal && signal.aborted) {
                try {
                    if (typeof reader.releaseLock === "function") {
                        reader.releaseLock();
                    }
                } catch (releaseError) {
                    // Best-effort lock release for custom stream implementations.
                }
                try {
                    if (typeof stream.cancel === "function") {
                        await stream.cancel(normalizeAbortError(signal.reason));
                    }
                } catch (cancelError) {
                    // Best-effort cancellation; original abort reason should be surfaced.
                }
            }
            throw error;
        } finally {
            if (typeof reader.releaseLock === "function") {
                try {
                    reader.releaseLock();
                } catch (releaseError) {
                    // Ignore lock-release failures for already-closed readers.
                }
            }
        }

        const consolidated = new Uint8Array(totalLength);
        let offset = 0;
        for (const chunk of chunks) {
            consolidated.set(chunk, offset);
            offset += chunk.byteLength;
        }
        return consolidated.buffer;
    }

    async function bodyToArrayBuffer(body, signal) {
        if (body === undefined || body === null) {
            return null;
        }
        if (typeof body === "string") {
            return new TextEncoder().encode(body).buffer;
        }
        if (body instanceof ArrayBuffer) {
            return body.slice(0);
        }
        if (ArrayBuffer.isView(body)) {
            return viewToArrayBuffer(body);
        }
        if (typeof Blob === "function" && body instanceof Blob) {
            return await body.arrayBuffer();
        }
        if (typeof URLSearchParams === "function" && body instanceof URLSearchParams) {
            return new TextEncoder().encode(body.toString()).buffer;
        }
        if (typeof ReadableStream === "function" && body instanceof ReadableStream) {
            return await streamToArrayBuffer(body, signal);
        }
        return new TextEncoder().encode(String(body)).buffer;
    }

    function bodyFromBuffer(buffer) {
        if (buffer == null) {
            return null;
        }
        return bytesToStream(buffer);
    }

    let nextFetchSignalID = 1;

    async function consumeBody(owner) {
        if (owner.bodyUsed) {
            throw new TypeError("Body already consumed");
        }
        owner.bodyUsed = true;

        if (owner._bodyBuffer != null) {
            return copyArrayBuffer(owner._bodyBuffer);
        }
        if (owner.body == null) {
            return new ArrayBuffer(0);
        }

        const buffer = await streamToArrayBuffer(owner.body);
        owner._bodyBuffer = copyArrayBuffer(buffer);
        return buffer;
    }

    class Headers {
        constructor(init = undefined) {
            this._map = new Map();

            if (init === undefined || init === null) {
                return;
            }

            if (init instanceof Headers) {
                for (const [key, value] of init) {
                    this.append(key, value);
                }
                return;
            }

            if (typeof init[Symbol.iterator] === "function") {
                for (const pair of init) {
                    if (!pair || pair.length < 2) {
                        throw new TypeError("Header pair must contain name and value");
                    }
                    this.append(pair[0], pair[1]);
                }
                return;
            }

            if (typeof init === "object") {
                for (const key of Object.keys(init)) {
                    this.append(key, init[key]);
                }
                return;
            }

            throw new TypeError("Unsupported Headers initializer");
        }

        append(name, value) {
            const key = normalizeHeaderName(name);
            const val = normalizeHeaderValue(value);
            const existing = this._map.get(key);
            this._map.set(key, existing === undefined ? val : existing + ", " + val);
        }

        delete(name) {
            this._map.delete(normalizeHeaderName(name));
        }

        get(name) {
            const value = this._map.get(normalizeHeaderName(name));
            return value === undefined ? null : value;
        }

        has(name) {
            return this._map.has(normalizeHeaderName(name));
        }

        set(name, value) {
            this._map.set(normalizeHeaderName(name), normalizeHeaderValue(value));
        }

        forEach(callback, thisArg) {
            for (const [key, val] of this._map) {
                callback.call(thisArg, val, key, this);
            }
        }

        *entries() {
            yield* this._map.entries();
        }

        *keys() {
            for (const [key] of this._map) {
                yield key;
            }
        }

        *values() {
            for (const [, value] of this._map) {
                yield value;
            }
        }

        *[Symbol.iterator]() {
            yield* this.entries();
        }
    }

    class Request {
        constructor(input, init = {}) {
            let source = null;
            if (input instanceof Request) {
                source = input;
                this.url = source.url;
            } else if (input instanceof URL) {
                this.url = input.href;
            } else {
                this.url = String(input);
            }

            this.method = String(init.method || (source ? source.method : "GET")).toUpperCase();
            this.headers = new Headers(source ? source.headers : undefined);
            if (init.headers !== undefined) {
                this.headers = new Headers(init.headers);
            }

            const sourceRedirect = source ? source.redirect : "follow";
            this.redirect = normalizeRedirectMode(init.redirect !== undefined ? init.redirect : sourceRedirect);
            this.credentials = init.credentials || (source ? source.credentials : "omit");
            this.cache = init.cache || (source ? source.cache : "default");
            this.referrer = init.referrer || (source ? source.referrer : "");
            this.integrity = init.integrity || (source ? source.integrity : "");
            this.keepalive = !!(init.keepalive !== undefined ? init.keepalive : (source && source.keepalive));
            this.signal = init.signal || (source ? source.signal : null);
            this.bodyUsed = false;

            let body = init.body;
            let hasBody = Object.prototype.hasOwnProperty.call(init, "body");
            if (!hasBody && source != null) {
                if (source.bodyUsed) {
                    throw new TypeError("Cannot construct Request from a consumed body");
                }
                if (source._bodyBuffer != null) {
                    body = copyArrayBuffer(source._bodyBuffer);
                    hasBody = body != null;
                } else if (source._bodySource !== undefined) {
                    if (typeof ReadableStream === "function" &&
                        source._bodySource instanceof ReadableStream) {
                        throw new TypeError("Cannot construct Request from a streaming body");
                    }
                    body = source._bodySource;
                    hasBody = true;
                }
            }

            if ((this.method === "GET" || this.method === "HEAD") && hasBody && body != null) {
                throw new TypeError("Request with GET/HEAD method cannot have body");
            }

            this._bodyBuffer = null;
            this._bodySource = undefined;
            this.body = null;
            if (hasBody && body != null) {
                if (body instanceof ArrayBuffer) {
                    this._bodyBuffer = body.slice(0);
                    this.body = bodyFromBuffer(this._bodyBuffer);
                } else if (ArrayBuffer.isView(body)) {
                    this._bodyBuffer = viewToArrayBuffer(body);
                    this.body = bodyFromBuffer(this._bodyBuffer);
                } else if (typeof body === "string") {
                    this._bodyBuffer = new TextEncoder().encode(body).buffer;
                    this.body = bodyFromBuffer(this._bodyBuffer);
                } else if (typeof URLSearchParams === "function" && body instanceof URLSearchParams) {
                    this._bodyBuffer = new TextEncoder().encode(body.toString()).buffer;
                    this.body = bodyFromBuffer(this._bodyBuffer);
                } else {
                    this._bodySource = body;
                    if (typeof ReadableStream === "function" && body instanceof ReadableStream) {
                        this.body = body;
                    }
                }
            }
        }

        async _transferBody(signal) {
            if (this.bodyUsed) {
                throw new TypeError("Body already consumed");
            }
            if (this._bodyBuffer != null) {
                this.bodyUsed = true;
                return copyArrayBuffer(this._bodyBuffer);
            }
            if (this._bodySource !== undefined) {
                const buffer = await bodyToArrayBuffer(this._bodySource, signal);
                this._bodyBuffer = copyArrayBuffer(buffer);
                this.bodyUsed = true;
                return buffer;
            }
            if (this.body != null) {
                return consumeBody(this);
            }
            return null;
        }

        async arrayBuffer() {
            if (this._bodySource !== undefined && this._bodyBuffer == null) {
                const buffer = await this._transferBody();
                return buffer || new ArrayBuffer(0);
            }
            return consumeBody(this);
        }

        async text() {
            return new TextDecoder().decode(await this.arrayBuffer());
        }

        async json() {
            return JSON.parse(await this.text());
        }

        async blob() {
            return new Blob([await this.arrayBuffer()]);
        }

        clone() {
            if (this.bodyUsed) {
                throw new TypeError("Body already consumed");
            }
            return new Request(this);
        }
    }

    class Response {
        constructor(body = null, options = {}) {
            this.status = options.status === undefined ? 200 : Number(options.status);
            this.statusText = options.statusText === undefined ? "" : String(options.statusText);
            this.ok = this.status >= 200 && this.status < 300;
            this.headers = new Headers(options.headers);
            this.url = options.url === undefined ? "" : String(options.url);
            this.redirected = !!options.redirected;
            this.type = options.type || "default";
            this.bodyUsed = false;
            this._bodyBuffer = null;
            this._bodySource = undefined;
            this.body = null;

            if (body != null) {
                if (body instanceof ArrayBuffer) {
                    this._bodyBuffer = body.slice(0);
                    this.body = bodyFromBuffer(this._bodyBuffer);
                } else if (ArrayBuffer.isView(body)) {
                    this._bodyBuffer = viewToArrayBuffer(body);
                    this.body = bodyFromBuffer(this._bodyBuffer);
                } else if (typeof Blob === "function" && body instanceof Blob) {
                    this._bodySource = body;
                    this.body = body.stream ? body.stream() : null;
                } else if (typeof ReadableStream === "function" && body instanceof ReadableStream) {
                    this.body = body;
                } else {
                    this._bodyBuffer = new TextEncoder().encode(String(body)).buffer;
                    this.body = bodyFromBuffer(this._bodyBuffer);
                    if (!this.headers.has("content-type")) {
                        this.headers.set("content-type", "text/plain;charset=UTF-8");
                    }
                }
            }
        }

        async arrayBuffer() {
            return consumeBody(this);
        }

        async text() {
            return new TextDecoder().decode(await this.arrayBuffer());
        }

        async json() {
            return JSON.parse(await this.text());
        }

        async blob() {
            return new Blob([await this.arrayBuffer()], {
                type: this.headers.get("content-type") || ""
            });
        }

        clone() {
            if (this.bodyUsed) {
                throw new TypeError("Body already consumed");
            }
            const cloneOptions = {
                status: this.status,
                statusText: this.statusText,
                headers: this.headers,
                url: this.url,
                redirected: this.redirected,
                type: this.type
            };
            if (this._bodyBuffer != null) {
                return new Response(copyArrayBuffer(this._bodyBuffer), cloneOptions);
            }
            if (this._bodySource !== undefined) {
                if (typeof ReadableStream === "function" && this._bodySource instanceof ReadableStream) {
                    throw new TypeError("Cannot clone a streaming body");
                }
                return new Response(this._bodySource, cloneOptions);
            }
            if (this.body != null) {
                throw new TypeError("Cannot clone a streaming body");
            }
            return new Response(null, cloneOptions);
        }

        static json(data, init = {}) {
            const headers = new Headers(init.headers);
            if (!headers.has("content-type")) {
                headers.set("content-type", "application/json");
            }
            return new Response(JSON.stringify(data), {
                status: init.status,
                statusText: init.statusText,
                headers
            });
        }

        static redirect(url, status = 302) {
            if ([301, 302, 303, 307, 308].indexOf(status) < 0) {
                throw new RangeError("Invalid redirect status");
            }
            return new Response(null, {
                status,
                headers: {
                    location: String(url)
                }
            });
        }

        static error() {
            return new Response(null, {
                status: 0,
                statusText: "",
                type: "error"
            });
        }
    }

    async function fetch(resource, options = {}) {
        const nativeInvoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof nativeInvoke !== "function") {
            throw new Error("EJS native core dispatcher is not available.");
        }

        const request = new Request(resource, options);
        if (request.redirect !== "follow") {
            throw new TypeError("Only redirect mode 'follow' is supported");
        }
        assertNotAborted(request.signal);
        const signalID = request.signal ? "fetch-signal-" + nextFetchSignalID++ : null;
        let detachAbort = null;
        let activeBodyStreamId = "";
        let keepAbortListenerForBody = false;
        function detachAbortListener() {
            if (detachAbort != null) {
                detachAbort();
                detachAbort = null;
            }
            activeBodyStreamId = "";
        }
        if (request.signal && typeof request.signal.addEventListener === "function") {
            const onAbort = () => {
                nativeInvoke("wintertc.fetch", "cancel", JSON.stringify({
                    bodyStreamId: activeBodyStreamId,
                    signalId: signalID,
                    reason: String(request.signal.reason || "abort")
                })).catch(function() {
                    // Abort cancellation best-effort.
                });
            };
            request.signal.addEventListener("abort", onAbort, { once: true });
            detachAbort = () => {
                if (typeof request.signal.removeEventListener === "function") {
                    request.signal.removeEventListener("abort", onAbort);
                }
            };
        }

        try {
            const headerPairs = [];
            request.headers.forEach((val, key) => {
                headerPairs.push([key, val]);
            });

            const bodyPayload = await request._transferBody(request.signal);
            assertNotAborted(request.signal);

            let startResultBuffer;
            try {
                startResultBuffer = await nativeInvoke("wintertc.fetch", "start", JSON.stringify({
                    url: request.url,
                    method: request.method,
                    headers: headerPairs,
                    bodyKind: bodyPayload == null ? "none" : "bytes",
                    redirect: request.redirect,
                    credentials: request.credentials,
                    cache: request.cache,
                    referrer: request.referrer,
                    integrity: request.integrity,
                    keepalive: request.keepalive,
                    signalId: signalID,
                    userAgent: "EJS"
                }), bodyPayload);
            } catch (error) {
                if (request.signal && request.signal.aborted) {
                    throw normalizeAbortError(request.signal.reason);
                }
                throw error;
            }

            assertNotAborted(request.signal);

            const startResultStr = new TextDecoder().decode(startResultBuffer);
            const startResult = JSON.parse(startResultStr);
            const streamId = startResult.bodyStreamId || startResult.streamId || "";
            activeBodyStreamId = streamId;

            const bodyStream = streamId ? new ReadableStream({
                async pull(controller) {
                    try {
                        const chunkBuffer = await nativeInvoke("wintertc.fetch", "pull", JSON.stringify({
                            bodyStreamId: streamId,
                            maxBytes: 65536
                        }));
                        if (!chunkBuffer || chunkBuffer.byteLength === 0) {
                            detachAbortListener();
                            controller.error(new Error("Empty wintertc.fetch pull frame"));
                            return;
                        }

                        const frame = new Uint8Array(chunkBuffer);
                        if (frame[0] === 0x00) {
                            detachAbortListener();
                            controller.close();
                        } else if (frame[0] === 0x01) {
                            controller.enqueue(frame.slice(1));
                        } else {
                            detachAbortListener();
                            controller.error(new Error("Invalid wintertc.fetch pull frame"));
                        }
                    } catch (err) {
                        if (request.signal && request.signal.aborted) {
                            controller.error(normalizeAbortError(request.signal.reason));
                            detachAbortListener();
                            return;
                        }
                        detachAbortListener();
                        controller.error(err);
                    }
                },
                async cancel(reason) {
                    try {
                        await nativeInvoke("wintertc.fetch", "cancel", JSON.stringify({
                            bodyStreamId: streamId,
                            signalId: signalID,
                            reason: String(reason)
                        }));
                    } catch (e) {
                        // Cancellation is best-effort from JS.
                    } finally {
                        detachAbortListener();
                    }
                }
            }) : null;
            keepAbortListenerForBody = bodyStream != null;

            const response = new Response(bodyStream, {
                status: startResult.status,
                statusText: startResult.statusText || "",
                headers: startResult.headers || [],
                url: startResult.url || request.url,
                redirected: !!startResult.redirected
            });
            return response;
        } finally {
            if (!keepAbortListenerForBody && detachAbort != null) {
                detachAbortListener();
            }
        }
    }

    globalThis.Headers = Headers;
    globalThis.Request = Request;
    globalThis.Response = Response;
    globalThis.fetch = fetch;
})();
