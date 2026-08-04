import nim_sqlite

let db = openDatabase(":memory:")

try:
    db.exec("CREATE TABLE Person(name TEXT NOT NULL, age INTEGER NOT NULL)")

    let insertPerson = db.stmt("INSERT INTO Person(name, age) VALUES(?, ?)")
    try:
        insertPerson.exec("Ada", 36)
        insertPerson.exec("Grace", 37)
    finally:
        insertPerson.finalize()

    let selectAdults = db.stmt(
        "SELECT name, age FROM Person WHERE age >= ? ORDER BY name")
    try:
        for row in selectAdults.iterate(37):
            let (name, age) = row.unpack((string, int))
            echo name, ": ", age
    finally:
        selectAdults.finalize()
finally:
    db.close()
