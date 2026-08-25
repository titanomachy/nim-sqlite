# Safety and hardening

This document describes the defensive behavior and verification behind `nim-sqlite`. For installation and everyday use, start with the [README](README.md).

These guarantees reduce common misuse and make failure behavior predictable. They do not turn SQLite into a sandbox: applications remain responsible for access control, database permissions, trusted extension loading, and deciding which SQL users may supply.

## Query and input safety

Values passed as parameters are bound through SQLite rather than interpolated into SQL text. Applications should use positional `?` parameters or named parameters for untrusted values.

Operations intended for one statement validate the complete SQL input before execution:

- Trailing whitespace, extra semicolons, and complete SQLite comments are accepted.
- A second statement, malformed trailing SQL, or an incomplete quoted token or block comment raises `SqliteError` before the first statement executes.
- Empty, whitespace-only, semicolon-only, and comment-only input raises `SqliteError`.

`execScript` is the explicit multi-statement API. Empty and comment-only scripts are no-ops.

SQL text, database paths, and extension paths containing embedded NUL bytes are rejected before reaching SQLite. Embedded NUL bytes remain valid in bound `TEXT` and `BLOB` values.

## Type and size boundaries

SQLite `INTEGER` values are signed 64-bit integers. Binding an ordinal that does not fit that range raises `SqliteError`. Decoding an integer into a narrower Nim integer, range, boolean, character, or enum also checks the target range rather than relying on compiler range-check settings.

Built-in `fromDb` conversions validate the SQLite storage class before reading a value. Text and BLOB operations use SQLite's 64-bit APIs, preserve empty values, and validate reported lengths before allocating Nim memory.

The `changes` operation uses SQLite's 64-bit changes API and returns `int64`.

## Connection and statement lifecycles

A database connection must be closed when no longer needed. Closing finalizes statements held by its internal cache.

Explicit statements created with `stmt` own their SQLite statement handles and must be finalized separately. If their connection is closed first, they become unusable but still require finalization; SQLite releases the underlying connection after the remaining handles are finalized.

Active operations are guarded against destructive reentrancy:

- A connection cannot be closed while one of its operations is binding or executing.
- An explicit statement cannot be reused or finalized during its own bind, execute, iterate, or reset lifecycle.
- Guards are released after success, binding errors, iterator early exits, and exceptions, leaving the handle reusable when appropriate.

The connection-level statement cache leases a cached statement to one operation at a time. Reentrant use of the same SQL receives an independent temporary statement, and cache eviction skips leased or busy statements.

Invalid lifecycle use is treated as a programming error and rejected with `AssertionDefect`. SQLite operational failures are reported as `SqliteError`.

## Execution and transaction failures

`exec`, prepared-statement `exec`, and each statement in `execScript` continue stepping until SQLite reports completion. If a row-producing statement encounters an error after returning one or more rows, the error is still reported and the statement is reset or released.

`transaction` rolls back when an exception escapes. If `COMMIT` fails while SQLite still considers the transaction active, the library attempts a rollback before propagating the original commit error.

`execMany` and `execScript` run their work in transactions when they start outside an existing transaction. A failure aborts and rolls back that work. Nested transaction helpers reuse the active transaction.

Preparation, binding, decoding, parsing, and execution failures clean up or reset their statement handles so failed operations do not poison later queries.

## Verification

The test suite includes focused failure-path checks for connection and statement lifecycles, reentrant conversions, parser failures, range errors, row-producing execution errors, cleanup, and rollback behavior.

CI exercises:

- stable and development Nim on Linux
- stable Nim on macOS and Windows
- normal, release, and danger builds with ORC
- an ARC build
- AddressSanitizer with leak detection
- UndefinedBehaviorSanitizer
- a minimum line-coverage threshold

Release-level behavior changes are recorded in the [changelog](CHANGELOG.md). The implementation history and future hardening work are tracked in the [hardening plan](PLANS/PLAN1-hardening.md).
