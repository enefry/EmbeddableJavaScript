# Android Lane C integration notes

This lane intentionally did not modify root `CMakeLists.txt`, shared `tests/CMakeLists.txt`, or root `platform/android`.

## Module Android entry points

- `modules/net/platform/android/java/com/ejs/modules/net/EJSNet.java`
- `modules/xhr/platform/android/java/com/ejs/modules/xhr/EJSXHR.java`
- `modules/ws/platform/android/java/com/ejs/modules/ws/EJSWebSocket.java`
- `modules/fswatch/platform/android/java/com/ejs/modules/fswatch/EJSFSWatch.java`

Each installer registers the Java provider with the existing `EJSContext.registerProvider` bridge and evaluates the existing JS wrapper from a classpath resource:

- `/ejs/modules/net/net.js`
- `/ejs/modules/xhr/xhr.js`
- `/ejs/modules/ws/ws.js`
- `/ejs/modules/fswatch/fswatch.js`

## Mainline integration patch required

The module `CMakeLists.txt` files now expose Android-only custom targets:

- `ejs_net_android_sources`
- `ejs_xhr_android_sources`
- `ejs_ws_android_sources`
- `ejs_fswatch_android_sources`

Each target has:

- `EJS_ANDROID_JAVA_SOURCES`: absolute Java source paths that must be added to the Android/Gradle compile source set.
- `EJS_ANDROID_RESOURCE_DIR`: absolute generated resource root containing the JS wrapper resource path.

Root Android packaging should collect these target properties and add the Java files/resources to the app or AAR packaging. No generic root provider behavior needs to be added.

Root packaging is still intentionally not implemented in this lane. The app/AAR integration layer must collect the module target properties above and package the generated resource roots so `Class.getResourceAsStream("/ejs/modules/...")` can resolve each JS wrapper.

The final Android app manifest must include `android.permission.INTERNET` when `net`, `xhr`, or `ws` are installed. The module providers do not inject manifest permissions by themselves.

## Provider method IDs

- `ejs.net`: `lookup`, `tcpConnect`, `tcpListen`, `tcpAccept`, `tcpRead`, `tcpWrite`, `tcpShutdown`, `tcpClose`, `tcpListenerClose`, `udpBind`, `udpSend`, `udpRecv`, `udpClose`
- `ejs.xhr`: `send`, `abort`
- `ejs.ws`: `connect`, `send`, `close`, `nextEvent`
- `ejs.fswatch`: `watch`, `close`

These match the current JS wrappers.

## Static review notes

- The current generic Android JNI bridge maps Java exceptions to `EJS_ERROR_INTERNAL` only. JS wrappers still get message text, but provider numeric error-code fidelity is lower than Apple until root `platform/android` reflects provider-specific exception metadata.
- `ws` uses a small RFC 6455 client over `Socket`/`SSLSocket` to avoid adding dependencies. It supports text, binary, close, ping/pong, and next-event polling, but it is intentionally not a full browser-grade WebSocket stack.
- `ws` records pending close requests by socket ID before native connect state is registered. If connect later wins the transport race, it does not leave/register/start a live socket and exposes a one-shot close event through `nextEvent`.
- `fswatch` uses Android `FileObserver` and does not support recursive watching, matching the Apple provider's non-recursive constraint. Android callbacks are serialized through a single module executor before dispatching JS. Because the current Android bridge does not expose an owner-runtime-thread dispatch API to this module, there is still residual runtime-thread affinity risk if `EJSContext.evaluateScript` is not safe from that executor.
