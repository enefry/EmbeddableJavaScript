# SQLite Tests

`tests/sqlite/apple/ejs_sqlite_apple_test.m` validates the optional Apple SQLite module:

- explicit install and `ejs.sqlite` policy parsing
- opening databases by configured policy name
- parameter-bound execute/query calls
- transaction commit and rollback
- close behavior
- unsupported database names
- read-only write rejection
- row limits

Run the focused test with:

```sh
cmake --build build --target ejs_sqlite_apple_test
./build/tests/ejs_sqlite_apple_test
```
