(function() {
    class Event {
        constructor(type, options = {}) {
            this.type = String(type);
            this.bubbles = !!options.bubbles;
            this.cancelable = !!options.cancelable;
            this.defaultPrevented = false;
            this.target = null;
            this.currentTarget = null;
            this.timeStamp = Date.now();
        }
        preventDefault() {
            if (this.cancelable) {
                this.defaultPrevented = true;
            }
        }
    }

    class CustomEvent extends Event {
        constructor(type, options = {}) {
            super(type, options);
            this.detail = options.detail === undefined ? null : options.detail;
        }
    }

    class ErrorEvent extends Event {
        constructor(type, options = {}) {
            super(type, options);
            this.message = options.message === undefined ? "" : String(options.message);
            this.filename = options.filename === undefined ? "" : String(options.filename);
            this.lineno = options.lineno === undefined ? 0 : Number(options.lineno);
            this.colno = options.colno === undefined ? 0 : Number(options.colno);
            this.error = options.error;
        }
    }

    class PromiseRejectionEvent extends Event {
        constructor(type, options = {}) {
            super(type, options);
            this.promise = options.promise;
            this.reason = options.reason;
        }
    }

    class EventTarget {
        constructor() {
            this._listeners = new Map();
        }
        addEventListener(type, callback) {
            if (callback === null ||
                (typeof callback !== 'function' &&
                 (typeof callback !== 'object' || typeof callback.handleEvent !== 'function'))) {
                return;
            }
            let list = this._listeners.get(type);
            if (!list) {
                list = [];
                this._listeners.set(type, list);
            }
            if (!list.includes(callback)) {
                list.push(callback);
            }
        }
        removeEventListener(type, callback) {
            const list = this._listeners.get(type);
            if (list) {
                const idx = list.indexOf(callback);
                if (idx !== -1) {
                    list.splice(idx, 1);
                }
            }
        }
        dispatchEvent(event) {
            if (!(event instanceof Event)) {
                throw new TypeError('Argument 1 must be an instance of Event');
            }
            event.target = this;
            event.currentTarget = this;
            
            const list = this._listeners.get(event.type);
            if (list) {
                // Slice list to prevent modifications during dispatch from breaking iterations
                const callers = list.slice();
                for (const cb of callers) {
                    try {
                        if (typeof cb === 'function') {
                            cb.call(this, event);
                        } else {
                            cb.handleEvent(event);
                        }
                    } catch (e) {
                        // Suppress errors during execution to align with spec or output to debug console
                        if (globalThis.console && globalThis.console.error) {
                            globalThis.console.error(e);
                        }
                    }
                }
            }
            
            // Handle on-event properties like signal.onabort
            const onProp = 'on' + event.type;
            if (typeof this[onProp] === 'function') {
                try {
                    this[onProp].call(this, event);
                } catch (e) {
                    if (globalThis.console && globalThis.console.error) {
                        globalThis.console.error(e);
                    }
                }
            }
            
            return !event.defaultPrevented;
        }
    }

    class AbortSignal extends EventTarget {
        constructor() {
            super();
            this.aborted = false;
            this.reason = undefined;
            this.onabort = null;
        }
        static abort(reason) {
            const signal = new AbortSignal();
            signal.aborted = true;
            signal.reason = reason === undefined ? new Error('The operation was aborted.') : reason;
            return signal;
        }
    }

    class AbortController {
        constructor() {
            this.signal = new AbortSignal();
        }
        abort(reason) {
            if (this.signal.aborted) return;
            this.signal.aborted = true;
            this.signal.reason = reason === undefined ? new Error('The operation was aborted.') : reason;
            
            const abortEvent = new Event('abort');
            this.signal.dispatchEvent(abortEvent);
        }
    }

    globalThis.Event = Event;
    globalThis.CustomEvent = CustomEvent;
    globalThis.ErrorEvent = ErrorEvent;
    globalThis.PromiseRejectionEvent = PromiseRejectionEvent;
    globalThis.EventTarget = EventTarget;
    globalThis.AbortSignal = AbortSignal;
    globalThis.AbortController = AbortController;

    const globalEventTarget = new EventTarget();

    function defineGlobalHandler(name) {
        let handler = typeof globalThis[name] === "function" ? globalThis[name] : null;
        Object.defineProperty(globalThis, name, {
            configurable: true,
            enumerable: true,
            get() {
                return handler;
            },
            set(value) {
                handler = value;
                globalEventTarget[name] = value;
            }
        });
        globalEventTarget[name] = handler;
    }

    defineGlobalHandler("onerror");
    defineGlobalHandler("onunhandledrejection");
    defineGlobalHandler("onrejectionhandled");

    globalThis.addEventListener = function(type, callback) {
        return globalEventTarget.addEventListener(type, callback);
    };

    globalThis.removeEventListener = function(type, callback) {
        return globalEventTarget.removeEventListener(type, callback);
    };

    globalThis.dispatchEvent = function(event) {
        return globalEventTarget.dispatchEvent(event);
    };

    globalThis.reportError = function(error) {
        const message = error && error.message !== undefined ? String(error.message) : String(error);
        const event = new ErrorEvent("error", {
            cancelable: true,
            message,
            error
        });
        globalThis.dispatchEvent(event);
    };

    const nativeEvents = globalThis.__ejs_native__ && globalThis.__ejs_native__.events;

    if (nativeEvents) {
        nativeEvents.setPromiseRejectionTracker(function(kind, promise, reason) {
            const type = kind === "handled" ? "rejectionhandled" : "unhandledrejection";
            const event = new PromiseRejectionEvent(type, {
                cancelable: type === "unhandledrejection",
                promise,
                reason
            });
            globalThis.dispatchEvent(event);
        });

        nativeEvents.setExceptionReporter(function(error) {
            globalThis.reportError(error);
        });
    }
})();
