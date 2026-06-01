(function() {
    class ReadableStreamDefaultController {
        constructor(stream, startObj) {
            this._stream = stream;
            this._startObj = startObj;
            this._queue = [];
            this._closeRequested = false;
            this._pulling = false;
            this._pullAgain = false;
            this._pendingReads = [];
        }

        get desiredSize() {
            if (this._stream._state === 'errored') {
                return null;
            }
            if (this._closeRequested || this._stream._state === 'closed') {
                return 0;
            }
            return Math.max(0, 1 - this._queue.length);
        }

        enqueue(chunk) {
            if (this._closeRequested) {
                throw new TypeError('Cannot enqueue to a closed stream');
            }
            if (this._pendingReads.length > 0) {
                const pending = this._pendingReads.shift();
                const resolve = pending.resolve;
                resolve({ value: chunk, done: false });
                if (this._pendingReads.length > 0 &&
                    !this._closeRequested &&
                    this._stream._state !== 'errored') {
                    this._pull();
                }
            } else {
                this._queue.push(chunk);
            }
        }

        close() {
            if (this._closeRequested) return;
            this._closeRequested = true;
            this._stream._state = 'closed';
            while (this._pendingReads.length > 0) {
                const pending = this._pendingReads.shift();
                const resolve = pending.resolve;
                resolve({ value: undefined, done: true });
            }
            if (this._stream._reader) {
                this._stream._reader._resolveClosed();
            }
        }

        error(err) {
            this._stream._state = 'errored';
            this._stream._storedError = err;
            while (this._pendingReads.length > 0) {
                const pending = this._pendingReads.shift();
                const reject = pending.reject;
                reject(err);
            }
            if (this._stream._reader) {
                this._stream._reader._rejectClosed(err);
            }
        }

        async _pull() {
            if (this._closeRequested || this._stream._state === 'errored') return;
            if (this._pulling) {
                this._pullAgain = true;
                return;
            }
            if (this._startObj && typeof this._startObj.pull === 'function') {
                this._pulling = true;
                try {
                    await this._startObj.pull(this);
                } catch (err) {
                    this.error(err);
                } finally {
                    this._pulling = false;
                    if (!this._closeRequested &&
                        this._stream._state !== 'errored' &&
                        this._pullAgain) {
                        this._pullAgain = false;
                        this._pull();
                    }
                }
            }
        }
    }

    class ReadableStreamDefaultReader {
        constructor(stream) {
            if (stream._locked) {
                throw new TypeError('Stream is already locked by another reader');
            }
            this._stream = stream;
            stream._locked = true;
            stream._reader = this;
            this._closedSettled = false;
            this._closedPromise = new Promise((resolve, reject) => {
                this._closedResolve = resolve;
                this._closedReject = reject;
            });
            if (stream._state === 'closed') {
                this._resolveClosed();
            } else if (stream._state === 'errored') {
                this._rejectClosed(stream._storedError);
            }
        }

        get closed() {
            return this._closedPromise;
        }

        _resolveClosed() {
            if (this._closedSettled) return;
            this._closedSettled = true;
            this._closedResolve(undefined);
        }

        _rejectClosed(err) {
            if (this._closedSettled) return;
            this._closedSettled = true;
            this._closedReject(err);
        }

        async cancel(reason) {
            if (this._stream == null) {
                throw new TypeError('Reader has no associated stream');
            }
            await this._stream.cancel(reason);
        }

        async read() {
            if (this._stream == null) {
                throw new TypeError('Reader has no associated stream');
            }
            if (this._stream._state === 'errored') {
                throw this._stream._storedError;
            }
            
            const controller = this._stream._controller;
            if (controller._queue.length > 0) {
                const val = controller._queue.shift();
                // Proactively trigger next pull to maintain queue
                controller._pull();
                return { value: val, done: false };
            }
            
            if (controller._closeRequested) {
                return { value: undefined, done: true };
            }

            // No data in queue, create a pending promise and trigger pull
            const p = new Promise((resolve, reject) => {
                controller._pendingReads.push({ resolve, reject, reader: this });
            });
            controller._pull();
            return p;
        }

        releaseLock() {
            if (this._stream) {
                const stream = this._stream;
                const controller = this._stream._controller;
                if (controller && controller._pendingReads.length > 0) {
                    const retained = [];
                    for (const pending of controller._pendingReads) {
                        if (pending.reader === this) {
                            pending.reject(new TypeError('Reader lock released'));
                        } else {
                            retained.push(pending);
                        }
                    }
                    controller._pendingReads = retained;
                }
                if (stream._state === 'readable') {
                    this._rejectClosed(new TypeError('Reader lock released'));
                }
                stream._locked = false;
                if (stream._reader === this) {
                    stream._reader = null;
                }
                this._stream = null;
            }
        }
    }

    class ReadableStream {
        constructor(underlyingSource = {}) {
            this._state = 'readable'; // readable, closed, errored
            this._storedError = undefined;
            this._locked = false;
            this._reader = null;
            this._controller = new ReadableStreamDefaultController(this, underlyingSource);

            // Execute start immediately
            if (typeof underlyingSource.start === 'function') {
                try {
                    underlyingSource.start(this._controller);
                } catch (err) {
                    this._controller.error(err);
                }
            }
        }

        get locked() {
            return this._locked;
        }

        getReader() {
            return new ReadableStreamDefaultReader(this);
        }

        async cancel(reason) {
            this._state = 'closed';
            const controller = this._controller;
            if (controller._startObj && typeof controller._startObj.cancel === 'function') {
                try {
                    await controller._startObj.cancel(reason);
                } catch (err) {
                    controller.error(err);
                    throw err;
                }
            }
            controller.close();
        }
    }

    globalThis.ReadableStream = ReadableStream;
})();
