import std/options
import nim_sqlite

let db = openDatabase(":memory:")

try:
    db.execScript("""
        CREATE TABLE Person(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            age INTEGER
        );
    """)

    db.exec("INSERT INTO Person(name, age) VALUES(?, ?)", "Ada", 36)
    db.exec("INSERT INTO Person(name, age) VALUES(:name, :age)",
        (name: "Grace", age: none(int)))

    for row in db.iterate("SELECT id, name, age FROM Person ORDER BY id"):
        let (id, name, age) = row.unpack((int, string, Option[int]))
        echo id, ": ", name, " (age: ", age, ")"
finally:
    db.close()
