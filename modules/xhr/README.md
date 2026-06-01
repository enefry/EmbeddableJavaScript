# EJS XHR

`modules/xhr` is an optional embedded `XMLHttpRequest` add-on. It does not
depend on WinterTC and only installs into contexts where the host explicitly
calls `EJSXHRInstallIntoContext`.

Phase 4C currently implements:

- global `XMLHttpRequest` constructor installation;
- async-only `open(method, url[, async])`;
- `setRequestHeader`, `getResponseHeader`, `getAllResponseHeaders`;
- `send()` with `null`/string/`ArrayBuffer`/`ArrayBufferView` body;
- `abort()` terminal behavior;
- `readyState/status/statusText/responseURL/responseText/response`;
- `onreadystatechange/onloadstart/onprogress/onload/onerror/onabort/ontimeout/onloadend`;
- `addEventListener/removeEventListener` for the same event set;
- `responseType`: `""`, `"text"`, `"arraybuffer"`, `"json"`;
- `progress` event payload with bounded `loaded`/`total`/`lengthComputable`;
- `progress` dispatch while `readyState === LOADING`;
- `abort()` resets `readyState` to `UNSENT`, with active requests dispatching
  `abort` then `loadend`;
- `response` shape:
  - `""` / `"text"` -> `string`;
  - `"arraybuffer"` -> `ArrayBuffer` (`responseText === ""`);
  - `"json"` -> parsed JSON value (including `null`).
- invalid JSON in `"json"` mode still observes `OPENED/HEADERS_RECEIVED/LOADING/DONE`
  readyState transitions, then dispatches `error` and `loadend` (no sync throw
  from event dispatch).

Current non-goals in Phase 4C:

- synchronous XHR;
- XML/document response parsing;
- upload progress target and incremental JS streaming progress;
- browser CORS/cookie persistence semantics.

Apple implementation uses a module-owned `NSURLSession` delegate buffering
pipeline with `ejs.network` policy parsing (`capabilities.xhr`, outbound allow
rules, `limits.maxHeaderBytes`, `limits.maxBodyBytes`). Requests are
default-deny unless outbound allow rules explicitly grant them. Response body
limits are enforced during `didReceiveData`; once buffered bytes exceed
`maxBodyBytes`, the provider cancels the task immediately and returns `EPERM`
without waiting for full response download. Default-deny requests that rely on
resolved-address restrictions must use IP-literal URLs; hostname URLs are
allowed only when outbound default allow is enabled and private/link-local
restrictions are not requested. Literal/resolved IPs still pass CIDR/literal-IP
and `denyPrivateNetworks` / `denyLinkLocal` checks before dispatch. System
proxy use is disabled in Phase 4C; `http.useSystemProxy: true` is rejected
because proxy endpoints are not yet part of the network policy model.

## API Shape

```js
const xhr = new XMLHttpRequest();
xhr.open("GET", "https://example.com/data.json");
xhr.responseType = "json";
xhr.onload = () => console.log(xhr.status, xhr.response);
xhr.onerror = () => console.error("request failed");
xhr.send();
```

## Verification

```sh
node --check modules/xhr/js/xhr.js
cmake --build build --target ejs_platform_boundary_check
ctest --test-dir build -R ejs_platform_boundary_test --output-on-failure
```
