#!/usr/bin/env python3
"""Compile every Nim code block in the generated-documentation source."""

import os
from pathlib import Path
import subprocess
import textwrap


root = Path(__file__).resolve().parents[1]
source = root / "src/nim_sqlite/private/documentation.rst"
lines = source.read_text().splitlines()
snippets = []
index = 0
while index < len(lines):
    if lines[index] != ".. code-block:: nim":
        index += 1
        continue
    index += 1
    while index < len(lines) and not lines[index].strip():
        index += 1
    block = []
    while index < len(lines) and (lines[index].startswith("    ") or not lines[index].strip()):
        block.append(lines[index])
        index += 1
    snippets.append(textwrap.dedent("\n".join(block)).strip())

output = root / "build/docs_snippets"
output.mkdir(parents=True, exist_ok=True)
for number, snippet in enumerate(snippets, 1):
    imports = [line for line in snippet.splitlines() if line.startswith("import ")]
    body = "\n".join(line for line in snippet.splitlines() if not line.startswith("import "))
    module = output / f"snippet_{number}.nim"
    module.write_text(
        "import nim_sqlite\nimport std/[options, times]\n"
        + "\n".join(imports)
        + "\nproc checkSnippet() =\n"
        + "  let db = openDatabase(\":memory:\")\n"
        + "  db.execScript(\"CREATE TABLE Person(name TEXT, age INTEGER); "
        "CREATE TABLE Log(message TEXT)\")\n"
        + "  block:\n"
        + textwrap.indent(body, "    ")
        + "\n  discard db\n"
    )
    subprocess.run(
        [os.environ.get("NIM_BIN", "nim"), "check", "--hints:off",
         "--warnings:off", "--path:src", "--nimcache:build/nimcache/docs-snippets",
         str(module)],
        cwd=root,
        check=True,
    )

print(f"Compiled {len(snippets)} documentation code blocks")
