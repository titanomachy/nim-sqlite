# Safety and hardening

This document describes the defensive behavior and verification behind `nim-sqlite`. For installation and everyday use, start with the [README](README.md).

These guarantees reduce common misuse and make failure behavior predictable. They do not turn SQLite into a sandbox: applications remain responsible for access control, database permissions, trusted extension loading, and deciding which SQL users may supply.

## Query and input safety

Values passed as parameters are bound through SQLite rather than interpolated into SQL text. Applications should use positional `?` parameters or named parameters for untrusted values.

Operations intended for one statement validate the complete SQL input before execution:

- Trailing whitespace, extra semicolons, and complete SQLite comments are accepted.
- A second statement, malformed trailing SQL, or an incomplete quoted token or block comment raises `SqliteError` before the first statement executes.
- Empty, whitespace-only, semicolon-only, and comment-only input raises `SqliteError`.

`execScript` is the explicit multi-statement API. Empty and comment-only scripts are no-ops. Explicit `BEGIN`, `COMMIT`, `END`, `ROLLBACK`, `SAVEPOINT`, and `RELEASE` statements are rejected so a script cannot escape or invalidate the transaction protecting its work. Use `exec` when transaction control must be managed manually.

SQL text, database paths, and extension paths containing embedded NUL bytes are rejected before reaching SQLite. Embedded NUL bytes remain valid in bound `TEXT` and `BLOB` values.

## Type and size boundaries

SQLite `INTEGER` values are signed 64-bit integers. Binding an ordinal that does not fit that range raises `SqliteError`. Decoding an integer into a narrower Nim integer, range, boolean, character, or enum also checks the target range rather than relying on compiler range-check settings.

Built-in `fromDb` conversions validate the SQLite storage class before reading a value. Text and BLOB operations use SQLite's 64-bit APIs, preserve empty values, and validate reported lengths before allocating Nim memory.

The `changes` operation uses SQLite's 64-bit changes API and returns `int64`.

## Error handling and sensitive data

`SqliteError` exposes stable machine-readable fields:

- `primaryCode` is SQLite's primary result code.
- `extendedCode` distinguishes cases such as unique and foreign-key constraints.
- `operation` is a `SqliteOperation` category describing where the failure occurred.
- `sqliteMessage` is SQLite's own diagnostic message.

For errors produced by library-side validation or conversion, both result codes are
`SQLITE_OK` (zero) and `sqliteMessage` is empty. The ordinary exception `msg`
remains suitable for logs and human-readable diagnostics.

The library does not attach SQL text or bound parameter values to exceptions.
SQLite's own diagnostic can identify schema objects or SQL tokens, so applications
should still apply their normal policy for protecting logs. In particular, avoid
putting secrets in SQL literals; bind them as parameters.

Invalid public handle state raises the catchable `SqliteUsageError`. This includes
using a closed connection, using a finalized statement, reusing an active explicit
statement, and closing or finalizing a handle during one of its active operations.
Internal invariant failures remain defects.

## Connection opening and lock handling

The compatibility `openDatabase(path, mode, cacheSize)` overload retains its
existing behavior: `dbReadWrite` opens or creates the main database,
`dbRead` requires an existing database, the statement cache holds up to 100
entries by default, URI interpretation is not requested, and no busy timeout is
installed.

The `OpenOptions` overload separates the file modes:

- `OpenMode.readOnly` requires an existing database and prevents writes.
- `OpenMode.readWriteExisting` requires an existing database and prevents a
  misspelled path from creating an empty one. SQLite may still fall back to
  read-only access if operating-system permissions prevent writing, so inspect
  `isReadonly` when writable access is mandatory.
- `OpenMode.readWriteCreate` opens or creates the database.

Start with `defaultOpenOptions` when changing selected fields. A directly
zero-initialized `OpenOptions` value has a zero-entry statement cache, whereas
`defaultOpenOptions` and the compatibility overload use 100 entries.

`busyTimeoutMs` installs SQLite's single per-connection busy handler. It allows
SQLite to sleep and retry during ordinary lock contention until the configured
sleep budget is reached. SQLite can still return `SQLITE_BUSY` earlier when
invoking the handler could contribute to a deadlock. Zero disables the timeout,
and negative values or values outside SQLite's signed `cint` range are rejected
before a connection is allocated.

`uriFilename` requests SQLite URI filename interpretation. URI parameters can
select a VFS or change access, cache, locking, and immutable-file behavior. Only
enable it for intentionally constructed `file:` URIs, and do not append
untrusted query parameters. A URI `mode` may make `OpenOptions.mode` more
restrictive, but SQLite rejects a URI that attempts to make it less restrictive.

`noFollow` passes `SQLITE_OPEN_NOFOLLOW`, causing database paths containing a
symbolic link to be rejected. It is opt-in because existing deployments may
intentionally use symlinked paths.

`SecurityProfile.hardened` enables `SQLITE_DBCONFIG_DEFENSIVE` and disables
`SQLITE_DBCONFIG_TRUSTED_SCHEMA` before the library executes initialization SQL.
The library passes SQLite's exact C ABI types to these variadic configuration
operations and verifies the effective setting reported by SQLite.
This prevents ordinary SQL from enabling features intended to modify SQLite's
internal schema representation and prevents non-innocuous application functions
or virtual tables from being invoked indirectly by schema objects. It can reject
legitimate databases relying on those compatibility behaviors.

The hardened profile is an additional defense, not a sandbox or integrity check.
It does not impose application-specific resource limits, disable triggers, views,
or attachment, validate an untrusted database file, or authorize user-supplied
SQL. The library also does not silently enable WAL or change synchronous or
journal durability settings; those remain application policy.

## Connection and statement lifecycles

A database connection must be closed when no longer needed. Closing finalizes statements held by its internal cache.

Explicit statements created with `stmt` own their SQLite statement handles and must be finalized separately. If their connection is closed first, they become unusable but still require finalization; SQLite releases the underlying connection after the remaining handles are finalized.

Active operations are guarded against destructive reentrancy:

- A connection cannot be closed while one of its operations is binding or executing.
- An explicit statement cannot be reused or finalized during its own bind, execute, iterate, or reset lifecycle.
- Guards are released after success, binding errors, iterator early exits, and exceptions, leaving the handle reusable when appropriate.

The connection-level statement cache leases a cached statement to one operation at a time. Reentrant use of the same SQL receives an independent temporary statement, and cache eviction skips leased or busy statements.

Invalid lifecycle use is reported as `SqliteUsageError`. SQLite operational and
library validation failures are reported as `SqliteError`.

## Execution and transaction failures

`exec`, prepared-statement `exec`, and each statement in `execScript` continue stepping until SQLite reports completion. If a row-producing statement encounters an error after returning one or more rows, the error is still reported and the statement is reset or released.

`transaction` rolls back when an exception escapes. Nested transaction blocks use uniquely named SQLite savepoints. A caught inner failure therefore rolls back only the inner block, while a failure escaping the outer block rolls back the full transaction.

Outermost transactions default to `TransactionMode.deferred`. `TransactionMode.immediate` and `TransactionMode.exclusive` select SQLite's corresponding `BEGIN` modes. A nested block always inherits the surrounding transaction's mode because SQLite savepoints do not acquire a separate transaction mode.

If `COMMIT` or a nested `RELEASE` fails while SQLite still considers a transaction active, the library attempts rollback cleanup before propagating the original failure. A savepoint cleanup failure causes a full transaction rollback because the narrower boundary can no longer be trusted. If one or more cleanup attempts also fail, the original body, commit, or release exception remains the exception observed by the caller and every cleanup exception remains available through Nim's `error.parent` chain in failure order. A failure of the final full rollback can leave SQLite's transaction active; callers can inspect `isInTransaction` before deciding whether to retry rollback or discard the connection.

Transactions and savepoints started manually with SQL remain owned by the caller. Entering `transaction` while SQLite is already in a transaction creates a savepoint; success releases that savepoint without committing the manual transaction, and ordinary failure rolls back only to that savepoint. The requested `TransactionMode` has no effect in this case. Do not manually commit, roll back, or release the active transaction/savepoint from inside a `transaction` block, because doing so invalidates the scope that the template must finish.

`execMany` and `execScript` start an outer transaction when needed and use a savepoint when a transaction is already active. A failure aborts and rolls back their own work without silently committing partial changes into a surrounding scope. `execScript` rejects explicit transaction-control statements before executing them because those statements could otherwise invalidate the managed transaction and make rollback impossible.

Preparation, binding, decoding, parsing, and execution failures clean up or reset their statement handles so failed operations do not poison later queries.

## Verification

The test suite includes focused failure-path checks for structured primary and
extended result codes, error categories, sensitive bound values, connection and
statement lifecycles, reentrant conversions, parser failures, range errors,
open modes, busy lock contention, URI filenames, symbolic-link rejection,
hardened connection settings and ABI-safe configuration, row-producing execution
errors, transaction-control rejection, nested savepoints, transaction modes,
complete cleanup exception chains, and rollback behavior.

CI exercises:

- stable and development Nim on Linux
- stable Nim on macOS and Windows
- normal, release, and danger builds with ORC
- an ARC build
- AddressSanitizer with leak detection
- UndefinedBehaviorSanitizer
- a minimum line-coverage threshold

Release-level behavior changes are recorded in the [changelog](CHANGELOG.md).
