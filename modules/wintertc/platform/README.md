# WinterTC Platform

This directory is owned by the `modules/wintertc` optional module. It contains
provider adapters that are registered through the generic platform facade.

Root `platform/*` stays independent from WinterTC. The dependency direction is
WinterTC to platform to core.

## Current Apple Provider Contracts

The current Apple add-on can register default providers when
`EJSWinterTCInstallOptions.installDefaultProviders` is enabled.

### `wintertc.clock`

Sync methods:

- `now`

Payload is ignored. Result is UTF-8 JSON:

```json
{"timeOriginEpochMs": 1770000000000, "nowMs": 1.25}
```

### `wintertc.crypto`

Sync methods:

- `getRandomValues`

Payload:

```json
{"byteLength": 32}
```

Result is raw random bytes. The provider rejects negative lengths and lengths
above 65536.

Async methods:

- `digest`

Payload:

```json
{"algorithm": "SHA-256"}
```

The transfer buffer contains the input bytes. Supported algorithms are
`SHA-256`, `SHA-384`, and `SHA-512`. Result is raw digest bytes.

### `wintertc.console`

Async methods:

- `write`

Payload:

```json
{"level": "log", "args": ["message"]}
```

The current Apple provider logs through `NSLog` and resolves with:

```json
{"ok": true}
```

### `wintertc.fetch`

Async methods:

- `start`
- `pull`
- `cancel`

`start` payload:

```json
{
  "url": "https://example.test/resource",
  "method": "POST",
  "headers": [["content-type", "text/plain"]],
  "bodyKind": "bytes"
}
```

The transfer buffer contains the request body bytes when `bodyKind` is
`"bytes"`. The default Apple provider supports `data:`, `http:`, and `https:`
URLs. It returns UTF-8 JSON:

```json
{"streamId":"uuid","status":200,"statusText":"OK","headers":{"content-type":"text/plain"}}
```

`pull` payload:

```json
{"bodyStreamId": "uuid", "maxBytes": 65536}
```

Result framing:

- first byte `0x01`: remaining bytes are a body chunk
- first byte `0x00`: body stream is complete

`cancel` payload:

```json
{"bodyStreamId": "uuid", "reason": "consumer canceled"}
```

Cancellation removes buffered stream state and resolves with:

```json
{"ok": true}
```

## Deferred Providers

Compression, file, storage, permissions, and other provider families are not
implemented in this source tree.
