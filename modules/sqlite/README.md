# EJS SQLite

`modules/sqlite` is an optional EJS module. Hosts install it explicitly with the Apple entrypoint:

```objc
EJSSQLiteInstallIntoContext(context, &error);
```

The provider module id and context configuration key are both `ejs.sqlite`. Installing the module evaluates the bundled JavaScript facade and exposes `globalThis.EJSSQLite`.

## Policy

JavaScript opens databases by policy name, not by filesystem path:

```json
{
  "version": 1,
  "databases": {
    "main": {
      "path": "/absolute/path/to/app.sqlite",
      "permissions": ["read", "write"],
      "createIfMissing": true
    }
  },
  "limits": {
    "maxRows": 1000,
    "maxStatementBytes": 65536,
    "maxBlobBytes": 1048576
  }
}
```

Database paths must be absolute. `createIfMissing` creates the parent directory and allows SQLite to create the file. If `createIfMissing` is false, the file must already exist.

## API

```js
const db = await EJSSQLite.open("main");
await db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)");
await db.execute("INSERT INTO items (name) VALUES (?)", ["alpha"]);
const rows = await db.query("SELECT id, name FROM items WHERE name = ?", ["alpha"]);
await db.transaction(async (tx) => {
  await tx.execute("INSERT INTO items (name) VALUES (?)", ["beta"]);
});
await db.close();
```

`execute` accepts write statements. `query` accepts read-only statements and returns JSON-compatible row objects keyed by column name. Parameters use SQLite binding and currently support `null`, booleans, finite numbers, and strings. New operations after `close()` reject.

BLOB result columns are represented as `{ "type": "blob", "base64": "..." }` and are limited by `maxBlobBytes`. Binary parameters are deferred in this first pass and are rejected by the JavaScript facade.
