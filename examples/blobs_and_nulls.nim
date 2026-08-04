import std/options
import nim_sqlite

let db = openDatabase(":memory:")

try:
    db.exec("""CREATE TABLE Attachment(
        name TEXT NOT NULL,
        contents BLOB NOT NULL,
        description TEXT
    )""")

    db.exec(
        "INSERT INTO Attachment(name, contents, description) VALUES(?, ?, ?)",
        "header.bin",
        @[byte 0x00, byte 0x7F, byte 0xFF],
        some("A three-byte header")
    )
    db.exec(
        "INSERT INTO Attachment(name, contents, description) VALUES(?, ?, ?)",
        "empty.bin",
        newSeq[byte](),
        none(string)
    )

    for row in db.iterate(
        "SELECT name, contents, description FROM Attachment ORDER BY name"
    ):
        let (name, contents, description) =
            row.unpack((string, seq[byte], Option[string]))
        echo name, ": ", contents.len, " byte(s), ", description
finally:
    db.close()
