(function() {
    function assertPath(path) {
        if (typeof path !== "string") {
            throw new TypeError("path must be a string");
        }
        return path;
    }

    function normalizeParts(path, allowAboveRoot) {
        const parts = path.split("/");
        const output = [];

        for (let i = 0; i < parts.length; i++) {
            const part = parts[i];
            if (part === "" || part === ".") {
                continue;
            }
            if (part === "..") {
                if (output.length > 0 && output[output.length - 1] !== "..") {
                    output.pop();
                } else if (allowAboveRoot) {
                    output.push("..");
                }
                continue;
            }
            output.push(part);
        }

        return output;
    }

    function normalize(path) {
        path = assertPath(path);
        if (path.length === 0) {
            return ".";
        }

        const absolute = path.charCodeAt(0) === 47;
        const trailingSlash = path.length > 1 && path.charCodeAt(path.length - 1) === 47;
        const normalized = normalizeParts(path, !absolute).join("/");

        if (normalized.length === 0) {
            return absolute ? "/" : trailingSlash ? "./" : ".";
        }

        let result = absolute ? "/" + normalized : normalized;
        if (trailingSlash) {
            result += "/";
        }
        return result;
    }

    function join() {
        if (arguments.length === 0) {
            return ".";
        }

        let joined = "";
        for (let i = 0; i < arguments.length; i++) {
            const part = assertPath(arguments[i]);
            if (part.length === 0) {
                continue;
            }
            joined += joined.length === 0 ? part : "/" + part;
        }
        return joined.length === 0 ? "." : normalize(joined);
    }

    function dirname(path) {
        path = assertPath(path);
        if (path.length === 0) {
            return ".";
        }

        let end = path.length - 1;
        while (end > 0 && path.charCodeAt(end) === 47) {
            end--;
        }

        const hasRoot = path.charCodeAt(0) === 47;
        const slash = path.lastIndexOf("/", end);
        if (slash < 0) {
            return ".";
        }
        if (slash === 1 && hasRoot && path.charCodeAt(1) === 47) {
            return "//";
        }
        if (slash === 0) {
            return hasRoot ? "/" : ".";
        }
        return path.slice(0, slash);
    }

    function basename(path, suffix) {
        path = assertPath(path);
        if (suffix !== undefined && typeof suffix !== "string") {
            throw new TypeError("suffix must be a string");
        }

        let end = path.length;
        while (end > 0 && path.charCodeAt(end - 1) === 47) {
            end--;
        }
        if (end === 0) {
            return "";
        }

        const start = path.lastIndexOf("/", end - 1) + 1;
        let base = path.slice(start, end);
        if (suffix && base.endsWith(suffix)) {
            base = base.slice(0, base.length - suffix.length);
        }
        return base;
    }

    function extname(path) {
        const base = basename(path);
        if (base === "..") {
            return "";
        }
        const dot = base.lastIndexOf(".");
        if (dot <= 0) {
            return "";
        }
        return base.slice(dot);
    }

    function isAbsolute(path) {
        path = assertPath(path);
        return path.length > 0 && path.charCodeAt(0) === 47;
    }

    function comparableParts(path) {
        const normalized = normalize(path);
        if (normalized === ".") {
            return [];
        }
        return normalized.replace(/^\/+/, "").split("/").filter(Boolean);
    }

    function currentWorkingDirectory() {
        try {
            const processObject = globalThis.process;
            if (processObject && typeof processObject.cwd === "function") {
                const cwd = processObject.cwd();
                if (typeof cwd === "string" && cwd.length > 0 && isAbsolute(cwd)) {
                    return normalize(cwd);
                }
            }
        } catch (_) {
            // Fall through to root fallback.
        }
        try {
            const systemObject = globalThis.EJSSystem;
            if (systemObject && typeof systemObject.cwd === "function") {
                const cwd = systemObject.cwd();
                if (typeof cwd === "string" && cwd.length > 0 && isAbsolute(cwd)) {
                    return normalize(cwd);
                }
            }
        } catch (_) {
            // Fall through to root fallback.
        }
        return "/";
    }

    function resolve() {
        let resolvedPath = "";
        let resolvedAbsolute = false;

        for (let i = arguments.length - 1; i >= -1 && !resolvedAbsolute; i--) {
            let path;
            if (i >= 0) {
                path = assertPath(arguments[i]);
                if (path.length === 0) {
                    continue;
                }
            } else {
                path = currentWorkingDirectory();
            }
            resolvedPath = path + "/" + resolvedPath;
            resolvedAbsolute = path.charCodeAt(0) === 47;
        }

        const normalized = normalizeParts(resolvedPath, !resolvedAbsolute).join("/");
        if (resolvedAbsolute) {
            return normalized.length > 0 ? "/" + normalized : "/";
        }
        return normalized.length > 0 ? normalized : ".";
    }

    function parse(path) {
        path = assertPath(path);
        const result = { root: "", dir: "", base: "", ext: "", name: "" };
        if (path.length === 0) {
            return result;
        }

        const absolute = path.charCodeAt(0) === 47;
        const start = absolute ? 1 : 0;
        if (absolute) {
            result.root = "/";
        }

        let end = path.length - 1;
        while (end >= start && path.charCodeAt(end) === 47) {
            end--;
        }
        if (end < start) {
            result.dir = result.root;
            return result;
        }

        const slash = path.lastIndexOf("/", end);
        const baseStart = slash < 0 ? start : slash + 1;
        result.base = path.slice(baseStart, end + 1);
        if (slash > 0) {
            result.dir = path.slice(0, slash);
        } else if (absolute) {
            result.dir = "/";
        }

        const dot = result.base.lastIndexOf(".");
        if (dot > 0) {
            result.name = result.base.slice(0, dot);
            result.ext = result.base.slice(dot);
        } else {
            result.name = result.base;
        }
        return result;
    }

    function format(pathObject) {
        if (pathObject === null || typeof pathObject !== "object") {
            throw new TypeError("pathObject must be an object");
        }
        const dir = pathObject.dir || pathObject.root || "";
        const base = pathObject.base || ((pathObject.name || "") + (pathObject.ext || ""));
        if (dir.length === 0) {
            return base;
        }
        if (dir === "/") {
            return "/" + base;
        }
        return dir === pathObject.root ? dir + base : dir + "/" + base;
    }

    function relative(from, to) {
        from = assertPath(from);
        to = assertPath(to);

        const cwd = currentWorkingDirectory();
        const fromPath = isAbsolute(from) ? normalize(from) : join(cwd, from);
        const toPath = isAbsolute(to) ? normalize(to) : join(cwd, to);

        if (fromPath === toPath) {
            return "";
        }

        const fromParts = comparableParts(fromPath);
        const toParts = comparableParts(toPath);
        let same = 0;
        const limit = Math.min(fromParts.length, toParts.length);
        while (same < limit && fromParts[same] === toParts[same]) {
            same++;
        }

        const output = [];
        for (let i = same; i < fromParts.length; i++) {
            output.push("..");
        }
        for (let i = same; i < toParts.length; i++) {
            output.push(toParts[i]);
        }
        return output.join("/");
    }

    const posix = Object.freeze({
        normalize: normalize,
        join: join,
        dirname: dirname,
        basename: basename,
        extname: extname,
        isAbsolute: isAbsolute,
        relative: relative,
        resolve: resolve,
        parse: parse,
        format: format
    });

    Object.defineProperty(globalThis, "EJSPath", {
        configurable: true,
        writable: true,
        value: Object.freeze({ posix: posix })
    });
})();
