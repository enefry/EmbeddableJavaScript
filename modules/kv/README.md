# EJSKV

`modules/kv` is an optional persistent key-value package. It is not part of
WinterTC and is not auto-installed by root `platform/apple`.

Dependency direction:

```text
Application
  -> ejs_kv_apple
  -> ejs_apple_platform
  -> ejs_core
```

## Apple Installation

Consumers configure policy through the generic context configuration channel and
then install EJSKV into that context:

```objc
#import "EJSKeyValueStoreApple.h"

EJSRuntimeConfiguration *runtimeConfig = [[EJSRuntimeConfiguration alloc] init];
runtimeConfig.contextDefaults = @{
  EJSKeyValueStoreConfigurationKey: kvConfigJSON
};

EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:runtimeConfig];
EJSContext *context = [runtime createContextWithID:@"app://main" error:&error];

if (!EJSKeyValueStoreInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The installer reads `EJSKeyValueStoreConfigurationKey` (`"ejs.kv"`), parses the
JSON policy once, registers the `ejs.kv` provider, and evaluates the bundled
JavaScript wrappers for both `EJSKV` and `EJSStorage`.

## JavaScript API

```js
await EJSKV.set("profile", "hello");
const bytes = await EJSKV.get("profile");

await EJSKV.set("avatar", new Uint8Array([1, 2, 3]));
const hasAvatar = await EJSKV.has("avatar");
const keys = await EJSKV.keys();

await EJSKV.setJSON("settings", { theme: "dark" });
const settings = await EJSKV.getJSON("settings");
await EJSKV.delete("avatar");
await EJSKV.clear();
```

`get` resolves to an `ArrayBuffer` or `null`. `set` accepts a string,
`ArrayBuffer`, or `ArrayBufferView`. JSON helpers serialize and parse in
JavaScript.

`EJSStorage` is a pure JavaScript facade over `EJSKV` and is installed by the
same KV package entrypoint:

```js
await EJSStorage.local.setItem("name", "Ada");
const name = await EJSStorage.local.getItem("name");
const firstKey = await EJSStorage.local.key(0);
const count = await EJSStorage.local.length();
await EJSStorage.local.removeItem("name");
await EJSStorage.local.clear();

await EJSStorage.json.set("settings", { theme: "dark" });
const settings = await EJSStorage.json.get("settings");
await EJSStorage.json.remove("settings");
```

Storage values are string-only through `local` and structured through `json`.
All storage operations remain asynchronous because they delegate to `EJSKV`.

Store names come from native policy. Omit `options.store` to use
`defaultStore`, or pass a configured store name:

```js
await EJSKV.set("token", "abc", { store: "secure" });
```

## Policy Schema

The policy is a JSON string stored under `EJSKeyValueStoreConfigurationKey`
(`"ejs.kv"`):

```json
{
  "version": 1,
  "defaultStore": "default",
  "stores": {
    "default": {
      "path": "/app/Library/Application Support/ejs/kv/default",
      "permissions": ["read", "write"],
      "createIfMissing": true
    }
  },
  "limits": {
    "maxKeyBytes": 512,
    "maxValueBytes": 1048576,
    "maxKeysPerList": 1000
  }
}
```

The Apple backend stores each configured store in `<store.path>/kv.sqlite3`
using SQLite WAL mode. Values live in `kv_entries(key TEXT PRIMARY KEY, value
BLOB NOT NULL, updated_at INTEGER NOT NULL)`. The provider serializes
operations per store while allowing different stores to progress independently.
There is no manifest compatibility path because this backend has not shipped yet.
