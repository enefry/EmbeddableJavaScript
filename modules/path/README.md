# EJSPath

`modules/path` is an optional pure-JavaScript POSIX path helper package. It is
not part of WinterTC and does not access the file system.

Dependency direction:

```text
Application
  -> ejs_path_apple
  -> ejs_apple_platform
  -> ejs_core
```

## Apple Installation

```objc
#import "EJSPathApple.h"

NSError *error = nil;
EJSContext *context = [runtime createContextWithID:@"app://main" error:&error];

if (!EJSPathInstallIntoContext(context, &error)) {
  // handle install failure
}
```

The installer evaluates the bundled JavaScript wrapper and exposes
`globalThis.EJSPath`.

## JavaScript API

```js
EJSPath.posix.normalize("profiles/../avatar.png");
EJSPath.posix.join("profiles", "active", "avatar.png");
EJSPath.posix.dirname("profiles/active/avatar.png");
EJSPath.posix.basename("profiles/active/avatar.png", ".png");
EJSPath.posix.extname("profiles/active/avatar.png");
EJSPath.posix.isAbsolute("/profiles");
EJSPath.posix.relative("profiles/active", "profiles/archive/item.json");
EJSPath.posix.resolve("profiles", "../archive");
EJSPath.posix.parse("/profiles/active/avatar.png");
EJSPath.posix.format({ dir: "/profiles/active", name: "avatar", ext: ".png" });
```

Only POSIX string semantics are implemented. There is no Windows mode, URL
mode, realpath lookup, symlink handling, or native separator inference.

## Verification

```sh
node --check modules/path/js/path.js
cmake --build build --target ejs_path_apple_test
./build/tests/ejs_path_apple_test
```
