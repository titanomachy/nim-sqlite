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
    mkDir binDir
    exec "nim c -r --nimcache:build/nimcache/tests --out:build/tests tests/tests"

task docs, "Generate docs":
    exec "nim doc -o:docs/tiny_sqlite.html src/tiny_sqlite.nim"
