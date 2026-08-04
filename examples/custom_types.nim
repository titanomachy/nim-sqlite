import std/times
import nim_sqlite

proc toDb(value: Time): DbValue =
    DbValue(kind: sqliteInteger, intVal: value.toUnix)

proc fromDb(value: DbValue, _: typedesc[Time]): Time =
    fromUnix(value.fromDb(int))

let db = openDatabase(":memory:")

try:
    db.exec("CREATE TABLE Event(name TEXT NOT NULL, startsAt INTEGER NOT NULL)")

    let start = fromUnix(1_700_000_000)
    db.exec("INSERT INTO Event(name, startsAt) VALUES(?, ?)", "Launch", start)

    let row = db.one("SELECT name, startsAt FROM Event").get
    let (name, startsAt) = row.unpack((string, Time))
    echo name, " starts at Unix timestamp ", startsAt.toUnix
finally:
    db.close()
