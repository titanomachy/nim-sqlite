# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
This changelog covers changes made after version 0.2.0.

## [Unreleased]

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

[Unreleased]: https://github.com/titanomachy/nim-sqlite/compare/v0.2.0...HEAD
