(function() {
    const moduleID = "ejs.xhr";
    const readyStateValues = Object.freeze({
        UNSENT: 0,
        OPENED: 1,
        HEADERS_RECEIVED: 2,
        LOADING: 3,
        DONE: 4
    });
    const eventNames = Object.freeze([
        "readystatechange",
        "loadstart",
        "progress",
        "load",
        "error",
        "abort",
        "timeout",
        "loadend"
    ]);
    const nativeCodeMap = Object.freeze({
        1: "EINVAL",
        2: "ECANCELLED",
        3: "ENETWORK",
        4: "ETLS",
        5: "ETIMEOUT",
        6: "ENOTSUP",
        7: "EPERM",
        8: "EINTERNAL"
    });
    let nextRequestID = 1;
    const supportedResponseTypes = Object.freeze(["", "text", "arraybuffer", "json"]);
    const base64DecodeLookup = Object.create(null);
    const base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (let i = 0; i < base64Alphabet.length; i += 1) {
        base64DecodeLookup[base64Alphabet[i]] = i;
    }

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function decodeUtf8(input) {
        const bytes = input instanceof ArrayBuffer
            ? new Uint8Array(input)
            : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        if (typeof globalThis.TextDecoder === "function") {
            return new globalThis.TextDecoder("utf-8").decode(bytes);
        }

        const chunks = [];
        let chunk = [];

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
                pushCodeUnit(0xd800 | (value >> 10));
                pushCodeUnit(0xdc00 | (value & 0x3ff));
            }
        }

        for (let i = 0; i < bytes.length;) {
            const first = bytes[i++];
            if (first < 0x80) {
                pushCodeUnit(first);
                continue;
            }
            if (first >= 0xc2 && first < 0xe0 && i < bytes.length) {
                const second = bytes[i++];
                pushCodeUnit(((first & 0x1f) << 6) | (second & 0x3f));
                continue;
            }
            if (first >= 0xe0 && first < 0xf0 && i + 1 < bytes.length) {
                const second = bytes[i++];
                const third = bytes[i++];
                pushCodeUnit(((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f));
                continue;
            }
            if (first >= 0xf0 && first < 0xf5 && i + 2 < bytes.length) {
                const second = bytes[i++];
                const third = bytes[i++];
                const fourth = bytes[i++];
                let codePoint = ((first & 0x07) << 18) | ((second & 0x3f) << 12) | ((third & 0x3f) << 6) | (fourth & 0x3f);
                pushCodePoint(codePoint);
                continue;
            }
            pushCodeUnit(0xfffd);
        }
        if (chunk.length > 0) {
            chunks.push(String.fromCharCode.apply(null, chunk));
        }
        return chunks.join("");
    }

    function isHTTPToken(value) {
        return /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(value);
    }

    function normalizeMethod(method) {
        const value = String(method == null ? "" : method).trim();
        if (value.length === 0 || !isHTTPToken(value)) {
            throw new TypeError("xhr method must be a valid HTTP token");
        }
        return value.toUpperCase();
    }

    function normalizeURL(url) {
        const value = String(url == null ? "" : url).trim();
        if (value.length === 0) {
            throw new TypeError("xhr url must be a non-empty string");
        }
        return value;
    }

    function normalizeHeaderName(name) {
        const value = String(name == null ? "" : name).trim();
        if (value.length === 0 || !isHTTPToken(value)) {
            throw new TypeError("xhr header name is invalid");
        }
        return value;
    }

    function normalizeHeaderValue(value) {
        const text = String(value == null ? "" : value);
        if (/[\r\n]/.test(text)) {
            throw new TypeError("xhr header value is invalid");
        }
        return text;
    }

    function normalizeBody(body) {
        if (body == null) {
            return { bodyText: null, transfer: null };
        }
        if (typeof body === "string") {
            return { bodyText: body, transfer: null };
        }
        if (body instanceof ArrayBuffer) {
            return { bodyText: null, transfer: new Uint8Array(body) };
        }
        if (ArrayBuffer.isView(body)) {
            return {
                bodyText: null,
                transfer: new Uint8Array(body.buffer, body.byteOffset, body.byteLength)
            };
        }
        throw new TypeError("xhr body must be null, string, ArrayBuffer, or ArrayBufferView");
    }

    function providerCodeToString(error) {
        const numeric = error && Number.isInteger(error.code) ? error.code : 8;
        return nativeCodeMap[numeric] || "EINTERNAL";
    }

    function makeXHRError(error, operation) {
        const message = (error && typeof error.message === "string" && error.message.length > 0)
            ? error.message
            : operation + " failed";
        const shaped = new Error(message);
        shaped.name = "EJSXHRError";
        shaped.code = providerCodeToString(error);
        shaped.module = "xhr";
        shaped.operation = operation;
        if (error && typeof error.platform_domain === "string") shaped.nativeDomain = error.platform_domain;
        if (error && Number.isInteger(error.platform_code)) shaped.nativeCode = error.platform_code;
        return shaped;
    }

    function createEvent(type, target) {
        return Object.freeze({
            type: type,
            target: target,
            currentTarget: target
        });
    }

    function createProgressEvent(type, target, loaded, total, lengthComputable) {
        return Object.freeze({
            type: type,
            target: target,
            currentTarget: target,
            loaded: loaded,
            total: total,
            lengthComputable: lengthComputable
        });
    }

    function abortRequestID(requestID, suppressErrors) {
        try {
            const promise = nativeInvoke()(moduleID, "abort", JSON.stringify({ requestID: requestID }), null);
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

    const xhrRegistry = typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(requestID => {
        abortRequestID(requestID, true);
    }) : null;

    function decodeBase64(base64Text) {
        const normalized = String(base64Text == null ? "" : base64Text).replace(/\s+/g, "");
        if (normalized.length === 0) {
            return new Uint8Array(0);
        }
        if (normalized.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(normalized)) {
            throw new TypeError("xhr response bodyBase64 is invalid");
        }

        if (typeof Uint8Array.fromBase64 === "function") {
            try {
                return Uint8Array.fromBase64(normalized);
            } catch (_) {
                throw new TypeError("xhr response bodyBase64 is invalid");
            }
        }

        if (typeof globalThis.atob === "function") {
            let binary = "";
            try {
                binary = globalThis.atob(normalized);
            } catch (_) {
                throw new TypeError("xhr response bodyBase64 is invalid");
            }
            const output = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i += 1) {
                output[i] = binary.charCodeAt(i);
            }
            return output;
        }

        let outputLength = (normalized.length / 4) * 3;
        if (normalized.endsWith("==")) {
            outputLength -= 2;
        } else if (normalized.endsWith("=")) {
            outputLength -= 1;
        }
        const output = new Uint8Array(outputLength);

        let offset = 0;
        for (let i = 0; i < normalized.length; i += 4) {
            const c0 = normalized[i];
            const c1 = normalized[i + 1];
            const c2 = normalized[i + 2];
            const c3 = normalized[i + 3];

            const n0 = base64DecodeLookup[c0];
            const n1 = base64DecodeLookup[c1];
            const n2 = c2 === "=" ? 0 : base64DecodeLookup[c2];
            const n3 = c3 === "=" ? 0 : base64DecodeLookup[c3];
            if (n0 == null || n1 == null || (c2 !== "=" && n2 == null) || (c3 !== "=" && n3 == null)) {
                throw new TypeError("xhr response bodyBase64 is invalid");
            }

            const value = (n0 << 18) | (n1 << 12) | (n2 << 6) | n3;
            output[offset++] = (value >> 16) & 0xff;
            if (c2 !== "=") {
                output[offset++] = (value >> 8) & 0xff;
            }
            if (c3 !== "=") {
                output[offset++] = value & 0xff;
            }
        }
        return output;
    }

    class XMLHttpRequestImpl {
        constructor() {
            this.readyState = readyStateValues.UNSENT;
            this.status = 0;
            this.statusText = "";
            this.responseURL = "";
            this.responseText = "";
            this.response = "";
            this.timeout = 0;

            this._method = "";
            this._url = "";
            this._responseType = "";
            this._requestHeaders = Object.create(null);
            this._responseHeaders = Object.create(null);
            this._listeners = Object.create(null);
            this._sendInProgress = false;
            this._activeRequestID = null;
            this._lastError = null;

            this.onreadystatechange = null;
            this.onload = null;
            this.onerror = null;
            this.onabort = null;
            this.ontimeout = null;
            this.onloadend = null;
            this.onloadstart = null;
            this.onprogress = null;
        }

        get responseType() {
            return this._responseType;
        }

        set responseType(value) {
            const normalized = String(value == null ? "" : value);
            if (!supportedResponseTypes.includes(normalized)) {
                throw new TypeError("xhr responseType supports only \"\", \"text\", \"arraybuffer\", and \"json\"");
            }
            this._responseType = normalized;
        }

        open(method, url, async) {
            if (async === false) {
                throw new TypeError("xhr open only supports async requests");
            }
            this._cancelActiveRequest();
            this._method = normalizeMethod(method);
            this._url = normalizeURL(url);
            this._requestHeaders = Object.create(null);
            this._responseHeaders = Object.create(null);
            this._sendInProgress = false;
            this._activeRequestID = null;
            this._lastError = null;
            this._resetResponseFields();
            this._setReadyState(readyStateValues.OPENED);
        }

        setRequestHeader(name, value) {
            if (this.readyState !== readyStateValues.OPENED || this._sendInProgress) {
                throw new Error("xhr setRequestHeader requires OPENED state before send");
            }
            const normalizedName = normalizeHeaderName(name);
            const normalizedValue = normalizeHeaderValue(value);
            const key = normalizedName.toLowerCase();
            const existing = this._requestHeaders[key];
            this._requestHeaders[key] = {
                name: normalizedName,
                value: existing ? (existing.value + ", " + normalizedValue) : normalizedValue
            };
        }

        getResponseHeader(name) {
            const normalized = String(name == null ? "" : name).trim().toLowerCase();
            if (normalized.length === 0 || this.readyState < readyStateValues.HEADERS_RECEIVED) {
                return null;
            }
            const entry = this._responseHeaders[normalized];
            return entry ? entry.value : null;
        }

        getAllResponseHeaders() {
            if (this.readyState < readyStateValues.HEADERS_RECEIVED) {
                return "";
            }
            const lines = [];
            for (const key of Object.keys(this._responseHeaders)) {
                const entry = this._responseHeaders[key];
                lines.push(entry.name + ": " + entry.value);
            }
            return lines.length > 0 ? lines.join("\r\n") + "\r\n" : "";
        }

        addEventListener(type, listener) {
            if (!eventNames.includes(type) || typeof listener !== "function") {
                return;
            }
            const bucket = this._listeners[type] || (this._listeners[type] = new Set());
            bucket.add(listener);
        }

        removeEventListener(type, listener) {
            const bucket = this._listeners[type];
            if (!bucket || typeof listener !== "function") {
                return;
            }
            bucket.delete(listener);
        }

        abort() {
            if (this.readyState === readyStateValues.UNSENT && !this._sendInProgress) {
                return;
            }
            const hadActiveRequest = this._sendInProgress || this._activeRequestID != null;
            if (this.readyState === readyStateValues.DONE && !hadActiveRequest) {
                this._resetResponseFields();
                this._setReadyState(readyStateValues.UNSENT);
                return;
            }
            this._cancelActiveRequest();
            this._resetResponseFields();
            this._setReadyState(readyStateValues.UNSENT);
            if (hadActiveRequest) {
                this._dispatchEvent("abort");
                this._dispatchEvent("loadend");
            }
        }

        send(body) {
            if (this.readyState !== readyStateValues.OPENED || this._sendInProgress) {
                throw new Error("xhr send requires OPENED state and no active request");
            }
            const normalized = normalizeBody(body);
            const requestID = String(nextRequestID++);
            this._sendInProgress = true;
            this._activeRequestID = requestID;
            this._lastError = null;
            if (xhrRegistry) {
                xhrRegistry.register(this, requestID, this);
            }

            const payload = {
                requestID: requestID,
                method: this._method,
                url: this._url,
                responseType: this._responseType,
                timeoutMs: Number.isFinite(this.timeout) && this.timeout > 0 ? Math.floor(this.timeout) : 0,
                headers: Object.keys(this._requestHeaders).map((key) => ({
                    name: this._requestHeaders[key].name,
                    value: this._requestHeaders[key].value
                }))
            };
            if (normalized.bodyText != null) {
                payload.bodyText = normalized.bodyText;
            }
            this._dispatchEvent("loadstart");

            nativeInvoke()(moduleID, "send", JSON.stringify(payload), normalized.transfer || null)
                .then((raw) => {
                    if (this._activeRequestID !== requestID) {
                        return;
                    }
                    let response;
                    try {
                        response = JSON.parse(decodeUtf8(raw));
                    } catch (error) {
                        this._sendInProgress = false;
                        this._activeRequestID = null;
                        if (xhrRegistry) {
                            xhrRegistry.unregister(this);
                        }
                        const shaped = makeXHRError(error, "send");
                        this._lastError = shaped;
                        this._resetResponseFields();
                        this._setReadyState(readyStateValues.DONE);
                        this._dispatchEvent("error");
                        this._dispatchEvent("loadend");
                        return;
                    }
                    this._sendInProgress = false;
                    this._activeRequestID = null;
                    if (xhrRegistry) {
                        xhrRegistry.unregister(this);
                    }
                    this._applyResponseMetadata(response);
                    this._setReadyState(readyStateValues.HEADERS_RECEIVED);
                    this._setReadyState(readyStateValues.LOADING);
                    this._dispatchEvent("progress", this._progressEventData(response));
                    try {
                        this._finalizeResponsePayload(response);
                    } catch (error) {
                        const shaped = makeXHRError(error, "send");
                        this._lastError = shaped;
                        this._resetResponseFields();
                        this._setReadyState(readyStateValues.DONE);
                        this._dispatchEvent("error");
                        this._dispatchEvent("loadend");
                        return;
                    }
                    this._setReadyState(readyStateValues.DONE);
                    this._dispatchEvent("load");
                    this._dispatchEvent("loadend");
                })
                .catch((error) => {
                    if (this._activeRequestID !== requestID) {
                        return;
                    }
                    this._sendInProgress = false;
                    this._activeRequestID = null;
                    if (xhrRegistry) {
                        xhrRegistry.unregister(this);
                    }
                    const shaped = makeXHRError(error, "send");
                    this._lastError = shaped;
                    this._resetResponseFields();
                    this._setReadyState(readyStateValues.DONE);
                    if (shaped.code === "ECANCELLED") {
                        this._dispatchEvent("abort");
                    } else if (shaped.code === "ETIMEOUT") {
                        this._dispatchEvent("timeout");
                    } else {
                        this._dispatchEvent("error");
                    }
                    this._dispatchEvent("loadend");
                });
        }

        _resetResponseFields() {
            this.status = 0;
            this.statusText = "";
            this.responseURL = "";
            this.responseText = "";
            this.response = "";
            this._responseHeaders = Object.create(null);
        }

        _cancelActiveRequest() {
            const requestID = this._activeRequestID;
            this._activeRequestID = null;
            this._sendInProgress = false;
            if (xhrRegistry) {
                xhrRegistry.unregister(this);
            }
            if (requestID == null) {
                return;
            }
            abortRequestID(requestID, true);
        }

        _setReadyState(next) {
            if (this.readyState === next) {
                return;
            }
            this.readyState = next;
            this._dispatchEvent("readystatechange");
        }

        _dispatchEvent(type, progressData) {
            const event = progressData == null
                ? createEvent(type, this)
                : createProgressEvent(type, this, progressData.loaded, progressData.total, progressData.lengthComputable);
            const handler = this["on" + type];
            if (typeof handler === "function") {
                try {
                    handler.call(this, event);
                } catch (_) {}
            }
            const listeners = this._listeners[type];
            if (!listeners || listeners.size === 0) {
                return;
            }
            for (const listener of Array.from(listeners)) {
                try {
                    listener.call(this, event);
                } catch (_) {}
            }
        }

        _progressEventData(response) {
            const loadedValue = response && Number(response.loaded);
            const totalValue = response && Number(response.total);
            const hasLoaded = Number.isFinite(loadedValue) && loadedValue >= 0;
            const hasTotal = Number.isFinite(totalValue) && totalValue >= 0;
            const loaded = hasLoaded ? Math.floor(loadedValue) : 0;
            const total = hasTotal ? Math.floor(totalValue) : 0;
            const lengthComputable = response && response.lengthComputable === true && hasTotal;
            return {
                loaded: loaded,
                total: lengthComputable ? total : 0,
                lengthComputable: lengthComputable
            };
        }

        _applyResponseMetadata(response) {
            const status = response && Number(response.status);
            this.status = Number.isInteger(status) && status >= 0 ? status : 0;
            this.statusText = response && typeof response.statusText === "string" ? response.statusText : "";
            this.responseURL = response && typeof response.responseURL === "string" ? response.responseURL : "";
            const bodyText = response && typeof response.bodyText === "string" ? response.bodyText : "";
            this.responseText = this._responseType === "arraybuffer" ? "" : bodyText;

            const headers = response && Array.isArray(response.headers) ? response.headers : [];
            const normalized = Object.create(null);
            for (const entry of headers) {
                if (!entry || typeof entry.name !== "string" || typeof entry.value !== "string") {
                    continue;
                }
                const key = entry.name.trim().toLowerCase();
                if (key.length === 0) {
                    continue;
                }
                if (normalized[key]) {
                    normalized[key].value += ", " + entry.value;
                } else {
                    normalized[key] = { name: entry.name.trim(), value: entry.value };
                }
            }
            this._responseHeaders = normalized;
        }

        _finalizeResponsePayload(response) {
            const bodyText = response && typeof response.bodyText === "string" ? response.bodyText : "";
            if (this._responseType === "" || this._responseType === "text") {
                this.response = bodyText;
            } else if (this._responseType === "json") {
                this.response = JSON.parse(bodyText);
            } else if (this._responseType === "arraybuffer") {
                const bodyBase64 = response && typeof response.bodyBase64 === "string" ? response.bodyBase64 : "";
                const bytes = decodeBase64(bodyBase64);
                this.response = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            } else {
                this.response = null;
            }
        }
    }

    class XMLHttpRequest extends XMLHttpRequestImpl {}

    Object.defineProperties(XMLHttpRequest, {
        UNSENT: { value: readyStateValues.UNSENT, enumerable: true },
        OPENED: { value: readyStateValues.OPENED, enumerable: true },
        HEADERS_RECEIVED: { value: readyStateValues.HEADERS_RECEIVED, enumerable: true },
        LOADING: { value: readyStateValues.LOADING, enumerable: true },
        DONE: { value: readyStateValues.DONE, enumerable: true }
    });

    Object.defineProperties(XMLHttpRequest.prototype, {
        UNSENT: { value: readyStateValues.UNSENT, enumerable: true },
        OPENED: { value: readyStateValues.OPENED, enumerable: true },
        HEADERS_RECEIVED: { value: readyStateValues.HEADERS_RECEIVED, enumerable: true },
        LOADING: { value: readyStateValues.LOADING, enumerable: true },
        DONE: { value: readyStateValues.DONE, enumerable: true }
    });

    function EJSXHRError(message) {
        const error = new Error(message || "xhr error");
        error.name = "EJSXHRError";
        return error;
    }

    Object.defineProperty(globalThis, "XMLHttpRequest", {
        configurable: true,
        enumerable: false,
        writable: true,
        value: XMLHttpRequest
    });
    Object.defineProperty(globalThis, "EJSXHRError", {
        configurable: true,
        enumerable: false,
        writable: true,
        value: EJSXHRError
    });
    Object.defineProperty(globalThis, "EJSXHR", {
        configurable: true,
        enumerable: false,
        writable: true,
        value: Object.freeze({
            installed: true,
            moduleID: moduleID,
            supportedResponseTypes: supportedResponseTypes,
            events: Object.freeze(eventNames.slice())
        })
    });
})();
