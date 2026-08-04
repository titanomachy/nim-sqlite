import std / [unittest, options, sequtils, times]
import nim_sqlite
from nim_sqlite / sqlite3_abi as abi import nil

const SelectPersons = "SELECT name, age FROM Person"
const SelectJohnDoe = "SELECT name, age FROM Person WHERE name = 'John Doe'"
type SelectPersonsRowType = tuple[name: string, age: Option[int]]

proc writePersons(db: DbConn) {.used.} =
    for row in db.all(SelectPersons):
        let (name, age) = row.unpack(SelectPersonsRowType)
        echo name, "\t", age

proc preparedStatementCount(db: DbConn): int =
    var statement = abi.sqlite3_next_stmt(db.unsafeHandle, nil)
    while not statement.isNil:
        result.inc
        statement = abi.sqlite3_next_stmt(db.unsafeHandle, statement)

type ReentrantParam = object
    db: DbConn

proc toDb(value: ReentrantParam): DbValue =
    discard value.db.one("SELECT :first, :second", (first: 100, second: 200))
    toDb(22)

const seedScript = staticRead("./seed_test_db.sql")

template withDb(body: untyped) =
    block:
        let db {.inject.} = openDatabase(":memory:")
        db.execScript(seedScript)
        try:
            body
        finally:
            db.close()

test "db.all":
    withDb:
        let rows = db.all(SelectPersons)
        check rows.len == 2
        let unpackedRows = rows.mapIt(it.unpack(SelectPersonsRowType))
        check unpackedRows.anyIt(it.name == "John Doe" and it.age == some(47))
        check unpackedRows.anyIt(it.name == "Jane Doe" and it.age == none(int))

test "db.all with break":
    # This tests that the prepared statement is cleaned up even when the iterator does
    # not run to completion
    withDb:
        for row in db.all("SELECT name, age FROM Person WHERE name = ?", "John Doe"):
            break
        for row in db.all("SELECT name, age FROM Person WHERE name = ?", "John Doe"):
            break

test "db cached statement same-SQL reentrancy":
    withDb:
        const sql = "SELECT id FROM Person ORDER BY id"
        let statementsBefore = db.preparedStatementCount
        var outerIds: seq[int64]
        for outerRow in db.iterate(sql):
            outerIds.add outerRow[0].intVal
            check db.one(sql).get[0].intVal == 1
            # Keep this regression bounded if a cache reset accidentally
            # restarts the outer query again.
            if outerIds.len > 3:
                break
        check outerIds == @[1'i64, 2'i64]
        check db.preparedStatementCount == statementsBefore + 1

test "db cached statement reentrant parameters are independent":
    withDb:
        const positionalSql = "SELECT id FROM Person WHERE id >= ? ORDER BY id"
        let statementsBefore = db.preparedStatementCount
        var positionalIds: seq[int64]
        for outerRow in db.iterate(positionalSql, 1):
            positionalIds.add outerRow[0].intVal
            check db.one(positionalSql, 2).get[0].intVal == 2
        check positionalIds == @[1'i64, 2'i64]
        check db.preparedStatementCount == statementsBefore + 1

        const namedSql = "SELECT id FROM Person WHERE id >= :minimum ORDER BY id"
        var namedIds: seq[int64]
        for outerRow in db.iterate(namedSql, (minimum: 1,)):
            namedIds.add outerRow[0].intVal
            check db.one(namedSql, (minimum: 2,)).get[0].intVal == 2
        check namedIds == @[1'i64, 2'i64]
        check db.preparedStatementCount == statementsBefore + 2

test "db statement lease begins before named parameter conversion":
    withDb:
        const sql = "SELECT :first, :second"
        let statementsBefore = db.preparedStatementCount
        let row = db.one(sql, (first: 11, second: ReentrantParam(db: db))).get
        check row[0].intVal == 11
        check row[1].intVal == 22
        check db.preparedStatementCount == statementsBefore + 1

test "db cache does not evict a busy statement":
    let db = openDatabase(":memory:", cacheSize = 1)
    try:
        db.execScript(seedScript)
        const outerSql = "SELECT id FROM Person ORDER BY id"
        var outerIds: seq[int64]
        for outerRow in db.iterate(outerSql):
            outerIds.add outerRow[0].intVal
            check db.value("SELECT COUNT(*) FROM Person").get.intVal == 2
            if outerIds.len > 3:
                break
        check outerIds == @[1'i64, 2'i64]
        check db.preparedStatementCount == 1
    finally:
        db.close()

test "db.iterate close":
    withDb:
        expect AssertionDefect:
            for row in db.iterate(SelectPersons):
                db.close()

test "db.one":
    withDb:
        discard db.one(SelectPersons).get.unpack((string, int))
        check db.one(SelectJohnDoe).get[0].strVal == "John Doe"
        check db.one("SELECT * FROM Person WHERE name = ?", "John Person") == none(ResultRow)

test "db.value":
    withDb:
        db.exec("PRAGMA user_version = 1")
        check db.value("PRAGMA user_version").get.intVal == 1

test "db.value no rows":
    withDb:
        check db.value("SELECT * FROM Person Where age = 0") == none(DbValue)

test "TEXT values preserve NUL bytes":
    withDb:
        for expected in ["a\0b", "\0", "\0a", "a\0", ""]:
            let actual = db.value("SELECT ?", expected).get
            check actual.kind == sqliteText
            check actual.strVal == expected
            check actual.strVal.len == expected.len

        let generated = db.value("SELECT CAST(X'610062' AS TEXT)").get
        check generated.kind == sqliteText
        check generated.strVal == "a\0b"
        check generated.strVal.len == 3

test "db.exec":
    withDb:
        db.exec("""
            INSERT INTO Person(name, age)
            VALUES(?, ?)
        """, "John Persson", 103)
        check db.changes == 1
        let rows = db.all(SelectPersons)
        check rows.len == 3
        db.exec("DELETE FROM Person WHERE name = ?", "John Persson")
        check db.all(SelectPersons).len == 2

test "db named parameters":
    withDb:
        db.exec("""
            INSERT INTO Person(name, age)
            VALUES(:name, :age)
        """, (age: 51, name: "Named Person"))

        let rows = db.all("""
            SELECT name, age
            FROM Person
            WHERE age = :age AND name = :name
        """, (name: "Named Person", age: 51))
        check rows.len == 1
        check rows[0].unpack((string, int)) == ("Named Person", 51)

        check db.value("SELECT :part || :part", (part: "repeat",)).get.strVal ==
            "repeatrepeat"
        check db.value("SELECT :myObject || :myResource",
            (myResource: "Resource", myObject: "Object")).get.strVal ==
            "ObjectResource"
        check db.value("SELECT :value", (value: toDb("converted"),)).get.strVal ==
            "converted"

        let cachedSql = "SELECT :first || :second"
        expect SqliteError:
            discard db.value(cachedSql, (first: "a",))
        check db.value(cachedSql, (second: "b", first: "a")).get.strVal == "ab"

        expect SqliteError:
            discard db.value("SELECT :known", (unknown: "value",))
        expect SqliteError:
            discard db.value("SELECT ?", (value: "value",))

test "db.exec trailing comment":
    withDb:
        db.exec("""
            INSERT INTO Person(name, age)
            VALUES(?, ?);
            -- comment
            /*
            comment
            */
        """, "John Persson", 103)
        check db.changes == 1
        let rows = db.all(SelectPersons)
        check rows.len == 3
        db.exec("DELETE FROM Person WHERE name = ?", "John Persson")
        check db.all(SelectPersons).len == 2

test "db.exec trailing syntax error":
    withDb:
        expect SqliteError:
            db.exec("""
                INSERT INTO Person(name, age)
                VALUES(?, ?);
                /*
                comment
                *
            """, "John Persson", 103)
        check db.all(SelectPersons).len == 2

test "db.exec with multiple SQL statements":
    withDb:
        expect SqliteError:
            db.exec("""
                DELETE FROM Person;
                DELETE FROM Person;
            """)
        check db.all(SelectPersons).len == 2

test "db.execMany":
    withDb:
        db.execMany("""
            INSERT INTO Person(name, age)
            VALUES(?, ?)
        """, @[
            @[toDb("John Doe"), toDb(23)],
            @[toDb("Jane Doe"), toDb(22)]
        ])
        let rows = db.all(SelectPersons)
        check rows.len == 4

test "db.execMany named parameters":
    withDb:
        db.execMany("""
            INSERT INTO Person(name, age)
            VALUES(:name, :age)
        """, [
            (age: 23, name: "Named One"),
            (age: 24, name: "Named Two")
        ])
        check db.value("""
            SELECT COUNT(*)
            FROM Person
            WHERE name IN (:first, :second)
        """, (second: "Named Two", first: "Named One")).get.intVal == 2

test "db.execMany with failure":
    withDb:
        expect SqliteError:
            db.execMany("""
                INSERT INTO Person(name, age)
                VALUES(?, ?)
            """, @[@[toDb("John Doe"), toDb(23)], @[toDb("Jane Doe")]])
        let rows = db.all(SelectPersons)
        check rows.len == 2

test "db.execMany in transaction":
    withDb:
        db.transaction:
            db.execMany("""
                INSERT INTO Person(name, age)
                VALUES(?, ?)
            """, @[@[toDb("John Doe"), toDb(23)], @[toDb("Jane Doe"), toDb(20)]])
            let rows = db.all(SelectPersons)
            check rows.len == 4

test "db.execScript trailing comment":
    withDb:
        db.execScript("""
            INSERT INTO Person(name, age)
            VALUES('John Persson', 23);
            INSERT INTO Person(name, age)
            VALUES('John Persson', 23);
            -- comment
            /*
            comment
            */
        """)
        let rows = db.all(SelectPersons)
        check rows.len == 4

test "db.execScript in transaction":
    withDb:
        db.transaction:
            db.execScript("""
                INSERT INTO Person(name, age)
                VALUES('John Persson', 23);
                INSERT INTO Person(name, age)
                VALUES('John Persson', 23);
            """)
            let rows = db.all(SelectPersons)
            check rows.len == 4

test "db.execScript with failure":
    withDb:
        expect SqliteError:
            db.execScript("""
                INSERT
                    INSERT INTO Person(name, age)
                    VALUES('John Persson', 23);

                    INSERT INTO Wrong(field)
                    VALUES(10);
            """)
        let rows = db.all(SelectPersons)
        check rows.len == 2

test "db.transaction with return":
    withDb:
        proc fun() =
            db.transaction:
                db.exec("INSERT INTO Person(name, age) VALUES('John Persson', 103)")
                return
        fun()
        let rows = db.all("SELECT * FROM Person")
        check rows.len == 3
        db.exec("DELETE FROM Person WHERE name = 'John Persson'")
        check db.all("SELECT name, age FROM Person").len == 2


test "db.transaction with exception":
    withDb:
        proc fun() =
            db.transaction:
                db.exec("DELETE FROM Person")
                raise newException(Exception, "failure")
        try:
            fun()
        except:
            discard
        check db.all("SELECT name, age FROM Person").len == 2

test "db.transaction rolls back a failed commit":
    withDb:
        db.execScript("""
            CREATE TABLE Parent(id INTEGER PRIMARY KEY);
            CREATE TABLE Child(
                parentId INTEGER,
                FOREIGN KEY(parentId) REFERENCES Parent(id)
                    DEFERRABLE INITIALLY DEFERRED
            );
        """)

        expect SqliteError:
            db.transaction:
                db.exec("INSERT INTO Child(parentId) VALUES(1)")

        check not db.isInTransaction
        check db.value("SELECT COUNT(*) FROM Child").get.fromDb(int) == 0

        # The connection must be ready for a new transaction after cleanup.
        db.transaction:
            db.exec("INSERT INTO Parent(id) VALUES(1)")
            db.exec("INSERT INTO Child(parentId) VALUES(1)")
        check db.value("SELECT COUNT(*) FROM Child").get.fromDb(int) == 1

test "db.transaction nesting":
    withDb:
        db.transaction:
            db.transaction:
                check db.all(SelectPersons).len == 2

test "db.isInTransaction":
    withDb:
        check not db.isInTransaction
        db.transaction:
            check db.isInTransaction
        check not db.isInTransaction

test "db.isOpen":
    var db: DbConn
    check not db.isOpen
    expect AssertionDefect:
        discard db.all(SelectPersons)
    db = openDatabase(":memory:")
    check db.isOpen
    db.close()
    check not db.isOpen
    expect AssertionDefect:
        discard db.all(SelectPersons)

test "raw SQLite ABI access":
    withDb:
        let handle: ptr abi.sqlite3 = db.unsafeHandle
        check not handle.isNil
        check abi.sqlite3_get_autocommit(handle) == 1

test "db.isReadonly":
    withDb:
        check not db.isReadonly
        let readonlyDb = openDatabase(":memory:", dbRead)
        check readonlyDb.isReadonly
        readonlyDb.close()

test "db.close twice":
    let db = openDatabase(":memory:")
    db.close()
    db.close()

test "db.close with owned explicit statements":
    let db = openDatabase(":memory:")
    db.execScript(seedScript)
    let stmt = db.stmt(SelectPersons)
    db.close()
    check not stmt.isAlive
    expect AssertionDefect:
        discard stmt.all()
    # The explicit statement still owns its SQLite handle after the logical
    # connection close and must remain safe to finalize.
    stmt.finalize()
    stmt.finalize()

test "db.close with multiple owned explicit statements":
    let db = openDatabase(":memory:")
    let first = db.stmt("SELECT 1")
    let second = db.stmt("SELECT 2")
    db.close()
    check not first.isAlive
    check not second.isAlive
    # Finalization order must not matter after sqlite3_close_v2.
    second.finalize()
    first.finalize()

test "db.close default value":
    var db: DbConn
    db.close()

when not defined(macosx):
    test "db.loadExtension":
        withDb:
            expect SqliteError:
                db.loadExtension("invalid extension path")

test "db.loadExtension on closed connection":
    let db = openDatabase(":memory:")
    db.close()
    expect AssertionDefect:
        db.loadExtension("invalid extension path")

test "row.unpack":
    withDb:
        let row = db.one(SelectJohnDoe).get
        let (name, age) = row.unpack((string, int))
        check (name, age) == ("John Doe", 47)
        expect AssertionDefect:
            discard row.unpack(tuple[name: string])

test "stmt.all":
    withDb:
        let stmt = db.stmt(SelectPersons)
        for i in 0 .. 1:
            let rows = stmt.all()
            check rows.len == 2
            let unpackedRows = rows.mapIt(it.unpack(SelectPersonsRowType))
            check unpackedRows.anyIt(it.name == "John Doe" and it.age == some(47))
            check unpackedRows.anyIt(it.name == "Jane Doe" and it.age == none(int))
        stmt.finalize()

    withDb:
        let stmt = db.stmt("SELECT name, age FROM Person WHERE name = ?")
        expect SqliteError:
            discard stmt.all()
        var rows = stmt.all("John Doe")
        check rows.len == 1
        check rows[0][0].fromDb(string) == "John Doe"
        check rows[0][1].fromDb(int) == 47
        rows = stmt.all("Jane Doe")
        check rows.len == 1
        check rows[0][0].fromDb(string) == "Jane Doe"
        check rows[0][1].fromDb(Option[int]) == none(int)
        stmt.finalize()

test "stmt named parameters":
    withDb:
        let insertStmt = db.stmt("""
            INSERT INTO Person(name, age)
            VALUES(:name, :age)
        """)
        insertStmt.exec((age: 31, name: "Prepared One"))
        insertStmt.execMany([
            (age: 32, name: "Prepared Two"),
            (age: 33, name: "Prepared Three")
        ])
        insertStmt.finalize()

        let selectStmt = db.stmt("""
            SELECT age
            FROM Person
            WHERE name = :name
        """)
        check selectStmt.value((name: "Prepared One",)).get.intVal == 31
        expect SqliteError:
            discard selectStmt.value((unknown: "Prepared One",))
        check selectStmt.value((name: "Prepared Two",)).get.intVal == 32
        selectStmt.finalize()

test "stmt.iterate busy":
    withDb:
        let stmt = db.stmt(SelectPersons)
        for row in stmt.iterate():
            expect AssertionDefect:
                discard stmt.all()
            expect AssertionDefect:
                discard stmt.one()
            expect AssertionDefect:
                discard stmt.value()
            expect AssertionDefect:
                stmt.exec()

test "stmt.iterate close/finalize":
    withDb:
        let stmt = db.stmt(SelectPersons)
        expect AssertionDefect:
            for row in stmt.iterate():
                db.close()
        stmt.finalize()
    withDb:
        let stmt = db.stmt(SelectPersons)
        expect AssertionDefect:
            for row in stmt.iterate():
                stmt.finalize()

test "stmt.isAlive":
    withDb:
        var stmt: SqlStatement
        check not stmt.isAlive
        expect AssertionDefect:
            discard stmt.all()
        stmt = db.stmt(SelectPersons)
        check stmt.isAlive
        stmt.finalize()
        check not stmt.isAlive
        expect AssertionDefect:
            discard stmt.all()

test "stmt.finalize twice":
    withDb:
        let stmt = db.stmt(SelectPersons)
        stmt.finalize()
        stmt.finalize()

test "stmt.finalize default value":
    var stmt: SqlStatement
    stmt.finalize()

test "cacheSize=0":
    let db = openDatabase(":memory:", cacheSize = 0)
    db.execScript(seedScript)
    discard db.all(SelectPersons)
    discard db.all(SelectPersons)
    db.close()

test "db binding failure releases uncached statements":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        let statementsBefore = db.preparedStatementCount
        for _ in 0 ..< 3:
            expect SqliteError:
                db.exec("SELECT ?")
            check db.preparedStatementCount == statementsBefore
    finally:
        db.close()

test "db preparation failure releases its statement":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        let statementsBefore = db.preparedStatementCount
        expect SqliteError:
            db.exec("SELECT 1; SELECT 2")
        check db.preparedStatementCount == statementsBefore
    finally:
        db.close()

test "openDatabase failure releases SQLite memory":
    let memoryBefore = abi.sqlite3_memory_used()
    for mode in [dbReadWrite, dbRead]:
        for _ in 0 ..< 3:
            expect SqliteError:
                discard openDatabase(".", mode)
            check abi.sqlite3_memory_used() == memoryBefore

test "ResultRow":
    withDb:
        let row = db.one(SelectPersons).get
        doAssert row["name"].strVal == "John Doe"
        doAssert row[0].strVal == "John Doe"
        doAssert row["age"].intVal == 47
        doAssert row[1].intVal == 47

    withDb:
        let row = db.one("SELECT a.name, b.name FROM Person a JOIN Person b").get
        check row.columns == @["name", "name"]
        expect AssertionDefect:
            discard row["name"]

test "SqliteError":
    withDb:
        expect SqliteError:
            db.execScript("""
                CREATE TABLE Person(
                    name TEXT,
                    age INTEGER
                );
            """)
        expect SqliteError:
            discard openDatabase("some/made/up/path", dbRead)

test "Type mappings":
    withDb:
        let rows = db.all("SELECT * FROM Types")
        check rows.len == 1
        block:
            let unpackedRow = rows[0].unpack((string, int, float, Option[int], seq[byte]))
            check unpackedRow[0] == "foo åäö 𐐷"
            check unpackedRow[1] == 1
            check unpackedRow[2] == 1.5
            check unpackedRow[3] == none(int)
            check unpackedRow[4] == @[0x01'u8, 0x02'u8, 0xFF'u8]
        block:
            # sqliteInteger can be treated as bool (or any other ordinal as well)
            let unpackedRow = rows[0].unpack((string, bool, float, Option[int], seq[byte]))
            check unpackedRow[1]

proc toDb(t: Time): DbValue =
    DbValue(kind: sqliteInteger, intVal: toUnix(t))

proc fromDb(value: DbValue, T: typedesc[Time]): Time =
    fromUnix(value.intval)

test "Custom type mapping":
    withDb:
        db.exec("CREATE TABLE Foo(timestamp INTEGER)")
        db.exec("INSERT INTO Foo(timestamp) VALUES(?)", fromUnix(12))
        db.exec("INSERT INTO Foo(timestamp) VALUES(:timestamp)",
            (timestamp: fromUnix(13),))
        let row = db.one("SELECT timestamp FROM Foo WHERE timestamp = :timestamp",
            (timestamp: fromUnix(13),))
        check row.isSome
        let (timestamp,) = row.get.unpack((Time,))
        check timestamp == fromUnix(13)

test "Foreign keys":
    withDb:
        db.exec("""
            CREATE TABLE ForeignKey(
                id INTEGER,
                personId INTEGER,
                FOREIGN KEY(personId) REFERENCES Person(id)
            );
        """)
        db.exec("PRAGMA foreign_keys = ON;")
        db.exec("INSERT INTO ForeignKey(personId) VALUES(NULL)")
        db.exec("INSERT INTO ForeignKey(personId) VALUES(1)")
        expect SqliteError:
            db.exec("INSERT INTO ForeignKey(personId) VALUES(100)")
