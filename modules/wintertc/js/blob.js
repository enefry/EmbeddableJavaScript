(function() {
    class Blob {
        constructor(blobParts = [], options = {}) {
            this.type = options.type ? String(options.type).toLowerCase() : '';
            
            // Consolidate parts into a single Uint8Array
            const arrays = [];
            let totalSize = 0;
            
            for (const part of blobParts) {
                if (part instanceof ArrayBuffer) {
                    arrays.push(new Uint8Array(part));
                    totalSize += part.byteLength;
                } else if (ArrayBuffer.isView(part)) {
                    const u8 = new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
                    arrays.push(u8);
                    totalSize += part.byteLength;
                } else if (part instanceof Blob) {
                    arrays.push(part._buffer);
                    totalSize += part.size;
                } else {
                    // String fallback
                    const str = String(part);
                    const encoder = new TextEncoder(); // Use built-in or global fallback
                    const u8 = encoder.encode(str);
                    arrays.push(u8);
                    totalSize += u8.byteLength;
                }
            }

            const consolidated = new Uint8Array(totalSize);
            let offset = 0;
            for (const arr of arrays) {
                consolidated.set(arr, offset);
                offset += arr.length;
            }

            this._buffer = consolidated;
            this.size = totalSize;
        }

        slice(start, end, contentType) {
            let relativeStart = start === undefined ? 0 : Number(start);
            let relativeEnd = end === undefined ? this.size : Number(end);

            if (relativeStart < 0) relativeStart = Math.max(this.size + relativeStart, 0);
            else relativeStart = Math.min(relativeStart, this.size);

            if (relativeEnd < 0) relativeEnd = Math.max(this.size + relativeEnd, 0);
            else relativeEnd = Math.min(relativeEnd, this.size);

            const len = Math.max(relativeEnd - relativeStart, 0);
            const slicedBuffer = this._buffer.slice(relativeStart, relativeStart + len);

            const options = contentType ? { type: contentType } : {};
            const newBlob = new Blob([], options);
            newBlob._buffer = slicedBuffer;
            newBlob.size = slicedBuffer.length;
            return newBlob;
        }

        async arrayBuffer() {
            // Return a copy to ensure immutability
            return this._buffer.buffer.slice(this._buffer.byteOffset, this._buffer.byteOffset + this._buffer.byteLength);
        }

        async text() {
            const decoder = new TextDecoder();
            return decoder.decode(this._buffer);
        }

        stream() {
            const buffer = this._buffer.buffer.slice(this._buffer.byteOffset, this._buffer.byteOffset + this._buffer.byteLength);
            return new ReadableStream({
                start(controller) {
                    if (buffer.byteLength > 0) {
                        controller.enqueue(new Uint8Array(buffer));
                    }
                    controller.close();
                }
            });
        }
    }

    class File extends Blob {
        constructor(fileBits, fileName, options = {}) {
            super(fileBits, options);
            this.name = String(fileName);
            this.lastModified = typeof options.lastModified === 'number' ? options.lastModified : Date.now();
        }
    }

    globalThis.Blob = Blob;
    globalThis.File = File;
})();
