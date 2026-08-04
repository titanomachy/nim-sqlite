# Package

version       = "0.3.0"
author        = "titanomachy"
description   = "A thin, type-safe SQLite wrapper for Nim"
license       = "MIT"
srcDir        = "src"
binDir        = "build"

# Dependencies
requires "nim >= 2.2.10"
requires "sqlite3_abi"

task test, "Run tests":
    mkDir binDir
    exec "nim c -r --path:src --nimcache:build/nimcache/tests --out:build/tests tests/tests"

task examples, "Compile and run examples":
    mkDir binDir
    for example in [
        "basic",
        "blobs_and_nulls",
        "custom_types",
        "named_parameters",
        "prepared_statements",
        "transactions"
    ]:
        exec "nim c -r -d:release --path:src --nimcache:build/nimcache/examples" &
            " --out:build/example_" & example & " examples/" & example & ".nim"

task coverage, "Run tests and generate code coverage report":
    exec "./code_coverage.sh"

task docs, "Generate docs":
    exec "nim doc -o:docs/index.html src/nim_sqlite.nim"
