(function() {
    function assertString(value, name) {
        if (typeof value !== "string") {
            throw new TypeError(name + " must be a string");
        }
        return value;
    }

    function parseIPv4Bytes(value) {
        value = assertString(value, "address");
        const parts = value.split(".");
        if (parts.length !== 4) {
            return null;
        }

        const bytes = [];
        for (let i = 0; i < parts.length; i++) {
            const part = parts[i];
            if (!/^(0|[1-9][0-9]{0,2})$/.test(part)) {
                return null;
            }
            const byte = Number(part);
            if (!Number.isInteger(byte) || byte < 0 || byte > 255) {
                return null;
            }
            bytes.push(byte);
        }
        return bytes;
    }

    function parseHextets(value) {
        if (value.length === 0) {
            return [];
        }
        const parts = value.split(":");
        const output = [];
        for (let i = 0; i < parts.length; i++) {
            const part = parts[i];
            if (!/^[0-9A-Fa-f]{1,4}$/.test(part)) {
                return null;
            }
            output.push(parseInt(part, 16));
        }
        return output;
    }

    function wordsToBytes(words) {
        const bytes = [];
        for (let i = 0; i < words.length; i++) {
            bytes.push((words[i] >>> 8) & 0xff, words[i] & 0xff);
        }
        return bytes;
    }

    function bytesToWords(bytes) {
        const words = [];
        for (let i = 0; i < bytes.length; i += 2) {
            words.push(((bytes[i] << 8) | bytes[i + 1]) >>> 0);
        }
        return words;
    }

    function normalizeIPv4Bytes(bytes) {
        return bytes.join(".");
    }

    function normalizeIPv6Bytes(bytes) {
        const words = bytesToWords(bytes);
        let bestStart = -1;
        let bestLength = 0;

        for (let i = 0; i < words.length;) {
            if (words[i] !== 0) {
                i++;
                continue;
            }
            const start = i;
            while (i < words.length && words[i] === 0) {
                i++;
            }
            const length = i - start;
            if (length > bestLength && length >= 2) {
                bestStart = start;
                bestLength = length;
            }
        }

        const hex = words.map((word) => word.toString(16));
        if (bestStart < 0) {
            return hex.join(":");
        }

        const head = hex.slice(0, bestStart).join(":");
        const tail = hex.slice(bestStart + bestLength).join(":");
        if (head.length > 0 && tail.length > 0) {
            return head + "::" + tail;
        }
        if (head.length > 0) {
            return head + "::";
        }
        if (tail.length > 0) {
            return "::" + tail;
        }
        return "::";
    }

    function splitIPv6Scope(value) {
        const percent = value.indexOf("%");
        if (percent < 0) {
            return { address: value, scopeId: "" };
        }
        if (percent === 0 || percent !== value.lastIndexOf("%") || percent === value.length - 1) {
            return null;
        }
        return {
            address: value.slice(0, percent),
            scopeId: value.slice(percent + 1)
        };
    }

    function parseIPv6Bytes(value) {
        value = assertString(value, "address");
        if (value.length === 0) {
            return null;
        }

        const scopedInput = splitIPv6Scope(value);
        if (scopedInput == null || scopedInput.address.length === 0) {
            return null;
        }

        let normalizedInput = scopedInput.address;
        if (normalizedInput.indexOf(".") >= 0) {
            const lastColon = normalizedInput.lastIndexOf(":");
            if (lastColon < 0) {
                return null;
            }
            const ipv4Bytes = parseIPv4Bytes(normalizedInput.slice(lastColon + 1));
            if (ipv4Bytes == null) {
                return null;
            }
            const first = ((ipv4Bytes[0] << 8) | ipv4Bytes[1]).toString(16);
            const second = ((ipv4Bytes[2] << 8) | ipv4Bytes[3]).toString(16);
            normalizedInput = normalizedInput.slice(0, lastColon + 1) + first + ":" + second;
        }

        const compressionParts = normalizedInput.split("::");
        if (compressionParts.length > 2) {
            return null;
        }

        const hasCompression = compressionParts.length === 2;
        const head = parseHextets(compressionParts[0]);
        const tail = parseHextets(hasCompression ? compressionParts[1] : "");
        if (head == null || tail == null) {
            return null;
        }

        let words;
        if (hasCompression) {
            const missing = 8 - head.length - tail.length;
            if (missing < 1) {
                return null;
            }
            words = head.concat(new Array(missing).fill(0), tail);
        } else {
            if (head.length !== 8) {
                return null;
            }
            words = head;
        }

        if (words.length !== 8) {
            return null;
        }
        return {
            bytes: wordsToBytes(words),
            scopeId: scopedInput.scopeId
        };
    }

    function freezeParseResult(result) {
        result.bytes = Object.freeze(result.bytes.slice());
        return Object.freeze(result);
    }

    function parse(value) {
        value = assertString(value, "address");

        const ipv4 = parseIPv4Bytes(value);
        if (ipv4 != null) {
            const normalized = normalizeIPv4Bytes(ipv4);
            return freezeParseResult({
                address: normalized,
                family: 4,
                normalized: normalized,
                bytes: ipv4
            });
        }

        const ipv6 = parseIPv6Bytes(value);
        if (ipv6 != null) {
            const normalizedAddress = normalizeIPv6Bytes(ipv6.bytes);
            const normalized = ipv6.scopeId ? normalizedAddress + "%" + ipv6.scopeId : normalizedAddress;
            const result = {
                address: normalized,
                family: 6,
                normalized: normalized,
                bytes: ipv6.bytes
            };
            if (ipv6.scopeId) {
                result.scopeId = ipv6.scopeId;
            }
            return freezeParseResult(result);
        }

        throw new TypeError("invalid IP address");
    }

    function isValidIPv4(value) {
        return typeof value === "string" && parseIPv4Bytes(value) != null;
    }

    function isValidIPv6(value) {
        return typeof value === "string" && parseIPv6Bytes(value) != null;
    }

    function isValid(value) {
        return isValidIPv4(value) || isValidIPv6(value);
    }

    function parseCIDR(value) {
        value = assertString(value, "cidr");
        const slash = value.indexOf("/");
        if (slash <= 0 || slash !== value.lastIndexOf("/") || slash === value.length - 1) {
            throw new TypeError("invalid CIDR");
        }

        const address = parse(value.slice(0, slash));
        const prefixText = value.slice(slash + 1);
        if (!/^(0|[1-9][0-9]*)$/.test(prefixText)) {
            throw new TypeError("invalid CIDR prefix length");
        }
        const prefixLength = Number(prefixText);
        const maxPrefix = address.family === 4 ? 32 : 128;
        if (!Number.isInteger(prefixLength) || prefixLength < 0 || prefixLength > maxPrefix) {
            throw new TypeError("CIDR prefix length out of range");
        }

        return freezeParseResult({
            address: address.address,
            family: address.family,
            prefixLength: prefixLength,
            normalized: address.normalized + "/" + prefixLength,
            bytes: address.bytes
        });
    }

    function isValidCIDR(value) {
        if (typeof value !== "string") {
            return false;
        }
        try {
            parseCIDR(value);
            return true;
        } catch (_) {
            return false;
        }
    }

    function expectedByteLengthForFamily(family) {
        if (family === 4) {
            return 4;
        }
        if (family === 6) {
            return 16;
        }
        return -1;
    }

    function assertCIDRObject(cidr) {
        if (!cidr || typeof cidr !== "object") {
            throw new TypeError("cidr must be a string or parsed CIDR object");
        }

        const expectedBytes = expectedByteLengthForFamily(cidr.family);
        const maxPrefix = expectedBytes * 8;
        if (expectedBytes < 0 ||
                !Number.isInteger(cidr.prefixLength) ||
                cidr.prefixLength < 0 ||
                cidr.prefixLength > maxPrefix ||
                !Array.isArray(cidr.bytes) ||
                cidr.bytes.length !== expectedBytes) {
            throw new TypeError("cidr object is invalid");
        }

        for (let i = 0; i < cidr.bytes.length; i++) {
            const byte = cidr.bytes[i];
            if (!Number.isInteger(byte) || byte < 0 || byte > 255) {
                throw new TypeError("cidr object is invalid");
            }
        }

        return cidr;
    }

    function bytesContain(cidrBytes, addressBytes, prefixLength) {
        let remaining = prefixLength;
        for (let i = 0; i < cidrBytes.length && remaining > 0; i++) {
            if (remaining >= 8) {
                if (cidrBytes[i] !== addressBytes[i]) {
                    return false;
                }
                remaining -= 8;
                continue;
            }

            const mask = (0xff << (8 - remaining)) & 0xff;
            return (cidrBytes[i] & mask) === (addressBytes[i] & mask);
        }
        return true;
    }

    function contains(cidr, address) {
        const parsedCIDR = assertCIDRObject(typeof cidr === "string" ? parseCIDR(cidr) : cidr);
        const parsedAddress = parse(address);
        if (parsedCIDR.family !== parsedAddress.family) {
            return false;
        }
        return bytesContain(parsedCIDR.bytes, parsedAddress.bytes, parsedCIDR.prefixLength);
    }

    function normalize(value) {
        return parse(value).normalized;
    }

    Object.defineProperty(globalThis, "EJSIPAddr", {
        configurable: true,
        writable: true,
        value: Object.freeze({
            isValid: isValid,
            isValidIPv4: isValidIPv4,
            isValidIPv6: isValidIPv6,
            isValidCIDR: isValidCIDR,
            parse: parse,
            parseCIDR: parseCIDR,
            contains: contains,
            normalize: normalize
        })
    });
})();
