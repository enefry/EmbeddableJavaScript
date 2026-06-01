(function() {
    const moduleID = "ejs.sqlite";
    let nextConnectionID = 1;
    let nextTransactionID = 1;

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

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
        if (input == null) {
            return "";
        }
        const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        let output = "";
        function cont(byte) {
            return byte >= 0x80 && byte <= 0xbf;
        }
        for (let i = 0; i < bytes.length;) {
            const first = bytes[i++];
            let codePoint = first;
            if (first <= 0x7f) {
                codePoint = first;
            } else if (first >= 0xc2 && first <= 0xdf && i < bytes.length && cont(bytes[i])) {
                const second = bytes[i++];
                codePoint = ((first & 0x1f) << 6) | (second & 0x3f);
            } else if (first >= 0xe0 && first <= 0xef && i + 1 < bytes.length && cont(bytes[i]) && cont(bytes[i + 1])) {
                const second = bytes[i++];
                const third = bytes[i++];
                codePoint = ((first & 0x0f) << 12) | ((second & 0x3f) << 6) | (third & 0x3f);
            } else if (first >= 0xf0 && first <= 0xf4 && i + 2 < bytes.length && cont(bytes[i]) && cont(bytes[i + 1]) && cont(bytes[i + 2])) {
                const second = bytes[i++];
                const third = bytes[i++];
                const fourth = bytes[i++];
                codePoint = ((first & 0x07) << 18) | ((second & 0x3f) << 12) | ((third & 0x3f) << 6) | (fourth & 0x3f);
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

    function jsonFromBuffer(buffer) {
        if (buffer == null) {
            return null;
        }
        return JSON.parse(decodeUtf8(buffer));
    }

    function decodeResultValue(value) {
        if (value == null || typeof value !== "object" || Array.isArray(value)) {
            return value;
        }
        if (value.type === "int64" && typeof value.value === "string") {
            if (typeof BigInt === "function") {
                try {
                    return BigInt(value.value);
                } catch (error) {
                    // Keep exact string form when BigInt parsing is unavailable.
                }
            }
            return value.value;
        }
        return value;
    }

    function decodeResultRows(rows) {
        return rows.map((row) => {
            if (row == null || typeof row !== "object" || Array.isArray(row)) {
                return row;
            }
            const decoded = {};
            for (const key of Object.keys(row)) {
                decoded[key] = decodeResultValue(row[key]);
            }
            return decoded;
        });
    }

    function invoke(method, request) {
        return nativeInvoke()(moduleID, method, JSON.stringify(request), null);
    }

    function normalizeSQL(sql) {
        if (typeof sql !== "string" || sql.length === 0) {
            throw new TypeError("sqlite sql must be a non-empty string");
        }
        return sql;
    }

    function normalizeParams(params) {
        if (params == null) {
            return [];
        }
        if (!Array.isArray(params)) {
            throw new TypeError("sqlite params must be an array");
        }
        return params.map((value) => {
            if (value === null) {
                return { type: "null" };
            }
            if (typeof value === "boolean") {
                return { type: "boolean", value };
            }
            if (typeof value === "number") {
                if (!Number.isFinite(value)) {
                    throw new TypeError("sqlite number params must be finite");
                }
                return { type: "number", value };
            }
            if (typeof value === "string") {
                return { type: "string", value };
            }
            throw new TypeError("sqlite params currently support null, boolean, number, and string");
        });
    }

    function normalizeName(name) {
        if (typeof name !== "string" || name.length === 0) {
            throw new TypeError("sqlite database name must be a non-empty string");
        }
        return name;
    }

    function closedError() {
        return new Error("sqlite database is closed");
    }

    class SQLiteTransaction {
        constructor(database, transactionID) {
            this._database = database;
            this._transactionID = transactionID;
        }

        _request(sql, params) {
            return this._database._request(sql, params, this._transactionID);
        }

        async execute(sql, params) {
            await invoke("execute", this._request(sql, params));
            return undefined;
        }

        async query(sql, params) {
            const result = await invoke("query", this._request(sql, params));
            const response = jsonFromBuffer(result);
            const rows = response && Array.isArray(response.rows) ? response.rows : [];
            return decodeResultRows(rows);
        }
    }

    function closeConnection(connectionID, suppressErrors) {
        try {
            const promise = nativeInvoke()(moduleID, "close", JSON.stringify({ connection: connectionID }), null);
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

    const dbRegistry = typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(connectionID => {
        closeConnection(connectionID, true);
    }) : null;

    class SQLiteDatabase {
        constructor(id) {
            this._id = id;
            this._closed = false;
            this._activeTx = null;
            if (dbRegistry) {
                dbRegistry.register(this, this._id, this);
            }
        }

        _request(sql, params, transactionID) {
            if (this._closed) {
                throw closedError();
            }
            const request = {
                connection: this._id,
                sql: normalizeSQL(sql),
                params: normalizeParams(params)
            };
            if (transactionID != null) {
                request.transaction = transactionID;
            }
            return request;
        }

        _baseRequest(sql, params) {
            if (this._activeTx != null) {
                throw new Error("sqlite transaction is active; use the transaction client");
            }
            return this._request(sql, params, null);
        }

        async execute(sql, params) {
            await invoke("execute", this._baseRequest(sql, params));
            return undefined;
        }

        async query(sql, params) {
            const result = await invoke("query", this._baseRequest(sql, params));
            const response = jsonFromBuffer(result);
            const rows = response && Array.isArray(response.rows) ? response.rows : [];
            return decodeResultRows(rows);
        }

        async transaction(callback) {
            if (this._closed) {
                throw closedError();
            }
            if (typeof callback !== "function") {
                throw new TypeError("sqlite transaction callback must be a function");
            }
            if (this._activeTx != null) {
                throw new Error("sqlite nested transactions are not supported");
            }
            const transactionID = "tx-" + nextTransactionID++;
            await invoke("begin", { connection: this._id, transaction: transactionID });
            this._activeTx = transactionID;
            const tx = new SQLiteTransaction(this, transactionID);
            try {
                const result = await callback(tx);
                await invoke("commit", { connection: this._id, transaction: transactionID });
                return result;
            } catch (error) {
                try {
                    await invoke("rollback", { connection: this._id, transaction: transactionID });
                } catch (rollbackError) {
                    await this.close().catch(() => {});
                    throw new Error(`sqlite transaction failed and rollback also failed: ${error.message || error}. Connection was closed to protect state consistency.`);
                } finally {
                    this._activeTx = null;
                }
                throw error;
            } finally {
                if (this._activeTx === transactionID) {
                    this._activeTx = null;
                }
            }
        }

        async close() {
            if (this._closed) {
                return this._closePromise || Promise.resolve();
            }
            this._closed = true;
            this._activeTx = null;
            if (dbRegistry) {
                dbRegistry.unregister(this);
            }
            this._closePromise = closeConnection(this._id, false);
            await this._closePromise;
            return undefined;
        }
    }

    async function open(name, options) {
        const request = {
            connection: "db-" + nextConnectionID++,
            name: normalizeName(name)
        };
        if (options && typeof options === "object" && options.readOnly != null) {
            request.readOnly = Boolean(options.readOnly);
        }
        await invoke("open", request);
        return new SQLiteDatabase(request.connection);
    }

    globalThis.EJSSQLite = {
        open
    };
})();
