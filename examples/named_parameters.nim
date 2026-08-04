import nim_sqlite

let db = openDatabase(":memory:")

try:
    db.exec("CREATE TABLE Person(name TEXT NOT NULL, age INTEGER NOT NULL)")

    let people = [
        (name: "Ada", age: 36),
        (name: "Grace", age: 37),
        (name: "Edsger", age: 72)
    ]
    db.execMany(
        "INSERT INTO Person(name, age) VALUES(:name, :age)",
        people
    )

    for row in db.iterate(
        """SELECT name, age
           FROM Person
           WHERE age >= :minimumAge AND name != :excluded
           ORDER BY age""",
        (excluded: "Ada", minimumAge: 37)
    ):
        let (name, age) = row.unpack((string, int))
        echo name, ": ", age
finally:
    db.close()
