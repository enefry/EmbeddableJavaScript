# third_party

Optional third-party source checkouts and Git submodules live here.

## quickjs-ng

The first engine backend is quickjs-ng. It is tracked as a Git submodule at:

```text
third_party/quickjs-ng/
```

Initialize it with:

```sh
git submodule update --init --recursive
```

Build with:

```sh
cmake -S . -B build -DEJS_ENGINE=quickjs-ng
cmake --build build --target ejs_core
```

To keep dependency source outside this repository, pass:

```sh
cmake -S . -B build -DEJS_ENGINE=quickjs-ng -DEJS_QUICKJS_NG_SOURCE_DIR=/path/to/quickjs-ng
```

Public runtime and host headers must not include quickjs-ng headers directly.
The dependency is private to `core/src`.

EJS intentionally does not add the upstream quickjs-ng CMake project as a
subdirectory for product builds. The `quickjs-ng` backend compiles only the
engine sources needed by `core`:

- `dtoa.c`
- `libregexp.c`
- `libunicode.c`
- `quickjs.c`

Do not link `quickjs-libc.c`, `qjs.c`, `qjsc.c`, `run-test262.c`, or other
quickjs-ng CLI/test targets into EJS products. Those files provide `qjs:std`,
`qjs:os`, process/file helpers, and CLI exit paths that bypass EJS module
boundaries and are not appropriate for Apple app binaries.

## libuv

The first runtime event-loop backend is libuv. It is tracked as a Git submodule
at:

```text
third_party/libuv/
```

Initialize it with:

```sh
git submodule update --init --recursive
```

Build with:

```sh
cmake -S . -B build -DEJS_ENGINE=quickjs-ng -DEJS_RUNTIME_LOOP=libuv
cmake --build build --target ejs_core
```

Public runtime and host headers must not include libuv headers directly. The
dependency is private to `core/src`.
