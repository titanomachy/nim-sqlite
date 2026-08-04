# nim-sqlite

[![CI](https://github.com/titanomachy/nim-sqlite/actions/workflows/main.yml/badge.svg)](https://github.com/titanomachy/nim-sqlite/actions/workflows/main.yml)
[![Coverage](https://titanomachy.github.io/nim-sqlite/coverage.svg)](https://github.com/titanomachy/nim-sqlite/actions)

[Documentation](https://titanomachy.github.io/nim-sqlite/) · [MIT License](LICENSE)

> [!WARNING]
> **Beta Notice:** nim-sqlite is a pre-1.0 package under active development.
> While it is fully functional today, future releases may introduce breaking changes,
> and the public API offers no backward compatibility guarantees.

`nim-sqlite` is a focused, type-safe SQLite library for Nim. It stays close to SQLite instead of presenting a generic database abstraction, while adding:

- safe connection and statement lifecycles
- typed values
- parameter binding
- named parameter binding
- prepared-statement caching
- row unpacking
- transactions

It builds on [nim-sqlite3-abi](https://github.com/arnetheduck/nim-sqlite3-abi), which compiles SQLite's C source into your program. The final host therefore needs neither a separate SQLite installation nor a dynamically linked SQLite library.

## Why nim-sqlite?

`nim-sqlite` is for developers who want SQLite—not an ORM—but want it to feel like a native Nim library. You keep control over your SQL and SQLite behavior while the library handles type conversion, parameter binding, statement reuse, and failure-safe cleanup.

- **Keep SQL as the source of truth.** Write ordinary SQLite queries and use SQLite-specific features directly, without learning a query DSL or fitting your data into an ORM.
- **Keep database values typed.** `DbValue` preserves SQLite's integers, floating-point values, text, blobs, and `NULL`; `fromDb` reports storage-class mismatches instead of silently coercing them.
- **Bind data, not strings.** Pass ordinary Nim values to positional parameters or use named tuples for order-independent binding. Quoting and representation stay out of application code.
- **Fetch exactly what you need.** Stream large results with `iterate`, collect them with `all`, request one row with `one`, or retrieve a single value with `value`.
- **Reuse statements without losing control.** Common queries benefit from automatic prepared-statement caching, while explicit `SqlStatement` values remain available for deliberate reuse.
- **Make failure behavior predictable.** Guarded connection and statement lifecycles catch invalid use, while `transaction`, `execMany`, and `execScript` provide consistent commit and rollback behavior.

## Requirements

- Nim 2.2.10 or newer
- A C compiler supported by Nim

## Installation

Install the current repository with Nimble:

```sh
nimble install https://github.com/titanomachy/nim-sqlite
```

Then import the module as `nim_sqlite`:

```nim
import nim_sqlite
```

## Quick start

This example creates an in-memory database, inserts nullable data with bound parameters, and converts each result row into a typed tuple:

```nim
import nim_sqlite, std/options

let db = openDatabase(":memory:")

try:
  db.execScript("""
    CREATE TABLE person (
      id   INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      age  INTEGER
    );
  """)

  db.exec("INSERT INTO person(name, age) VALUES(?, ?)", "Ada", 36)
  db.exec("INSERT INTO person(name, age) VALUES(?, ?)", "Grace", nil)

  for row in db.iterate("SELECT name, age FROM person ORDER BY id"):
    let (name, age) = row.unpack((string, Option[int]))
    echo name, ": ", age
finally:
  db.close()
```

Output:

```text
Ada: some(36)
Grace: none(int)
```

Always close a connection when it is no longer needed. A `try`/`finally` block is a convenient way to guarantee that cleanup. Closing a connection finalizes the statements in its internal cache. Explicit statements created with `stmt` have their own lifecycle and must be finalized separately.

## Executing SQL safely

Use `exec` for a single SQL statement. Values passed after the SQL string are bound to `?` placeholders and converted to SQLite values:

```nim
db.exec(
  "UPDATE person SET age = ? WHERE name = ?",
  37,
  "Ada"
)

echo db.changes # rows changed by the most recent INSERT, UPDATE, or DELETE
```

Bound parameters handle quoting and data types correctly. Do not build SQL by interpolating untrusted values into the SQL string.
Passing multiple statements to a single-statement operation raises `SqliteError`; use `execScript` for scripts containing several statements.

For order-independent binding, use SQLite `:name` parameters and pass a named tuple. Each tuple field binds the parameter with the same name, regardless of where either one appears:

```nim
let personName = "Ada"
let newAge = 37

db.exec(
  "UPDATE person SET age = :age WHERE name = :name",
  (name: personName, age: newAge) # Deliberately ordered differently from the SQL.
)
```

Named tuples are supported by `exec`, `iterate`, `all`, `one`, and `value`, as well as their prepared-statement counterparts. `execMany` accepts an array or sequence of named tuples. Repeated occurrences of the same parameter, such as `:name = :name`, share one tuple field. Missing parameters, unknown tuple fields, or mixing a named tuple with positional `?` parameters raises `SqliteError`.

Use `execScript` when schema setup or a migration contains several statements. The complete script runs in a transaction:

```nim
db.execScript("""
  CREATE TABLE project (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL
  );

  CREATE INDEX project_name_idx ON project(name);
""")
```

## Reading rows

Choose the query operation based on how much data you need:

```nim
import std/options

# Stream rows without collecting the complete result set.
for row in db.iterate("SELECT id, name FROM person ORDER BY id"):
  let (id, name) = row.unpack((int, string))
  echo id, " ", name

# Collect every row.
let adults = db.all("SELECT name, age FROM person WHERE age >= ?", 18)

# Fetch at most one row.
let ada = db.one("SELECT name, age FROM person WHERE name = ?", "Ada")
if ada.isSome:
  let (name, age) = ada.get.unpack((string, Option[int]))
  echo name, " ", age

# Fetch the first column of the first row.
let count = db.value("SELECT COUNT(*) FROM person").get.fromDb(int)
echo "people: ", count
```

`ResultRow` also supports access by index or unambiguous column name:

```nim
let row = db.one("SELECT id, name FROM person LIMIT 1").get
echo row[0].intVal
echo row["name"].strVal
```

Tuple unpacking is usually preferable because it makes the expected result shape and Nim types explicit.

## Supported values

The built-in conversions are:

| Nim value | SQLite storage class |
| --- | --- |
| Ordinal types such as `int`, `bool`, and enums | `INTEGER` |
| Floating-point types | `REAL` |
| `string` | `TEXT` |
| `seq[byte]` | `BLOB` |
| `Option[T]` or `nil` | `NULL` when empty; otherwise the mapping for `T` |

Use `toDb` to convert a Nim value explicitly and `fromDb` to convert a result. Built-in `fromDb` conversions require the matching SQLite storage class and raise `SqliteError` on a mismatch. You can support application-specific types by defining matching overloads:

```nim
import std/times

proc toDb(value: Time): DbValue =
  DbValue(kind: sqliteInteger, intVal: value.toUnix)

proc fromDb(value: DbValue, _: typedesc[Time]): Time =
  fromUnix(value.fromDb(int))
```

These overloads also allow `Time` values to participate in parameter binding and tuple unpacking. Delegating custom decoding to a built-in `fromDb` conversion preserves storage-class validation.

## Examples

Complete runnable programs are available in the [`examples`](examples) directory:

- [`basic.nim`](examples/basic.nim) covers schema creation, bound parameters, and typed rows.
- [`blobs_and_nulls.nim`](examples/blobs_and_nulls.nim) stores BLOB values and nullable text.
- [`custom_types.nim`](examples/custom_types.nim) adds `toDb` and `fromDb` overloads for `Time`.
- [`named_parameters.nim`](examples/named_parameters.nim) uses named tuples for bulk inserts and filtered queries.
- [`prepared_statements.nim`](examples/prepared_statements.nim) demonstrates explicit statement reuse and cleanup.
- [`transactions.nim`](examples/transactions.nim) implements an atomic account transfer with rollback on failure.

Run an example from the repository root with:

```sh
nim r --path:src examples/basic.nim
```

## Bulk inserts and transactions

`execMany` repeats one statement for several parameter sets and wraps the operation in a transaction:

```nim
let people = [
  (name: "Alan", age: 41),
  (name: "Barbara", age: 29),
  (name: "Edsger", age: 72)
]

db.execMany(
  "INSERT INTO person(name, age) VALUES(:name, :age)",
  people
)
```

Use the `transaction` template when several different operations must succeed or fail together:

```nim
db.transaction:
  db.exec("UPDATE account SET balance = balance - ? WHERE id = ?", 50, 1)
  db.exec("UPDATE account SET balance = balance + ? WHERE id = ?", 50, 2)
```

The transaction commits when the block finishes normally and rolls back when an exception escapes it. If `COMMIT` fails while SQLite still considers the transaction active, the pending changes are rolled back before the commit error is propagated. Nested `transaction` blocks reuse the active transaction.

## Prepared statements and caching

Normal connection methods automatically cache recently prepared SQL statements. The default cache holds 100 statements, so manual statement management is usually unnecessary. Set `cacheSize = 0` when opening a database to disable the cache.

Cached statements are leased to one connection-level operation at a time. If nested or reentrant code executes SQL whose cached statement is already leased or busy, the operation uses a temporary statement and finalizes it afterward. Cache eviction also skips leased and busy statements. This keeps nested queries independent, including when they use the same SQL with different parameters. Explicit statements created with `stmt` are single-use while executing and reject reentrant use.

For explicit reuse, prepare and finalize a statement yourself:

```nim
let insertPerson = db.stmt("INSERT INTO person(name, age) VALUES(?, ?)")

try:
  insertPerson.exec("Donald", 45)
  insertPerson.exec("Frances", 33)
finally:
  insertPerson.finalize()
```

Prepared statements provide the same `exec`, `execMany`, `iterate`, `all`, `one`, and `value` operations as a connection.

An explicit statement owns its underlying SQLite statement handle. Closing its database connection makes the statement unusable for further execution, but does not finalize that handle. The statement must still be finalized afterward:

```nim
let statement = db.stmt("SELECT name FROM person")

db.close()
doAssert not statement.isAlive
statement.finalize() # Safe and required after the connection is closed.
```

Connection shutdown uses SQLite's deferred-close behavior. SQLite releases the underlying connection after all explicit statements have been finalized. Prefer finalizing statements before closing their connection when practical; post-close finalization exists to make cleanup ordering safe.

## Opening modes

```nim
let memoryDb = openDatabase(":memory:")
let writableDb = openDatabase("application.db")             # dbReadWrite
let readonlyDb = openDatabase("application.db", dbRead)     # must already exist
```

`dbReadWrite` is the default and creates the database file when necessary. `dbRead` opens an existing database without write access. Each opened connection must eventually be closed, and each explicit prepared statement must eventually be finalized.

SQLite failures raise `SqliteError`. Programming errors such as using a closed connection or a finalized statement are detected with assertions.

## Documentation

The complete generated API reference is published at:

**https://titanomachy.github.io/nim-sqlite/**

To build the same documentation locally:

```sh
nimble docs
```

Then open `docs/index.html` in a browser.

## Development

Run the test suite with:

```sh
nimble test -Y
```

The tests cover connection lifecycle, queries, transactions, prepared statements, caching, type conversion, extensions, and foreign keys.

Run all examples with:

```sh
nimble examples -Y
```

To generate the line coverage report and badge, install `lcov` and `genhtml`, then run:

```sh
nimble coverage
```

The HTML report is written to `coverage_html/index.html`, and the generated badge is written to `docs/coverage.svg`. CI enforces at least 80% line coverage and publishes the badge with the API documentation.

## License and attribution

`nim-sqlite` is an [MIT-licensed](LICENSE) fork of [tiny_sqlite](https://github.com/GULPF/tiny_sqlite), created by [Oscar Nihlgård](https://github.com/GULPF).
