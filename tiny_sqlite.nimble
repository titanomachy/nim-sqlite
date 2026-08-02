# Package

version       = "0.2.0"
author        = "Oscar Nihlgård"
description   = "A thin SQLite wrapper"
license       = "MIT"
srcDir        = "src"
binDir        = "build"

# Dependencies
requires "nim >= 2.2.10", "sqlite3_abi"

task test, "Run tests":
    exec "nim c -r tests/tests"
    rmFile "tests/tests"

task docs, "Generate docs":
    exec "nim doc -o:docs/tiny_sqlite.html src/tiny_sqlite.nim"
