## Check every Nim code block in the generated-documentation source.

import std / [os, strutils]

let root = currentSourcePath().parentDir.parentDir
let source = root / "src/nim_sqlite/private/documentation.rst"
let lines = readFile(source).splitLines()
var snippets: seq[string]
var index = 0
while index < lines.len:
    if lines[index] != ".. code-block:: nim":
        inc index
        continue
    inc index
    while index < lines.len and lines[index].strip().len == 0:
        inc index
    var code: seq[string]
    while index < lines.len and
            (lines[index].startsWith("    ") or lines[index].strip().len == 0):
        # Normalize blank lines before removing the common indentation.
        code.add(if lines[index].strip().len == 0: "" else: lines[index])
        inc index
    snippets.add(code.join("\n").dedent().strip())

let output = root / "build/docs_snippets"
mkDir output
withDir root:
    for number, snippet in snippets:
        var imports, body: seq[string]
        for line in snippet.splitLines():
            if line.startsWith("import "):
                imports.add line
            else:
                body.add(if line.strip().len == 0: "" else: "    " & line)
        let module = output / ("snippet_" & $(number + 1) & ".nim")
        writeFile(module,
            "import nim_sqlite\nimport std/[options, times]\n" &
            imports.join("\n") &
            "\nproc checkSnippet() =\n" &
            "  let db = openDatabase(\":memory:\")\n" &
            "  db.execScript(\"CREATE TABLE Person(name TEXT, age INTEGER); " &
            "CREATE TABLE Log(message TEXT)\")\n" &
            "  block:\n" &
            body.join("\n") &
            "\n  discard db\n")
        exec quoteShellCommand([
            getEnv("NIM_BIN", "nim"), "check", "--hints:off",
            "--warnings:off", "--path:src",
            "--nimcache:build/nimcache/docs-snippets", module
        ])

echo "Checked ", snippets.len, " documentation code blocks"
