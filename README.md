# nim-sqlite

[![CI](https://github.com/titanomachy/nim-sqlite/actions/workflows/main.yml/badge.svg)](https://github.com/titanomachy/nim-sqlite/actions/workflows/main.yml)
[![Coverage](https://titanomachy.github.io/nim-sqlite/coverage.svg)](https://github.com/titanomachy/nim-sqlite/actions)

[Documentation](https://titanomachy.github.io/nim-sqlite/) · [Examples](examples) · [Safety and hardening](SAFETY.md) · [MIT License](LICENSE)

`nim-sqlite` is a small, type-safe SQLite library for Nim. You write ordinary SQL and work with familiar Nim values; the library handles binding, result conversion, prepared statements, and transactions.

SQLite is compiled into your program through [nim-sqlite3-abi](https://github.com/arnetheduck/nim-sqlite3-abi), so the finished application does not need a separate SQLite installation.

> `nim-sqlite` is pre-1.0 software. It is ready to use, but releases may still include breaking API changes.

## Installation

`nim-sqlite` requires Nim 2.2.10 or newer and a C compiler supported by Nim.

```sh
nimble install nim_sqlite
```

Then import it as:

```nim
import nim_sqlite
```

## Quick start

This example creates an in-memory database, inserts two rows, and reads them back as Nim values:

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

```text
Ada: some(36)
Grace: none(int)
```

Close each database when you finish with it. A `try`/`finally` block is a convenient way to make cleanup unconditional.

## Handling errors

SQLite and validation failures raise `SqliteError`. Its `primaryCode`,
`extendedCode`, `operation`, and `sqliteMessage` fields allow handling failures
without parsing exception text. Extended codes distinguish cases such as unique
and foreign-key constraint failures:

```nim
from nim_sqlite/sqlite3_abi as sqlite import nil

db.exec("CREATE UNIQUE INDEX person_name ON person(name)")
try:
  db.exec("INSERT INTO person(name) VALUES(?)", "Ada")
except SqliteError as error:
  if error.extendedCode == int32(sqlite.SQLITE_CONSTRAINT_UNIQUE):
    echo "name already exists"
  else:
    raise
```

Invalid handle state, such as using a closed connection or finalized statement,
raises the catchable `SqliteUsageError`. `nim-sqlite` never attaches bound
parameter values or the submitted SQL text to exceptions. See
[Safety and hardening](SAFETY.md) for the complete error and logging contract.

## Binding values

Pass Nim values after the SQL string to bind positional `?` parameters:

```nim
db.exec(
  "UPDATE person SET age = ? WHERE name = ?",
  37,
  "Ada"
)
```

Named parameters use a named tuple. Tuple fields are matched by name, so their order does not matter:

```nim
db.exec(
  "UPDATE person SET age = :age WHERE name = :name",
  (name: "Ada", age: 37)
)
```

Use `execScript` for schema setup, migrations, and other multi-statement scripts.

## Reading rows

Choose a query operation based on how many rows you need:

```nim
# Stream rows one at a time.
for row in db.iterate("SELECT id, name FROM person ORDER BY id"):
  let (id, name) = row.unpack((int, string))
  echo id, " ", name

# Collect all rows.
let adults = db.all("SELECT name, age FROM person WHERE age >= ?", 18)

# Fetch at most one row.
let ada = db.one("SELECT name, age FROM person WHERE name = ?", "Ada")

# Fetch the first value from the first row.
let count = db.value("SELECT COUNT(*) FROM person")
```

Rows contain `DbValue` values and support access by position or column name. Use `row.unpack(...)` when you want a typed tuple.

## Transactions and bulk operations

`transaction` commits when the block finishes and rolls back if an exception escapes.
Nested blocks use SQLite savepoints, so a caught inner failure rolls back only the
inner block:

```nim
db.transaction:
  db.exec("UPDATE account SET balance = balance - ? WHERE id = ?", 50, 1)
  try:
    db.transaction:
      db.exec("UPDATE account SET balance = balance + ? WHERE id = ?", 50, 2)
      raise newException(ValueError, "cancel credit")
  except ValueError:
    discard
```

The default mode is `TransactionMode.deferred`. Pass `TransactionMode.immediate`
or `TransactionMode.exclusive` when the outermost transaction should acquire its
SQLite lock earlier:

```nim
db.transaction(TransactionMode.immediate):
  db.exec("UPDATE account SET balance = balance - ? WHERE id = ?", 50, 1)
```

If a transaction was started manually with SQL, `transaction` creates a savepoint
and leaves the manual transaction open for its caller to commit or roll back.
See [Safety and hardening](SAFETY.md) for the detailed cleanup contract.

`execMany` binds several parameter sets to the same statement in one transaction:

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

## Prepared statements

Connection operations cache commonly used statements automatically. For explicit reuse, create a statement with `stmt` and finalize it when finished:

```nim
let insertPerson = db.stmt("INSERT INTO person(name, age) VALUES(?, ?)")

try:
  insertPerson.exec("Donald", 45)
  insertPerson.exec("Frances", 33)
finally:
  insertPerson.finalize()
```

Prepared statements provide the same `exec`, `execMany`, `iterate`, `all`, `one`, and `value` operations as a connection.

## Values and custom types

The built-in mappings cover Nim ordinal and floating-point types, `string`, `seq[byte]`, `Option[T]`, and `nil`:

| Nim value | SQLite storage class |
| --- | --- |
| Ordinal types such as `int`, `bool`, and enums | `INTEGER` |
| Floating-point types | `REAL` |
| `string` | `TEXT` |
| `seq[byte]` | `BLOB` |
| `Option[T]` or `nil` | `NULL` when empty; otherwise the mapping for `T` |

Use `toDb` and `fromDb` directly when you need explicit conversion. Application types can participate in binding and row unpacking by defining overloads for those procedures; see the [custom types example](examples/custom_types.nim).

## More resources

- [API reference](https://titanomachy.github.io/nim-sqlite/)
- [Runnable examples](examples)
- [Safety and hardening](SAFETY.md), covering input validation, lifecycle guarantees, failure behavior, and sanitizer verification
- [Changelog](CHANGELOG.md)

## Development

```sh
nimble test -Y
nimble examples -Y
nimble docs
```

Coverage can be generated with `nimble coverage` when `lcov` and `genhtml` are installed.

## License

`nim-sqlite` is released under the [MIT License](LICENSE).
