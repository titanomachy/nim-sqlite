# nim-sqlite [![CI](https://github.com/titanomachy/nim-sqlite/actions/workflows/main.yml/badge.svg)](https://github.com/titanomachy/nim-sqlite/actions/workflows/main.yml)

`nim-sqlite` is a comparatively thin, type-safe wrapper for the SQLite database library. The Nim module is named `nim_sqlite` because Nimble package and Nim module names cannot contain hyphens.

It differs from the standard library module `std/db_sqlite` in several ways:

- `nim_sqlite` represents database values with a type-safe case object called `DbValue` instead of treating every value as a string. Among other things, this means that SQLite `NULL` values can be properly supported.

- `nim_sqlite` is designed specifically for SQLite, rather than as a generic database API. The standard library database modules are designed so an application may support several database engines by replacing an import; this library deliberately does not make that tradeoff.

- `nim_sqlite` wraps raw SQLite handles to prevent use-after-free bugs from triggering undefined behavior, unlike direct use of `std/db_sqlite` handles.

## Installation

Install the package from this repository:

```sh
nimble install https://github.com/titanomachy/nim-sqlite
```

The Nimble package name is `nim_sqlite`.

## Usage

```nim
import nim_sqlite, std / options

let db = openDatabase(":memory:")
db.execScript("""
CREATE TABLE Person(
    name TEXT,
    age INTEGER
);

INSERT INTO
    Person(name, age)
VALUES
    ("John Doe", 47);
""")

db.exec("INSERT INTO Person VALUES(?, ?)", "Jane Doe", nil)

for row in db.iterate("SELECT name, age FROM Person"):
    let (name, age) = row.unpack((string, Option[int]))
    echo name, " ", age

# Output:
# John Doe Some(47)
# Jane Doe None[int]
```

## Documentation

- [Generated API documentation](docs/nim_sqlite.html)

## Upstream and license

This project is a fork of [tiny_sqlite](https://github.com/GULPF/tiny_sqlite), originally created by [Oscar Nihlgård](https://github.com/GULPF). His authorship is retained in the package metadata and in the repository history.

The library remains available under the MIT License. See [LICENSE](LICENSE), which retains Oscar Nihlgård's original copyright notice and the complete license text.
