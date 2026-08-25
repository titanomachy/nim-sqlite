# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
This changelog covers changes made after version 0.2.0.

## [Unreleased]

### Added

- Add savepoint-backed nested `transaction` blocks so caught inner failures roll back only their own work.
- Add `TransactionMode.deferred`, `TransactionMode.immediate`, and `TransactionMode.exclusive` for outermost transactions.
- Add structured `SqliteError` metadata with primary and extended SQLite result codes, a stable `SqliteOperation` category, and SQLite's diagnostic message.
- Add the catchable `SqliteUsageError` for invalid connection and statement lifecycle state.
- Add `OpenOptions` with separate read-only, read-write-existing, and read-write-create modes, statement-cache sizing, a busy timeout, URI filename interpretation, symbolic-link rejection, and normal or hardened security profiles.

### Changed

- Recover from commit and savepoint-release failures with rollback cleanup, preserving the original exception and exposing secondary cleanup failures through its `parent` chain.
- Treat `transaction` inside a manually started SQL transaction as a savepoint scope without taking ownership of the outer transaction.
- **Breaking:** Report public lifecycle misuse with `SqliteUsageError` instead of `AssertionDefect`.
- Keep SQL text and bound parameter values out of exception fields and messages, including rejected numeric values; library-side validation errors use zero result codes and an empty SQLite message.
- Preserve the convenience `openDatabase` overload and its create-if-missing, 100-entry-cache defaults while routing it through the explicit options implementation.

## [0.4.0] - 2026-08-25

### Added

- Add a pinned Linux hardening matrix covering normal, release, and danger ORC builds, ARC, AddressSanitizer, and UndefinedBehaviorSanitizer.
- Add focused failure-path regressions that verify prepared handles return to their expected baseline after lifecycle, binding, decoding, parser, and execution errors.
- Add a dedicated safety and hardening guide, keeping the README focused on everyday library use.

### Changed

- **Breaking:** Return `int64` from `changes` via SQLite's 64-bit changes API, and return the requested floating-point type from `fromDb` rather than always returning `float64`.

### Fixed

- Reject ordinal values that do not fit SQLite's signed 64-bit `INTEGER` or the requested Nim ordinal type, independently of compiler range-check settings.
- Use SQLite's 64-bit text and BLOB binding APIs while preserving empty BLOBs, validate column byte counts before Nim allocation, and avoid narrowing SQL lengths to `cint`.
- Guard active connection and explicit-statement operations against destructive reentrancy. Closing a connection, or finalizing or reusing an explicit statement, is now rejected for the complete bind/execute/reset lifecycle, including user-defined named-parameter conversions.
- Restore connection and statement operation state after binding errors, iterator early exits, and exceptional exits so handles remain safe and reusable.
- Drive `exec`, prepared-statement `exec`, and every statement in `execScript` through `SQLITE_DONE`, ensuring errors that occur after an initial result row are reported and cleaned up.
- Replace the unbounded trailing-SQL comment scanner with SQLite-driven parsing. Bare line comments and other non-SQL tails are accepted safely, while incomplete or invalid tails fail before a single-statement operation executes.
- Reject empty and non-statement input in single-statement operations with a clear `SqliteError`, while preserving `execScript` no-op behavior for empty and comment-only scripts.
- Reject embedded NUL bytes in SQL, database paths, and extension paths before passing them to SQLite, while continuing to preserve NUL bytes in bound `TEXT` and `BLOB` values.

## [0.3.0] - 2026-08-04

### Added

- Add named SQLite parameter binding through named tuples for connection and prepared-statement operations, including bulk inserts with `execMany`.
- Add runnable examples for basic usage, BLOB and NULL values, custom type conversions, named parameters, prepared statements, and transactions.
- Add local and CI line-coverage reporting with an automatically published coverage badge.
- Publish the generated API documentation automatically through GitHub Pages.

### Changed

- **Breaking:** Rename the package and import module from `tiny_sqlite` to `nim_sqlite`.
- **Breaking:** Rename `toDbValue` and `fromDbValue` to `toDb` and `fromDb`, and remove the `toDbValues` helper.
- **Breaking:** Require Nim 2.2.10 or newer.
- **Breaking:** Use the `sqlite3_abi` package for the bundled SQLite C API; `unsafeHandle` now returns a `ptr sqlite3_abi.sqlite3`.
- Reject trailing SQL statements in single-statement operations with `SqliteError`; use `execScript` for multi-statement SQL.
- Validate the SQLite storage class in built-in `fromDb` conversions and raise `SqliteError` when it does not match the requested Nim type.
- Treat empty, whitespace-only, semicolon-only, and comment-only input as a successful no-op in `execScript`.

### Fixed

- Prevent closing a database from leaving dangling explicit statement handles.
- Prevent cached statements from being reused or evicted while they are executing, including during nested and reentrant queries.
- Reject `loadExtension` on a closed connection instead of dereferencing a nil SQLite handle.
- Release SQLite handles and prepared statements when database opening, statement preparation, or parameter binding fails.
- Roll back an active transaction when `COMMIT` fails, while preserving the original commit error.
- Preserve embedded NUL bytes when reading SQLite `TEXT` values.

[Unreleased]: https://github.com/titanomachy/nim-sqlite/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/titanomachy/nim-sqlite/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/titanomachy/nim-sqlite/compare/v0.2.0...v0.3.0
