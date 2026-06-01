(function() {
    class URLSearchParams {
        constructor(init = '') {
            this._pairs = [];
            if (typeof init === 'string') {
                if (init.startsWith('?')) {
                    init = init.slice(1);
                }
                if (init) {
                    const parts = init.split('&');
                    for (const p of parts) {
                        const idx = p.indexOf('=');
                        if (idx !== -1) {
                            const key = decodeURIComponent(p.slice(0, idx).replace(/\+/g, ' '));
                            const val = decodeURIComponent(p.slice(idx + 1).replace(/\+/g, ' '));
                            this._pairs.push([key, val]);
                        } else {
                            this._pairs.push([decodeURIComponent(p.replace(/\+/g, ' ')), '']);
                        }
                    }
                }
            } else if (Array.isArray(init)) {
                for (const item of init) {
                    if (Array.isArray(item) && item.length >= 1) {
                        this._pairs.push([String(item[0]), item[1] === undefined ? '' : String(item[1])]);
                    }
                }
            } else if (init instanceof URLSearchParams) {
                this._pairs = init._pairs.map(p => [...p]);
            } else if (init && typeof init === 'object') {
                for (const key of Object.keys(init)) {
                    this._pairs.push([key, String(init[key])]);
                }
            }
            this._onChange = null;
        }

        _triggerChange() {
            if (typeof this._onChange === 'function') {
                this._onChange(this.toString());
            }
        }

        append(name, value) {
            this._pairs.push([String(name), String(value)]);
            this._triggerChange();
        }

        delete(name) {
            const target = String(name);
            this._pairs = this._pairs.filter(p => p[0] !== target);
            this._triggerChange();
        }

        get(name) {
            const target = String(name);
            const found = this._pairs.find(p => p[0] === target);
            return found ? found[1] : null;
        }

        getAll(name) {
            const target = String(name);
            return this._pairs.filter(p => p[0] === target).map(p => p[1]);
        }

        has(name) {
            const target = String(name);
            return this._pairs.some(p => p[0] === target);
        }

        set(name, value) {
            const targetName = String(name);
            const targetVal = String(value);
            let replaced = false;
            const nextPairs = [];

            for (const pair of this._pairs) {
                if (pair[0] !== targetName) {
                    nextPairs.push(pair);
                } else if (!replaced) {
                    nextPairs.push([targetName, targetVal]);
                    replaced = true;
                }
            }

            if (!replaced) {
                this._pairs.push([targetName, targetVal]);
            } else {
                this._pairs = nextPairs;
            }
            this._triggerChange();
        }

        toString() {
            return this._pairs.map(p => {
                return encodeURIComponent(p[0]).replace(/%20/g, '+') + '=' + encodeURIComponent(p[1]).replace(/%20/g, '+');
            }).join('&');
        }

        forEach(callback, thisArg) {
            for (const [key, val] of this._pairs) {
                callback.call(thisArg, val, key, this);
            }
        }

        *[Symbol.iterator]() {
            for (const p of this._pairs) {
                yield [...p];
            }
        }

        *entries() {
            for (const p of this._pairs) {
                yield [...p];
            }
        }

        *keys() {
            for (const p of this._pairs) {
                yield p[0];
            }
        }

        *values() {
            for (const p of this._pairs) {
                yield p[1];
            }
        }
    }

    // A robust, standard-oriented regex URL parser suited for resource-constrained runtimes
    const URL_REGEX = /^(?:([^:\/?#]+):)?(?:\/\/((?:(?:[^:@\/]*):?(?:[^:@\/]*)@)?([^:\/?#]*)(?::(\d*))?))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/;

    function defaultPortForProtocol(protocol) {
        switch (String(protocol).toLowerCase()) {
            case "ftp:":
                return "21";
            case "http:":
            case "ws:":
                return "80";
            case "https:":
            case "wss:":
                return "443";
            default:
                return "";
        }
    }

    function popLastPathSegment(path) {
        const index = path.lastIndexOf("/");
        if (index < 0) {
            return "";
        }
        return path.slice(0, index);
    }

    // RFC 3986 remove_dot_segments.
    function normalizePathname(pathname) {
        let input = pathname;
        let output = "";

        while (input.length > 0) {
            if (input.startsWith("../")) {
                input = input.slice(3);
                continue;
            }
            if (input.startsWith("./")) {
                input = input.slice(2);
                continue;
            }
            if (input.startsWith("/./")) {
                input = "/" + input.slice(3);
                continue;
            }
            if (input === "/.") {
                input = "/";
                continue;
            }
            if (input.startsWith("/../")) {
                input = "/" + input.slice(4);
                output = popLastPathSegment(output);
                continue;
            }
            if (input === "/..") {
                input = "/";
                output = popLastPathSegment(output);
                continue;
            }
            if (input === "." || input === "..") {
                input = "";
                continue;
            }

            let segment = "";
            if (input[0] === "/") {
                const nextSlash = input.indexOf("/", 1);
                if (nextSlash < 0) {
                    segment = input;
                    input = "";
                } else {
                    segment = input.slice(0, nextSlash);
                    input = input.slice(nextSlash);
                }
            } else {
                const nextSlash = input.indexOf("/");
                if (nextSlash < 0) {
                    segment = input;
                    input = "";
                } else {
                    segment = input.slice(0, nextSlash);
                    input = input.slice(nextSlash);
                }
            }
            output += segment;
        }

        return output || "/";
    }

    class URL {
        constructor(url, base) {
            url = String(url).trim();
            let absoluteUrl = url;

            if (base !== undefined) {
                base = String(base).trim();
                const baseParsed = base.match(URL_REGEX);
                if (!baseParsed || !baseParsed[1]) {
                    throw new TypeError(`Invalid base URL: ${base}`);
                }
                
                // If the url is not absolute, resolve it relative to base
                const isAbsolute = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url);
                if (!isAbsolute) {
                    const baseProtocol = baseParsed[1];
                    const baseAuthority = baseParsed[2] || '';
                    let basePath = baseParsed[5] || '/';
                    
                    if (url.startsWith('//')) {
                        absoluteUrl = baseProtocol + ':' + url;
                    } else if (url.startsWith('/')) {
                        absoluteUrl = baseProtocol + '://' + baseAuthority + url;
                    } else if (url.startsWith('#') || url.startsWith('?')) {
                        const baseSearch = baseParsed[6] ? '?' + baseParsed[6] : '';
                        const baseHash = baseParsed[7] ? '#' + baseParsed[7] : '';
                        const baseNoSearchHash = base.slice(0, base.length - baseSearch.length - baseHash.length);
                        absoluteUrl = baseNoSearchHash + url;
                    } else {
                        // Relative pathname resolution
                        const dirIdx = basePath.lastIndexOf('/');
                        const resolvedDir = dirIdx !== -1 ? basePath.slice(0, dirIdx + 1) : '/';
                        absoluteUrl = baseProtocol + '://' + baseAuthority + resolvedDir + url;
                    }
                }
            }

            const parsed = absoluteUrl.match(URL_REGEX);
            if (!parsed || !parsed[1]) {
                throw new TypeError(`Invalid URL: ${url}`);
            }

            this._protocol = parsed[1];
            this._authority = parsed[2] || '';
            this._host = parsed[3] + (parsed[4] ? ':' + parsed[4] : '');
            this._hostname = parsed[3];
            this._port = parsed[4] || '';
            this._pathname = parsed[5] || '/';
            if (!this._pathname.startsWith('/')) {
                this._pathname = '/' + this._pathname;
            }
            this._pathname = normalizePathname(this._pathname);
            this._search = parsed[6] ? '?' + parsed[6] : '';
            this._hash = parsed[7] ? '#' + parsed[7] : '';

            // Clean up protocol format (must end in colon)
            if (!this._protocol.endsWith(':')) {
                this._protocol += ':';
            }

            this._searchParams = new URLSearchParams(this._search);
            this._searchParams._onChange = (newSearchString) => {
                this._search = newSearchString ? '?' + newSearchString : '';
            };
        }

        get href() {
            const authStr = this._authority ? '//' + this._authority : '';
            return this._protocol + authStr + this._pathname + this._search + this._hash;
        }

        set href(val) {
            const newUrl = new URL(val);
            this._protocol = newUrl._protocol;
            this._authority = newUrl._authority;
            this._host = newUrl._host;
            this._hostname = newUrl._hostname;
            this._port = newUrl._port;
            this._pathname = newUrl._pathname;
            this._search = newUrl._search;
            this._hash = newUrl._hash;
            this._searchParams = newUrl._searchParams;
            this._searchParams._onChange = (newSearchString) => {
                this._search = newSearchString ? '?' + newSearchString : '';
            };
        }

        get protocol() { return this._protocol; }
        set protocol(val) {
            val = String(val).toLowerCase();
            if (/^[a-z][a-z0-9+.-]*:?$/.test(val)) {
                this._protocol = val.endsWith(':') ? val : val + ':';
            }
        }

        get origin() {
            const protocol = this._protocol.toLowerCase();
            if (!this._host || protocol === 'file:') {
                return 'null';
            }
            if (protocol === 'http:' ||
                protocol === 'https:' ||
                protocol === 'ws:' ||
                protocol === 'wss:' ||
                protocol === 'ftp:') {
                const defaultPort = defaultPortForProtocol(protocol);
                const port = this._port && this._port !== defaultPort ? ':' + this._port : '';
                return this._protocol + '//' + this._hostname + port;
            }
            return 'null';
        }

        get host() { return this._host; }
        set host(val) {
            val = String(val);
            const portIdx = val.lastIndexOf(':');
            if (portIdx !== -1) {
                this._hostname = val.slice(0, portIdx);
                this._port = val.slice(portIdx + 1);
            } else {
                this._hostname = val;
                this._port = '';
            }
            this._host = val;
            this._authority = this._host; // simple mapping
        }

        get hostname() { return this._hostname; }
        set hostname(val) {
            this._hostname = String(val);
            this._host = this._hostname + (this._port ? ':' + this._port : '');
            this._authority = this._host;
        }

        get port() { return this._port; }
        set port(val) {
            this._port = String(val);
            this._host = this._hostname + (this._port ? ':' + this._port : '');
            this._authority = this._host;
        }

        get pathname() { return this._pathname; }
        set pathname(val) {
            val = String(val);
            const absolutePath = val.startsWith('/') ? val : '/' + val;
            this._pathname = normalizePathname(absolutePath);
        }

        get search() { return this._search; }
        set search(val) {
            val = String(val);
            if (!val) {
                this._search = '';
            } else {
                this._search = val.startsWith('?') ? val : '?' + val;
            }
            this._searchParams = new URLSearchParams(this._search);
            this._searchParams._onChange = (newSearchString) => {
                this._search = newSearchString ? '?' + newSearchString : '';
            };
        }

        get searchParams() { return this._searchParams; }

        get hash() { return this._hash; }
        set hash(val) {
            val = String(val);
            if (!val) {
                this._hash = '';
            } else {
                this._hash = val.startsWith('#') ? val : '#' + val;
            }
        }

        toString() {
            return this.href;
        }

        toJSON() {
            return this.href;
        }
    }

    globalThis.URLSearchParams = URLSearchParams;
    globalThis.URL = URL;
})();
