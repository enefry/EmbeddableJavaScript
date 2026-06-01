(function() {
    class SubtleCrypto {
        async digest(algorithm, data) {
            const nativeInvoke = globalThis.__ejs_native__ && globalThis.__ejs_native__.invoke;
            if (!nativeInvoke) {
                throw new Error('EJS native core dispatcher is not available.');
            }

            let algoName = '';
            if (typeof algorithm === 'string') {
                algoName = algorithm;
            } else if (algorithm && typeof algorithm === 'object') {
                algoName = algorithm.name || '';
            }

            algoName = algoName.toUpperCase();

            // Support both ArrayBuffer and TypedArray as inputs
            let binaryData = data;
            if (ArrayBuffer.isView(data)) {
                binaryData = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
            }

            const resultBuffer = await nativeInvoke("wintertc.crypto", "digest", JSON.stringify({
                algorithm: algoName
            }), binaryData);

            return resultBuffer;
        }

        // Placeholders for encrypt / decrypt, which will be dispatched to Platform Providers if needed
        async encrypt(algorithm, key, data) { throw new Error('Not implemented yet'); }
        async decrypt(algorithm, key, data) { throw new Error('Not implemented yet'); }
    }

    const crypto = {
        getRandomValues(typedArray) {
            const validConstructors = [
                Int8Array,
                Uint8Array,
                Uint8ClampedArray,
                Int16Array,
                Uint16Array,
                Int32Array,
                Uint32Array
            ];
            if (typeof BigInt64Array === "function" && typeof BigUint64Array === "function") {
                validConstructors.push(BigInt64Array, BigUint64Array);
            }

            if (!validConstructors.some(function(ctor) { return typedArray instanceof ctor; })) {
                throw new TypeError('Argument 1 must be an integer ArrayBufferView');
            }

            if (typedArray.byteLength > 65536) {
                throw new RangeError('getRandomValues byteLength exceeds 65536');
            }

            const nativeInvokeSync = globalThis.__ejs_native__ && globalThis.__ejs_native__.invokeSync;
            if (typeof nativeInvokeSync !== 'function') {
                throw new Error('EJS native sync dispatcher is not available.');
            }

            const randomBytes = nativeInvokeSync('wintertc.crypto', 'getRandomValues', JSON.stringify({
                byteLength: typedArray.byteLength
            }), null);
            if (!randomBytes || randomBytes.byteLength !== typedArray.byteLength) {
                throw new Error('wintertc.crypto.getRandomValues returned invalid byte length.');
            }
            const randomView = new Uint8Array(randomBytes);
            new Uint8Array(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength).set(randomView);
            return typedArray;
        },

        randomUUID() {
            const bytes = new Uint8Array(16);
            crypto.getRandomValues(bytes);
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            const hex = Array.from(bytes, function(byte) {
                return byte.toString(16).padStart(2, '0');
            });
            return (
                hex.slice(0, 4).join('') + '-' +
                hex.slice(4, 6).join('') + '-' +
                hex.slice(6, 8).join('') + '-' +
                hex.slice(8, 10).join('') + '-' +
                hex.slice(10, 16).join('')
            );
        },

        subtle: new SubtleCrypto()
    };

    globalThis.crypto = crypto;
})();
