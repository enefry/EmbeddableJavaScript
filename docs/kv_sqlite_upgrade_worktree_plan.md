# KV SQLite Upgrade Worktree Plan (Minimal Context)

Date: 2026-05-27
Owner: kv/sqlite upgrade worktree

## 1. Goal

Close remaining issues:

- `FR-024`: provider-level head-of-line blocking risk.
- `FR-025`: KV manifest full-read/full-write scalability bottleneck.

Primary strategy:

- Migrate `modules/kv` Apple backend from `manifest.json + value files` to SQLite-backed storage.
- Keep JS API stable (`EJSKV` / `EJSStorage`).

## 2. Scope (Strict)

In scope:

- `modules/kv/platform/apple/src/EJSKeyValueStoreApple.m`
- `modules/kv/README.md`
- `docs/design.md`
- KV-specific tests (`tests/kv/apple/ejs_kv_apple_test.m`)

Out of scope:

- Changing public JS method names/signatures.
- Refactoring unrelated modules (`fs`, `wintertc`, `platform` root).
- Broad performance redesign outside KV.

## 3. Worktree Bootstrap

Use flat branch naming (no nested `codex/...`):

```bash
git fetch origin
git worktree add -b codex-kv-sqlite-upgrade /private/tmp/ejs-kv-sqlite-upgrade HEAD
cd /private/tmp/ejs-kv-sqlite-upgrade
cmake -S . -B build -DEJS_ENGINE=quickjs-ng -DEJS_RUNTIME_LOOP=libuv -DEJS_TEST=ON
```

If submodule/backend path resolution fails in the worktree, configure with explicit source dirs from main checkout.

## 4. Design Constraints

Storage model:

- Per store, one DB file: `<store.path>/kv.sqlite3`.
- Table:
  - `kv_entries(key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL)`.

Safety:

- Keep store path policy checks (absolute path + permission checks).
- SQL only via prepared statements + bound parameters.
- Keep existing size limits (`maxKeyBytes`, `maxValueBytes`, `maxKeysPerList`).
- Add `maxTotalKeys` policy limit (new).

Concurrency:

- WAL mode (`PRAGMA journal_mode=WAL`).
- `busy_timeout` configured.
- Keep deterministic serialization per store (acceptable for first pass).
- Avoid global cross-store lock contention.

## 5. Migration Plan

Phase 0: Design doc update first

- Update KV section in docs to declare SQLite backend and limits.

Phase 1: Introduce SQLite backend

- Add open/init path per store.
- Create schema + indexes (if needed).
- Implement CRUD/keys/clear with transactions.

Phase 2: Compatibility migration

- On first open, detect legacy manifest format.
- Import legacy entries into SQLite transactionally.
- Migration marker to ensure idempotency.
- On migration failure, preserve old data and return explicit error.

Phase 3: Cleanup + docs

- Update module README and design doc to reflect new backend.
- Keep behavior contract for JS unchanged.

## 6. Test Plan (Gate)

Required:

```bash
ctest -R ejs_kv_apple_test --output-on-failure
ctest -R ejs_sqlite_apple_test --output-on-failure
ctest -R "ejs_core_test|ejs_apple_platform_test" --output-on-failure
```

Add/extend KV tests for:

- set/get/delete/has/keys/clear unchanged behavior.
- migration success from legacy manifest.
- migration idempotency.
- invalid/corrupt legacy manifest handling.
- concurrent access from multiple runtimes to same store (no data loss/corruption).
- limit enforcement (`maxValueBytes`, `maxTotalKeys`, `maxKeysPerList`).

## 7. Acceptance Criteria

Must satisfy all:

- `FR-024` and `FR-025` both marked `Fixed` in `docs/fix_plan_from_final_review.md`.
- Public JS API behavior unchanged for existing callers.
- No path-boundary or policy regression.
- Required tests pass in worktree build.

## 8. Commit Strategy

Make small commits per phase:

1. docs/design constraints
2. SQLite backend implementation
3. migration path
4. tests
5. docs + fix plan status update

Do not merge until all gates pass.

## 9. Rollback Strategy

If migration quality is uncertain:

- Keep legacy reader path behind temporary compile/runtime flag in the same branch.
- Merge only after migration tests are stable.

