(function() {
    const moduleID = "ejs.fs";

    function nativeInvoke() {
        const invoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
        if (typeof invoke !== "function") {
            throw new Error("EJS native dispatcher is not available.");
        }
        return invoke;
    }

    function normalizePath(path) {
        if (typeof path !== "string") {
            throw new TypeError("fs path must be a string");
        }
        if (path.length === 0) {
            throw new TypeError("fs path must not be empty");
        }
        return path;
    }

    function normalizeEncoding(options) {
        let encoding = null;
        if (typeof options === "string") {
            encoding = options;
        } else if (options && typeof options === "object" && options.encoding != null) {
            encoding = options.encoding;
        }

        if (encoding == null) {
            return null;
        }

        const normalized = String(encoding).toLowerCase();
        if (normalized !== "utf8" && normalized !== "utf-8") {
            throw new TypeError("Only utf8 encoding is supported");
        }
        return "utf8";
    }

    function requestFromOptions(path, options) {
        const request = {
            path: normalizePath(path)
        };

        if (options && typeof options === "object" && typeof options !== "string") {
            if (options.root != null) {
                if (typeof options.root !== "string" || options.root.length === 0) {
                    throw new TypeError("fs root must be a non-empty string");
                }
                request.root = options.root;
            }
        }

        return request;
    }

    function renameRequestFromOptions(oldPath, newPath, options) {
        const request = requestFromOptions(oldPath, options);
        request.newPath = normalizePath(newPath);

        if (options && typeof options === "object" && typeof options !== "string") {
            if (options.newRoot != null) {
                if (typeof options.newRoot !== "string" || options.newRoot.length === 0) {
                    throw new TypeError("fs newRoot must be a non-empty string");
                }
                request.newRoot = options.newRoot;
            }
        }

        return request;
    }

    function boolOption(options, key, defaultValue) {
        if (!options || typeof options !== "object" || typeof options === "string" || options[key] == null) {
            return defaultValue;
        }
        if (typeof options[key] !== "boolean") {
            throw new TypeError(`fs options.${key} must be a boolean`);
        }
        return options[key];
    }

    function numberOption(options, key, defaultValue) {
        if (!options || typeof options !== "object" || typeof options === "string" || options[key] == null) {
            return defaultValue;
        }
        const value = Number(options[key]);
        if (!Number.isFinite(value) || value < 0) {
            throw new TypeError(`fs options.${key} must be a non-negative number`);
        }
        return value;
    }

    function normalizeMode(mode, defaultValue) {
        if (mode == null) {
            return defaultValue;
        }
        const value = Number(mode);
        if (!Number.isInteger(value) || value < 0 || value > 0o7777) {
            throw new TypeError("fs mode must be an integer between 0 and 0o7777");
        }
        return value;
    }

    function normalizeLength(length, defaultValue) {
        if (length == null) {
            return defaultValue;
        }
        const value = Number(length);
        if (!Number.isInteger(value) || value < 0) {
            throw new TypeError("fs length must be a non-negative integer");
        }
        return value;
    }

    function normalizeOwnerID(value, name) {
        const number = Number(value);
        if (!Number.isInteger(number) || number < 0) {
            throw new TypeError(`${name} must be a non-negative integer`);
        }
        return number;
    }

    function normalizeTimeMs(value, name) {
        let time = value;
        if (value instanceof Date) {
            time = value.getTime();
        }
        const number = Number(time);
        if (!Number.isFinite(number) || number < 0) {
            throw new TypeError(`${name} must be a non-negative time in milliseconds`);
        }
        return number;
    }

    function normalizeAccessMode(options) {
        let mode = null;
        if (typeof options === "string") {
            mode = options;
        } else if (options && typeof options === "object" && options.mode != null) {
            mode = options.mode;
        }

        if (mode == null) {
            return "read";
        }

        const normalized = String(mode).toLowerCase().replace("-", "");
        if (normalized === "read" || normalized === "r") {
            return "read";
        }
        if (normalized === "write" || normalized === "w") {
            return "write";
        }
        if (normalized === "readwrite" || normalized === "rw") {
            return "readwrite";
        }
        throw new TypeError("access mode must be read, write, or readwrite");
    }

    function copyFileRequestFromOptions(srcPath, destPath, options) {
        const request = renameRequestFromOptions(srcPath, destPath, options);

        if (options && typeof options === "object" && typeof options !== "string" && options.flag != null) {
            request.flag = String(options.flag);
        }

        return request;
    }

    function encodeUtf8(input) {
        if (typeof TextEncoder !== "undefined") {
            return new TextEncoder().encode(input);
        }
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

    function bytesFromData(data, options) {
        if (typeof data === "string") {
            normalizeEncoding(options);
            return encodeUtf8(data);
        }
        if (data instanceof ArrayBuffer) {
            return data;
        }
        if (ArrayBuffer.isView(data)) {
            return data;
        }
        throw new TypeError("fs data must be a string, ArrayBuffer, or ArrayBufferView");
    }

    async function readFile(path, options) {
        const encoding = normalizeEncoding(options);
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "readFile", JSON.stringify(request), null);
        return encoding ? decodeUtf8(result) : result;
    }

    async function writeFile(path, data, options) {
        const request = requestFromOptions(path, options);
        if (options && typeof options === "object" && typeof options !== "string" && options.flag != null) {
            request.flag = String(options.flag);
        }
        const bytes = bytesFromData(data, options);
        await nativeInvoke()(moduleID, "writeFile", JSON.stringify(request), bytes);
        return undefined;
    }

    function jsonFromBuffer(buffer) {
        return JSON.parse(decodeUtf8(buffer));
    }

    function makeStats(response) {
        const type = typeof response.type === "string" ? response.type : "other";
        const mode = Number(response.mode || 0);
        return {
            dev: Number(response.dev || 0),
            ino: Number(response.ino || 0),
            mode: mode,
            nlink: Number(response.nlink || 0),
            uid: Number(response.uid || 0),
            gid: Number(response.gid || 0),
            rdev: Number(response.rdev || 0),
            size: Number(response.size || 0),
            blksize: Number(response.blksize || 0),
            blocks: Number(response.blocks || 0),
            atimeMs: typeof response.atimeMs === "number" ? response.atimeMs : null,
            mtimeMs: typeof response.mtimeMs === "number" ? response.mtimeMs : null,
            ctimeMs: typeof response.ctimeMs === "number" ? response.ctimeMs : null,
            birthtimeMs: typeof response.birthtimeMs === "number" ? response.birthtimeMs : null,
            type, // legacy fallback
            isFile() {
                if (mode !== 0) return (mode & 0o170000) === 0o100000;
                return type === "file";
            },
            isDirectory() {
                if (mode !== 0) return (mode & 0o170000) === 0o040000;
                return type === "directory";
            },
            isSymbolicLink() {
                if (mode !== 0) return (mode & 0o170000) === 0o120000;
                return type === "symbolicLink";
            }
        };
    }

    async function stat(path, options) {
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "stat", JSON.stringify(request), null);
        return makeStats(jsonFromBuffer(result));
    }

    async function lstat(path, options) {
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "lstat", JSON.stringify(request), null);
        return makeStats(jsonFromBuffer(result));
    }

    async function exists(path, options) {
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "exists", JSON.stringify(request), null);
        const response = jsonFromBuffer(result);
        return Boolean(response.exists);
    }

    async function access(path, options) {
        const request = requestFromOptions(path, options);
        request.mode = normalizeAccessMode(options);
        await nativeInvoke()(moduleID, "access", JSON.stringify(request), null);
        return undefined;
    }

    function closeFileHandle(handle, suppressErrors) {
        try {
            const promise = nativeInvoke()(moduleID, "fileHandleClose", JSON.stringify({ handle }), null);
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

    const fileHandleRegistry = typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(handle => {
        closeFileHandle(handle, true);
    }) : null;

    class FileHandle {
        constructor(handle) {
            this.handle = String(handle);
            this.closed = false;
            if (fileHandleRegistry) {
                fileHandleRegistry.register(this, this.handle, this);
            }
        }

        ensureOpen() {
            if (this.closed) {
                throw new TypeError("FileHandle is closed");
            }
        }

        async read(options) {
            this.ensureOpen();
            const encoding = normalizeEncoding(options);
            const request = {
                handle: this.handle,
                length: normalizeLength(numberOption(options, "length", 64 * 1024), 64 * 1024)
            };
            if (options && typeof options === "object" && typeof options !== "string" && options.position != null) {
                request.position = Math.floor(numberOption(options, "position", 0));
            }
            const result = await nativeInvoke()(moduleID, "fileHandleRead", JSON.stringify(request), null);
            return encoding ? decodeUtf8(result) : result;
        }

        async write(data, options) {
            this.ensureOpen();
            const request = {
                handle: this.handle
            };
            if (options && typeof options === "object" && typeof options !== "string" && options.position != null) {
                request.position = Math.floor(numberOption(options, "position", 0));
            }
            const result = await nativeInvoke()(moduleID, "fileHandleWrite", JSON.stringify(request), bytesFromData(data, options));
            return jsonFromBuffer(result).bytesWritten;
        }

        async truncate(length = 0) {
            this.ensureOpen();
            const request = {
                handle: this.handle,
                length: normalizeLength(length, 0)
            };
            await nativeInvoke()(moduleID, "fileHandleTruncate", JSON.stringify(request), null);
            return undefined;
        }

        async datasync() {
            this.ensureOpen();
            await nativeInvoke()(moduleID, "fileHandleDatasync", JSON.stringify({ handle: this.handle }), null);
            return undefined;
        }

        async sync() {
            this.ensureOpen();
            await nativeInvoke()(moduleID, "fileHandleSync", JSON.stringify({ handle: this.handle }), null);
            return undefined;
        }

        async close() {
            if (this.closed) {
                return this._closePromise || Promise.resolve();
            }
            this.closed = true;
            if (fileHandleRegistry) {
                fileHandleRegistry.unregister(this);
            }
            this._closePromise = closeFileHandle(this.handle, false);
            await this._closePromise;
            return undefined;
        }
    }

    async function open(path, flags = "r", mode = 0o666, options) {
        if (flags && typeof flags === "object") {
            options = flags;
            flags = "r";
            mode = 0o666;
        } else if (mode && typeof mode === "object") {
            options = mode;
            mode = 0o666;
        }

        const request = requestFromOptions(path, options);
        request.flags = String(flags == null ? "r" : flags);
        request.mode = normalizeMode(mode, 0o666);
        const result = await nativeInvoke()(moduleID, "open", JSON.stringify(request), null);
        const response = jsonFromBuffer(result);
        return new FileHandle(response.handle);
    }

    async function readdir(path, options) {
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "readdir", JSON.stringify(request), null);
        const response = jsonFromBuffer(result);
        return Array.isArray(response.entries) ? response.entries : [];
    }

    async function rename(oldPath, newPath, options) {
        const request = renameRequestFromOptions(oldPath, newPath, options);
        await nativeInvoke()(moduleID, "rename", JSON.stringify(request), null);
        return undefined;
    }

    async function mkdir(path, options) {
        const request = requestFromOptions(path, options);
        request.recursive = boolOption(options, "recursive", false);
        await nativeInvoke()(moduleID, "mkdir", JSON.stringify(request), null);
        return undefined;
    }

    async function copyFile(srcPath, destPath, options) {
        const request = copyFileRequestFromOptions(srcPath, destPath, options);
        await nativeInvoke()(moduleID, "copyFile", JSON.stringify(request), null);
        return undefined;
    }

    async function readLink(path, options) {
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "readLink", JSON.stringify(request), null);
        return jsonFromBuffer(result).target;
    }

    async function link(existingPath, newPath, options) {
        const request = renameRequestFromOptions(existingPath, newPath, options);
        await nativeInvoke()(moduleID, "link", JSON.stringify(request), null);
        return undefined;
    }

    async function symlink(target, path, options) {
        if (typeof target !== "string" || target.length === 0) {
            throw new TypeError("symlink target must be a non-empty string");
        }
        const request = requestFromOptions(path, options);
        request.target = target;
        await nativeInvoke()(moduleID, "symlink", JSON.stringify(request), null);
        return undefined;
    }

    async function statFs(path, options) {
        const request = requestFromOptions(path, options);
        const result = await nativeInvoke()(moduleID, "statFs", JSON.stringify(request), null);
        return jsonFromBuffer(result);
    }

    async function makeTempDir(prefix = "tmp-", options) {
        if (prefix && typeof prefix === "object") {
            options = prefix;
            prefix = "tmp-";
        }
        const dir = options && typeof options === "object" && typeof options !== "string" && options.dir != null
            ? options.dir
            : ".";
        const request = requestFromOptions(dir, options);
        request.prefix = String(prefix);
        const result = await nativeInvoke()(moduleID, "makeTempDir", JSON.stringify(request), null);
        return jsonFromBuffer(result).path;
    }

    async function makeTempFile(prefix = "tmp-", options) {
        if (prefix && typeof prefix === "object") {
            options = prefix;
            prefix = "tmp-";
        }
        const dir = options && typeof options === "object" && typeof options !== "string" && options.dir != null
            ? options.dir
            : ".";
        const request = requestFromOptions(dir, options);
        request.prefix = String(prefix);
        const result = await nativeInvoke()(moduleID, "makeTempFile", JSON.stringify(request), null);
        return jsonFromBuffer(result).path;
    }

    async function chmod(path, mode, options) {
        const request = requestFromOptions(path, options);
        request.mode = normalizeMode(mode, 0);
        await nativeInvoke()(moduleID, "chmod", JSON.stringify(request), null);
        return undefined;
    }

    async function chownRequest(method, path, uid, gid, options) {
        const request = requestFromOptions(path, options);
        request.uid = normalizeOwnerID(uid, "uid");
        request.gid = normalizeOwnerID(gid, "gid");
        await nativeInvoke()(moduleID, method, JSON.stringify(request), null);
        return undefined;
    }

    async function chown(path, uid, gid, options) {
        return chownRequest("chown", path, uid, gid, options);
    }

    async function lchown(path, uid, gid, options) {
        return chownRequest("lchown", path, uid, gid, options);
    }

    async function utime(path, atime, mtime, options) {
        const request = requestFromOptions(path, options);
        request.atimeMs = normalizeTimeMs(atime, "atime");
        request.mtimeMs = normalizeTimeMs(mtime, "mtime");
        await nativeInvoke()(moduleID, "utime", JSON.stringify(request), null);
        return undefined;
    }

    async function lutime(path, atime, mtime, options) {
        const request = requestFromOptions(path, options);
        request.atimeMs = normalizeTimeMs(atime, "atime");
        request.mtimeMs = normalizeTimeMs(mtime, "mtime");
        await nativeInvoke()(moduleID, "lutime", JSON.stringify(request), null);
        return undefined;
    }

    async function unlink(path, options) {
        const request = requestFromOptions(path, options);
        request.recursive = false;
        request.force = false;
        await nativeInvoke()(moduleID, "delete", JSON.stringify(request), null);
        return undefined;
    }

    async function rm(path, options) {
        const request = requestFromOptions(path, options);
        request.recursive = boolOption(options, "recursive", false);
        request.force = boolOption(options, "force", false);
        await nativeInvoke()(moduleID, "delete", JSON.stringify(request), null);
        return undefined;
    }

    const deletePath = rm;
    const remove = rm;
    const createDirectory = mkdir;

    globalThis.EJSFS = {
        promises: {
            access,
            chmod,
            chown,
            createDirectory,
            copyFile,
            delete: deletePath,
            exists,
            lchown,
            link,
            list: readdir,
            lstat,
            lutime,
            makeTempDir,
            makeTempFile,
            mkdir,
            open,
            readdir,
            readFile,
            readLink,
            rename,
            remove,
            rm,
            stat,
            statFs,
            symlink,
            unlink,
            utime,
            writeFile
        },
        FileHandle
    };
})();
