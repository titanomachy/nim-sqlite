import std / [unittest, options, os, sequtils, strutils, times]
import nim_sqlite
from nim_sqlite / sqlite3_abi as abi import nil

const SelectPersons = "SELECT name, age FROM Person"
const SelectJohnDoe = "SELECT name, age FROM Person WHERE name = 'John Doe'"
const LateRowErrorPositional = """
    WITH RECURSIVE Input(value) AS (
        VALUES(1)
        UNION ALL
        SELECT value + 1 FROM Input WHERE value < 2
    )
    SELECT CASE
        WHEN value = 2 AND ? THEN abs(-9223372036854775808)
        ELSE value
    END
    FROM Input
"""
const LateRowErrorNamed = LateRowErrorPositional.replace("?", ":fail")
const NoSqlErrorMessage = "SQL input contains no statement."
const EmbeddedNulSqlErrorMessage = "SQL input contains an embedded NUL byte."
type SelectPersonsRowType = tuple[name: string, age: Option[int]]

type
    SmallIntegerRange = range[-2 .. 2]
    WideUnsignedRange = range[0'u64 .. high(uint64)]
    TestEnum = enum
        enumZero,
        enumOne,
        enumTwo

    DeniedSavepointOperation = enum
        denyNoSavepointOperation,
        denySavepointRollback,
        denySavepointRelease,
        denyAllRollback

    TransactionAuthorizerState = object
        deniedOperation: DeniedSavepointOperation

proc transactionAuthorizer(userData: pointer, actionCode: cint,
        operation, savepoint, database, trigger: cstring): cint {.cdecl.} =
    discard savepoint
    discard database
    discard trigger
    if operation.isNil:
        return abi.SQLITE_OK

    let state = cast[ptr TransactionAuthorizerState](userData)
    case state.deniedOperation
    of denyNoSavepointOperation:
        abi.SQLITE_OK
    of denySavepointRollback:
        if actionCode == abi.SQLITE_SAVEPOINT and $operation == "ROLLBACK":
            abi.SQLITE_DENY
        else:
            abi.SQLITE_OK
    of denySavepointRelease:
        if actionCode == abi.SQLITE_SAVEPOINT and $operation == "RELEASE":
            abi.SQLITE_DENY
        else:
            abi.SQLITE_OK
    of denyAllRollback:
        if $operation == "ROLLBACK" and actionCode in {
                abi.SQLITE_SAVEPOINT, abi.SQLITE_TRANSACTION}:
            abi.SQLITE_DENY
        else:
            abi.SQLITE_OK

template expectSqliteErrorMessage(expectedMessage: string, body: untyped) =
    block:
        var raised = false
        try:
            body
        except SqliteError as error:
            raised = true
            check error.msg == expectedMessage
        check raised

proc writePersons(db: DbConn) {.used.} =
    for row in db.all(SelectPersons):
        let (name, age) = row.unpack(SelectPersonsRowType)
        echo name, "\t", age

proc preparedStatementCount(db: DbConn): int =
    var statement = abi.sqlite3_next_stmt(db.unsafeHandle, nil)
    while not statement.isNil:
        result.inc
        statement = abi.sqlite3_next_stmt(db.unsafeHandle, statement)

proc databaseConfigValue(db: DbConn, option: cint): cint =
    check abi.sqlite3_db_config(db.unsafeHandle, option, cint(-1), addr result) ==
        abi.SQLITE_OK

template expectPreparedCountUnchanged(db: DbConn, exceptionType: typedesc,
        body: untyped) =
    block:
        let preparedCountBefore = db.preparedStatementCount
        expect exceptionType:
            body
        check db.preparedStatementCount == preparedCountBefore

type ReentrantParam = object
    db: DbConn

proc toDb(value: ReentrantParam): DbValue =
    discard value.db.one("SELECT :first, :second", (first: 100, second: 200))
    toDb(22)

type ClosingParam = object
    db: DbConn

proc toDb(value: ClosingParam): DbValue =
    value.db.close()
    toDb(23)

type
    StatementLifecycleAction = enum
        finalizeStatement,
        reuseStatement

    StatementLifecycleParam = object
        statement: SqlStatement
        action: StatementLifecycleAction

proc toDb(value: StatementLifecycleParam): DbValue =
    case value.action
    of finalizeStatement:
        value.statement.finalize()
    of reuseStatement:
        discard value.statement.value((value: toDb(24),))
    toDb(25)

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

test "db close is rejected during named parameter conversion":
    for cacheSize in [0, 1]:
        let db = openDatabase(":memory:", cacheSize = cacheSize)
        try:
            check db.value("SELECT :value", (value: toDb(26),)).get.intVal == 26
            let statementsBefore = db.preparedStatementCount
            expectPreparedCountUnchanged(db, SqliteUsageError):
                discard db.value("SELECT :value", (value: ClosingParam(db: db),))

            check db.isOpen
            check db.value("SELECT :value", (value: toDb(26),)).get.intVal == 26
            check db.preparedStatementCount == statementsBefore
        finally:
            db.close()

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
        # Warm the cache so the failure must return the existing statement
        # lease rather than legitimately adding its first cached handle.
        discard db.all(SelectPersons)
        expectPreparedCountUnchanged(db, SqliteUsageError):
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

test "bound TEXT and BLOB values preserve NUL bytes":
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

        for expected in [
            newSeq[byte](),
            @[0x61'u8, 0x00'u8, 0x62'u8],
            @[0x00'u8],
            @[0x00'u8, 0x61'u8],
            @[0x61'u8, 0x00'u8]
        ]:
            let actual = db.value("SELECT ?", expected).get
            check actual.kind == sqliteBlob
            check actual.blobVal == expected
            check actual.blobVal.len == expected.len

test "single-statement operations reject input without SQL":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        for sql in [
            "",
            "   \n\t",
            ";;;",
            "-- line comment",
            "/* block comment */",
            "; -- comments and empty statements\n; /* only */ ;"
        ]:
            let statementsBefore = db.preparedStatementCount

            expectSqliteErrorMessage NoSqlErrorMessage:
                db.exec(sql)
            expectSqliteErrorMessage NoSqlErrorMessage:
                db.exec(sql, (unused: 1,))
            expectSqliteErrorMessage NoSqlErrorMessage:
                discard db.all(sql)
            expectSqliteErrorMessage NoSqlErrorMessage:
                discard db.one(sql)
            expectSqliteErrorMessage NoSqlErrorMessage:
                discard db.value(sql)
            expectSqliteErrorMessage NoSqlErrorMessage:
                discard db.value(sql, (unused: 1,))
            expectSqliteErrorMessage NoSqlErrorMessage:
                for _ in db.iterate(sql):
                    discard
            expectSqliteErrorMessage NoSqlErrorMessage:
                let statement = db.stmt(sql)
                statement.finalize()

            check db.preparedStatementCount == statementsBefore

        # A validation failure must not leave the operation guard active.
        check db.value("SELECT 1").get.intVal == 1
    finally:
        db.close()

test "SQL operations reject embedded NUL bytes":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        db.exec("CREATE TABLE ExecutionLog(value INTEGER)")
        let statementsBefore = db.preparedStatementCount

        for sql in ["\0SELECT 1", "SELECT 1\0", "SELECT 1\0; SELECT 2"]:
            expectSqliteErrorMessage EmbeddedNulSqlErrorMessage:
                db.exec(sql)

        expectSqliteErrorMessage EmbeddedNulSqlErrorMessage:
            discard db.value("SELECT 1\0; SELECT 2")
        expectSqliteErrorMessage EmbeddedNulSqlErrorMessage:
            discard db.value("SELECT :value\0; SELECT 2", (value: 1,))
        expectSqliteErrorMessage EmbeddedNulSqlErrorMessage:
            let statement = db.stmt("SELECT 1\0; SELECT 2")
            statement.finalize()
        expectSqliteErrorMessage EmbeddedNulSqlErrorMessage:
            db.execScript("INSERT INTO ExecutionLog VALUES(1);\0 SELECT 1")

        check db.value("SELECT COUNT(*) FROM ExecutionLog").get.intVal == 0
        check db.preparedStatementCount == statementsBefore
    finally:
        db.close()

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

test "db.exec runs row-producing statements to completion":
    withDb:
        check db.one(LateRowErrorNamed, (fail: 1,)).get[0].intVal == 1
        let statementsAfterFirstRow = db.preparedStatementCount

        expectPreparedCountUnchanged(db, SqliteError):
            db.exec(LateRowErrorNamed, (fail: 1,))
        check db.preparedStatementCount == statementsAfterFirstRow

        db.exec(LateRowErrorNamed, (fail: 0,))
        check db.preparedStatementCount == statementsAfterFirstRow

        db.exec(LateRowErrorPositional, 0)
        expectPreparedCountUnchanged(db, SqliteError):
            db.exec(LateRowErrorPositional, 1)
        db.exec(LateRowErrorPositional, 0)

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
        check db.value(cachedSql, (second: "b", first: "a")).get.strVal == "ab"
        expectPreparedCountUnchanged(db, SqliteError):
            discard db.value(cachedSql, (first: "a",))
        check db.value(cachedSql, (second: "b", first: "a")).get.strVal == "ab"

        check db.value("SELECT :known", (known: "value",)).get.strVal == "value"
        expectPreparedCountUnchanged(db, SqliteError):
            discard db.value("SELECT :known", (unknown: "value",))
        check db.value("SELECT ?", "value").get.strVal == "value"
        expectPreparedCountUnchanged(db, SqliteError):
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

test "db.exec accepts generated non-SQL tails":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        const tailParts = [
            "",
            " ",
            "\t\r\n\f",
            ";",
            ";;",
            "-- trailing comment",
            "-- trailing comment\n",
            "/* trailing comment */"
        ]

        # Exercise combinations rather than teaching the wrapper its own SQL
        # comment grammar. SQLite must identify every generated tail as
        # containing no further statement.
        for first in tailParts:
            for second in tailParts:
                for third in tailParts:
                    db.exec("SELECT 1;" & first & second & third)
                    check db.preparedStatementCount == 0
    finally:
        db.close()

test "db.exec trailing syntax error":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        db.exec("CREATE TABLE ExecutionLog(value INTEGER)")
        for invalidTail in [
            "/*",
            "/* unterminated",
            "SELECT FROM",
            "'unterminated string"
        ]:
            expect SqliteError:
                db.exec("INSERT INTO ExecutionLog VALUES(1);" & invalidTail)
            check db.value("SELECT COUNT(*) FROM ExecutionLog").get.intVal == 0
            check db.preparedStatementCount == 0
    finally:
        db.close()

test "db.exec with multiple SQL statements":
    withDb:
        expectPreparedCountUnchanged(db, SqliteError):
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

test "db.execScript ignores scripts without statements":
    withDb:
        for script in [
            "",
            "   \n\t",
            ";;;",
            "-- line comment",
            "/* block comment */",
            "; -- comments and empty statements\n; /* only */ ;"
        ]:
            db.execScript(script)
        check db.all(SelectPersons).len == 2

test "db.execScript rejects invalid trailing SQL":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        db.exec("CREATE TABLE ExecutionLog(value INTEGER)")
        for invalidTail in ["/*", "SELECT FROM"]:
            expect SqliteError:
                db.execScript("INSERT INTO ExecutionLog VALUES(1);" & invalidTail)
            check db.value("SELECT COUNT(*) FROM ExecutionLog").get.intVal == 0
            check db.preparedStatementCount == 0
    finally:
        db.close()

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

test "db.execScript rejects transaction control without committing partial work":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        db.exec("CREATE TABLE ExecutionLog(value INTEGER)")
        for transactionSql in [
            "\xEF\xBB\xBFbegin",
            "/* leading comment */ COMMIT",
            "-- leading comment\nEND",
            "ROLLBACK",
            "SAVEPOINT user_scope",
            "RELEASE user_scope"
        ]:
            var raised = false
            try:
                db.execScript("INSERT INTO ExecutionLog VALUES(1); " &
                    transactionSql & "; INSERT INTO ExecutionLog VALUES(2)")
            except SqliteError as error:
                raised = true
                check error.msg ==
                    "Transaction-control statements are not allowed in execScript."
                check error.operation == SqliteOperation.validation
                check error.primaryCode == int32(abi.SQLITE_OK)
            check raised
            check not db.isInTransaction
            check db.value("SELECT COUNT(*) FROM ExecutionLog").get.intVal == 0
    finally:
        db.close()

test "db.execScript transaction-control rejection preserves a manual transaction":
    withDb:
        db.exec("BEGIN")
        db.exec("INSERT INTO Person(name, age) VALUES('Manual', 40)")
        expect SqliteError:
            db.execScript("""
                INSERT INTO Person(name, age) VALUES('Script', 41);
                COMMIT;
                INSERT INTO Person(name, age) VALUES('After', 42);
            """)

        check db.isInTransaction
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Manual'").get.intVal == 1
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Script'").get.intVal == 0
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'After'").get.intVal == 0
        db.exec("ROLLBACK")

test "db.execScript reports errors after the first result row":
    let db = openDatabase(":memory:", cacheSize = 0)
    try:
        db.exec("CREATE TABLE ExecutionLog(value INTEGER)")
        expect SqliteError:
            db.execScript("""
                INSERT INTO ExecutionLog(value) VALUES(1);
                WITH RECURSIVE Input(value) AS (
                    VALUES(1)
                    UNION ALL
                    SELECT value + 1 FROM Input WHERE value < 2
                )
                SELECT CASE
                    WHEN value = 2 THEN abs(-9223372036854775808)
                    ELSE value
                END
                FROM Input;
                INSERT INTO ExecutionLog(value) VALUES(2);
            """)

        check db.preparedStatementCount == 0
        check db.value("SELECT COUNT(*) FROM ExecutionLog").get.intVal == 0
        db.exec("INSERT INTO ExecutionLog(value) VALUES(3)")
        check db.value("SELECT value FROM ExecutionLog").get.intVal == 3
    finally:
        db.close()

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
        let statementsBefore = db.preparedStatementCount
        db.transaction:
            check db.preparedStatementCount == statementsBefore
            db.transaction:
                check db.preparedStatementCount == statementsBefore
                check db.all(SelectPersons).len == 2
        # Only the application SELECT is cached; unique transaction-control
        # statements are finalized immediately.
        check db.preparedStatementCount == statementsBefore + 1

test "db.transaction rolls back only a failed nested scope":
    withDb:
        db.transaction:
            db.exec("INSERT INTO Person(name, age) VALUES('Outer One', 31)")
            try:
                db.transaction:
                    db.exec("INSERT INTO Person(name, age) VALUES('Inner', 32)")
                    raise newException(ValueError, "inner failure")
            except ValueError as error:
                check error.msg == "inner failure"
            db.exec("INSERT INTO Person(name, age) VALUES('Outer Two', 33)")

        check db.value("SELECT COUNT(*) FROM Person WHERE name LIKE 'Outer %'").get.intVal == 2
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Inner'").get.intVal == 0

test "db.transaction outer failure rolls back nested work":
    withDb:
        var caught = false
        try:
            db.transaction:
                db.exec("INSERT INTO Person(name, age) VALUES('Outer', 31)")
                db.transaction:
                    db.exec("INSERT INTO Person(name, age) VALUES('Inner', 32)")
                raise newException(ValueError, "outer failure")
        except ValueError:
            caught = true

        check caught
        check db.value("SELECT COUNT(*) FROM Person WHERE name IN ('Outer', 'Inner')").get.intVal == 0
        check not db.isInTransaction

test "db.execMany failure rolls back its nested savepoint":
    withDb:
        db.transaction:
            db.exec("INSERT INTO Person(name, age) VALUES('Outer', 31)")
            expect SqliteError:
                db.execMany("INSERT INTO Person(name, age) VALUES(?, ?)", @[
                    @[toDb("Bulk One"), toDb(32)],
                    @[toDb("Bulk Two")]
                ])

        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Outer'").get.intVal == 1
        check db.value("SELECT COUNT(*) FROM Person WHERE name LIKE 'Bulk %'").get.intVal == 0

test "db.transaction mode controls outer transaction locking":
    let databasePath = getTempDir() / ("nim_sqlite_transaction_modes_" &
        $getCurrentProcessId() & "_" & $epochTime() & ".sqlite")
    var first, second: DbConn
    try:
        first = openDatabase(databasePath)
        second = openDatabase(databasePath)
        first.exec("CREATE TABLE Item(value INTEGER)")

        first.transaction(TransactionMode.deferred):
            second.exec("INSERT INTO Item(value) VALUES(1)")

        first.transaction(TransactionMode.immediate):
            expect SqliteError:
                second.exec("INSERT INTO Item(value) VALUES(2)")

        first.transaction(TransactionMode.exclusive):
            expect SqliteError:
                discard second.value("SELECT COUNT(*) FROM Item")

        check first.value("SELECT COUNT(*) FROM Item").get.intVal == 1
    finally:
        second.close()
        first.close()
        if fileExists(databasePath):
            removeFile(databasePath)

test "db.transaction uses a savepoint inside a manual transaction":
    withDb:
        db.exec("BEGIN IMMEDIATE")
        db.exec("INSERT INTO Person(name, age) VALUES('Manual', 40)")
        try:
            db.transaction(TransactionMode.exclusive):
                db.exec("INSERT INTO Person(name, age) VALUES('Nested', 41)")
                raise newException(ValueError, "nested failure")
        except ValueError:
            discard

        check db.isInTransaction
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Manual'").get.intVal == 1
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Nested'").get.intVal == 0
        db.exec("COMMIT")
        check not db.isInTransaction

test "db.transaction exposes rollback cleanup failures":
    withDb:
        var state = TransactionAuthorizerState(
            deniedOperation: denyNoSavepointOperation)
        db.exec("BEGIN")
        check abi.sqlite3_set_authorizer(db.unsafeHandle,
            transactionAuthorizer, addr state) == abi.SQLITE_OK
        try:
            var caught = false
            try:
                db.transaction:
                    db.exec("INSERT INTO Person(name, age) VALUES('Nested', 41)")
                    state.deniedOperation = denySavepointRollback
                    raise newException(ValueError, "body failure")
            except ValueError as error:
                caught = true
                check error.msg == "body failure"
                check not error.parent.isNil
                check error.parent of SqliteError
            check caught
        finally:
            discard abi.sqlite3_set_authorizer(db.unsafeHandle, nil, nil)

        # Denying ROLLBACK TO forces the safety fallback to roll back the full
        # manually created transaction, restoring a known autocommit state.
        check not db.isInTransaction
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Nested'").get.intVal == 0

test "db.transaction preserves every rollback cleanup failure":
    withDb:
        var state = TransactionAuthorizerState(
            deniedOperation: denyNoSavepointOperation)
        db.exec("BEGIN")
        check abi.sqlite3_set_authorizer(db.unsafeHandle,
            transactionAuthorizer, addr state) == abi.SQLITE_OK
        try:
            var caught = false
            try:
                db.transaction:
                    db.exec("INSERT INTO Person(name, age) VALUES('Nested', 41)")
                    state.deniedOperation = denyAllRollback
                    raise newException(ValueError, "body failure")
            except ValueError as error:
                caught = true
                check error.msg == "body failure"
                check not error.parent.isNil
                check error.parent of SqliteError
                check not error.parent.parent.isNil
                check error.parent.parent of SqliteError
                check error.parent.parent.parent.isNil
            check caught
            check db.isInTransaction
        finally:
            discard abi.sqlite3_set_authorizer(db.unsafeHandle, nil, nil)
            if db.isInTransaction:
                db.exec("ROLLBACK")

        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Nested'").get.intVal == 0

test "db.transaction recovers from a nested release failure":
    withDb:
        var state = TransactionAuthorizerState(
            deniedOperation: denyNoSavepointOperation)
        db.exec("BEGIN")
        check abi.sqlite3_set_authorizer(db.unsafeHandle,
            transactionAuthorizer, addr state) == abi.SQLITE_OK
        var caught = false
        try:
            try:
                db.transaction:
                    db.exec("INSERT INTO Person(name, age) VALUES('Nested', 41)")
                    state.deniedOperation = denySavepointRelease
            except SqliteError as error:
                caught = true
                check not error.parent.isNil
                check error.parent of SqliteError
            check caught
        finally:
            discard abi.sqlite3_set_authorizer(db.unsafeHandle, nil, nil)

        check not db.isInTransaction
        check db.value("SELECT COUNT(*) FROM Person WHERE name = 'Nested'").get.intVal == 0

test "db.isInTransaction":
    withDb:
        check not db.isInTransaction
        db.transaction:
            check db.isInTransaction
        check not db.isInTransaction

test "db.isOpen":
    var db: DbConn
    check not db.isOpen
    expect SqliteUsageError:
        discard db.all(SelectPersons)
    db = openDatabase(":memory:")
    check db.isOpen
    db.close()
    check not db.isOpen
    expect SqliteUsageError:
        discard db.all(SelectPersons)

test "raw SQLite ABI access":
    withDb:
        let handle: ptr abi.sqlite3 = db.unsafeHandle
        check not handle.isNil
        check abi.sqlite3_get_autocommit(handle) == 1

    let closedDb = openDatabase(":memory:")
    closedDb.close()
    expect SqliteUsageError:
        discard closedDb.unsafeHandle

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
    expect SqliteUsageError:
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
            check db.databaseConfigValue(
                abi.SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION) == 1
            expectSqliteErrorMessage "Extension path contains an embedded NUL byte.":
                db.loadExtension("invalid\0extension path")

test "db.loadExtension on closed connection":
    let db = openDatabase(":memory:")
    db.close()
    expect SqliteUsageError:
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
        expectPreparedCountUnchanged(db, SqliteError):
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
        expectPreparedCountUnchanged(db, SqliteError):
            discard selectStmt.value((unknown: "Prepared One",))
        check selectStmt.value((name: "Prepared Two",)).get.intVal == 32
        selectStmt.finalize()

test "stmt.exec runs row-producing statements to completion":
    withDb:
        let stmt = db.stmt(LateRowErrorNamed)
        try:
            check stmt.one((fail: 1,)).get[0].intVal == 1

            expectPreparedCountUnchanged(db, SqliteError):
                stmt.exec((fail: 1,))
            check stmt.isAlive

            stmt.exec((fail: 0,))
            check stmt.isAlive

            expectPreparedCountUnchanged(db, SqliteError):
                stmt.exec((fail: 1,))
            check stmt.isAlive
        finally:
            stmt.finalize()

test "stmt.iterate busy":
    withDb:
        let stmt = db.stmt(SelectPersons)
        try:
            for row in stmt.iterate():
                expectPreparedCountUnchanged(db, SqliteUsageError):
                    discard stmt.all()
                expectPreparedCountUnchanged(db, SqliteUsageError):
                    discard stmt.one()
                expectPreparedCountUnchanged(db, SqliteUsageError):
                    discard stmt.value()
                expectPreparedCountUnchanged(db, SqliteUsageError):
                    stmt.exec()
        finally:
            stmt.finalize()

test "stmt.iterate close/finalize":
    withDb:
        let stmt = db.stmt(SelectPersons)
        expectPreparedCountUnchanged(db, SqliteUsageError):
            for row in stmt.iterate():
                db.close()
        stmt.finalize()
    withDb:
        let stmt = db.stmt(SelectPersons)
        try:
            expectPreparedCountUnchanged(db, SqliteUsageError):
                for row in stmt.iterate():
                    stmt.finalize()
        finally:
            stmt.finalize()

test "stmt lifecycle changes are rejected during named parameter conversion":
    withDb:
        let stmt = db.stmt("SELECT :value")

        expectPreparedCountUnchanged(db, SqliteUsageError):
            discard stmt.value((value: ClosingParam(db: db),))
        check db.isOpen
        check stmt.isAlive

        expectPreparedCountUnchanged(db, SqliteUsageError):
            discard stmt.value((value: StatementLifecycleParam(
                statement: stmt, action: finalizeStatement),))
        check stmt.isAlive

        expectPreparedCountUnchanged(db, SqliteUsageError):
            discard stmt.value((value: StatementLifecycleParam(
                statement: stmt, action: reuseStatement),))
        check stmt.isAlive

        check stmt.value((value: toDb(27),)).get.intVal == 27
        stmt.finalize()

test "stmt.isAlive":
    withDb:
        var stmt: SqlStatement
        check not stmt.isAlive
        expect SqliteUsageError:
            discard stmt.all()
        stmt = db.stmt(SelectPersons)
        check stmt.isAlive
        stmt.finalize()
        check not stmt.isAlive
        expect SqliteUsageError:
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

test "OpenOptions controls statement caching":
    var options = defaultOpenOptions
    options.cacheSize = 0
    let uncached = openDatabase(":memory:", options)
    try:
        check uncached.preparedStatementCount == 0
        discard uncached.value("SELECT 1")
        check uncached.preparedStatementCount == 0
    finally:
        uncached.close()

    options.cacheSize = 1
    let cached = openDatabase(":memory:", options)
    try:
        check cached.preparedStatementCount == 1
        discard cached.value("SELECT 1")
        check cached.preparedStatementCount == 1
    finally:
        cached.close()

test "OpenOptions distinguishes all database open modes":
    let databasePath = getTempDir() / ("nim_sqlite_open_modes_" &
        $getCurrentProcessId() & "_" & $epochTime() & ".sqlite")
    var options = defaultOpenOptions
    options.cacheSize = 0
    try:
        options.mode = OpenMode.readOnly
        expect SqliteError:
            discard openDatabase(databasePath, options)
        check not fileExists(databasePath)

        options.mode = OpenMode.readWriteExisting
        expect SqliteError:
            discard openDatabase(databasePath, options)
        check not fileExists(databasePath)

        options.mode = OpenMode.readWriteCreate
        let created = openDatabase(databasePath, options)
        created.exec("CREATE TABLE Item(value INTEGER)")
        created.close()
        check fileExists(databasePath)

        options.mode = OpenMode.readWriteExisting
        let existing = openDatabase(databasePath, options)
        existing.exec("INSERT INTO Item(value) VALUES(1)")
        existing.close()

        options.mode = OpenMode.readOnly
        let readonly = openDatabase(databasePath, options)
        try:
            check readonly.isReadonly
            check readonly.value("SELECT COUNT(*) FROM Item").get.intVal == 1
            expect SqliteError:
                readonly.exec("INSERT INTO Item(value) VALUES(2)")
        finally:
            readonly.close()
    finally:
        if fileExists(databasePath):
            removeFile(databasePath)

test "OpenOptions busy timeout is installed and reports lock contention":
    let databasePath = getTempDir() / ("nim_sqlite_busy_timeout_" &
        $getCurrentProcessId() & "_" & $epochTime() & ".sqlite")
    var first, second: DbConn
    var options = defaultOpenOptions
    options.cacheSize = 0
    options.busyTimeoutMs = 25
    try:
        first = openDatabase(databasePath, options)
        second = openDatabase(databasePath, options)
        check second.value("PRAGMA busy_timeout").get.intVal == 25
        first.exec("CREATE TABLE Item(value INTEGER)")
        first.exec("BEGIN IMMEDIATE")
        var raised = false
        try:
            second.exec("INSERT INTO Item(value) VALUES(1)")
        except SqliteError as error:
            raised = true
            check error.primaryCode == int32(abi.SQLITE_BUSY)
            check error.operation == SqliteOperation.execute
        check raised
        first.exec("ROLLBACK")
    finally:
        second.close()
        first.close()
        if fileExists(databasePath):
            removeFile(databasePath)

test "OpenOptions URI filenames support shared in-memory databases":
    let databaseUri = "file:nim_sqlite_uri_" & $getCurrentProcessId() &
        "?mode=memory&cache=shared"
    var options = defaultOpenOptions
    options.cacheSize = 0
    options.uriFilename = true
    let first = openDatabase(databaseUri, options)
    let second = openDatabase(databaseUri, options)
    try:
        first.exec("CREATE TABLE Item(value INTEGER)")
        first.exec("INSERT INTO Item(value) VALUES(1)")
        check second.value("SELECT value FROM Item").get.intVal == 1
    finally:
        second.close()
        first.close()

when not defined(windows):
    test "OpenOptions noFollow rejects symbolic-link database paths":
        let suffix = $getCurrentProcessId() & "_" & $epochTime()
        let databasePath = getTempDir() / ("nim_sqlite_nofollow_" & suffix &
            ".sqlite")
        let linkPath = getTempDir() / ("nim_sqlite_nofollow_link_" & suffix &
            ".sqlite")
        var options = defaultOpenOptions
        options.cacheSize = 0
        try:
            let created = openDatabase(databasePath, options)
            created.close()
            createSymlink(databasePath, linkPath)

            options.mode = OpenMode.readOnly
            let followed = openDatabase(linkPath, options)
            followed.close()

            options.noFollow = true
            var raised = false
            try:
                discard openDatabase(linkPath, options)
            except SqliteError as error:
                raised = true
                check error.primaryCode == int32(abi.SQLITE_CANTOPEN)
                check error.operation == SqliteOperation.openDatabase
            check raised
        finally:
            if symlinkExists(linkPath):
                removeFile(linkPath)
            if fileExists(databasePath):
                removeFile(databasePath)

test "OpenOptions hardened profile configures SQLite defenses":
    var normalOptions = defaultOpenOptions
    normalOptions.cacheSize = 0
    let normal = openDatabase(":memory:", normalOptions)
    try:
        check normal.databaseConfigValue(abi.SQLITE_DBCONFIG_DEFENSIVE) == 0
        check normal.databaseConfigValue(abi.SQLITE_DBCONFIG_TRUSTED_SCHEMA) == 1
    finally:
        normal.close()

    var hardenedOptions = normalOptions
    hardenedOptions.securityProfile = SecurityProfile.hardened
    let hardened = openDatabase(":memory:", hardenedOptions)
    try:
        check hardened.databaseConfigValue(abi.SQLITE_DBCONFIG_DEFENSIVE) == 1
        check hardened.databaseConfigValue(abi.SQLITE_DBCONFIG_TRUSTED_SCHEMA) == 0
        hardened.exec("PRAGMA writable_schema = ON")
        check hardened.value("PRAGMA writable_schema").get.intVal == 0
    finally:
        hardened.close()

test "OpenOptions rejects busy timeouts outside SQLite range":
    for invalidTimeout in [-1'i64, int64(high(cint)) + 1]:
        var options = defaultOpenOptions
        options.busyTimeoutMs = invalidTimeout
        let memoryBefore = abi.sqlite3_memory_used()
        var raised = false
        try:
            discard openDatabase(":memory:", options)
        except SqliteError as error:
            raised = true
            check error.msg == "Busy timeout is out of range for SQLite."
            check error.operation == SqliteOperation.validation
            check error.primaryCode == int32(abi.SQLITE_OK)
            check error.extendedCode == int32(abi.SQLITE_OK)
        check raised
        check abi.sqlite3_memory_used() == memoryBefore

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

test "openDatabase rejects embedded NUL bytes":
    for mode in [dbReadWrite, dbRead]:
        var opened: DbConn
        expectSqliteErrorMessage "Database path contains an embedded NUL byte.":
            opened = openDatabase(":memory:\0ignored", mode)
        if opened.isOpen:
            opened.close()
        check not opened.isOpen

    var options = defaultOpenOptions
    var opened: DbConn
    expectSqliteErrorMessage "Database path contains an embedded NUL byte.":
        opened = openDatabase(":memory:\0ignored", options)
    check not opened.isOpen

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
        var duplicateTableRaised = false
        try:
            db.execScript("""
                CREATE TABLE Person(
                    name TEXT,
                    age INTEGER
                );
            """)
        except SqliteError as error:
            duplicateTableRaised = true
            check error.primaryCode == int32(abi.SQLITE_ERROR)
            check error.extendedCode == int32(abi.SQLITE_ERROR)
            check error.operation == SqliteOperation.prepare
            check error.sqliteMessage.len > 0
            check error.msg == "sqlite error: " & error.sqliteMessage
        check duplicateTableRaised

        var openRaised = false
        try:
            discard openDatabase("some/made/up/path", dbRead)
        except SqliteError as error:
            openRaised = true
            check error.primaryCode == int32(abi.SQLITE_CANTOPEN)
            check (error.extendedCode and 0xff) == int32(abi.SQLITE_CANTOPEN)
            check error.operation == SqliteOperation.openDatabase
            check error.sqliteMessage.len > 0
        check openRaised

test "SqliteError distinguishes extended result codes without bound values":
    withDb:
        const secret = "phase-2.2-bound-secret"
        db.exec("CREATE TABLE StructuredError(value TEXT UNIQUE)")
        db.exec("INSERT INTO StructuredError(value) VALUES(?)", secret)

        var raised = false
        try:
            db.exec("INSERT INTO StructuredError(value) VALUES(?)", secret)
        except SqliteError as error:
            raised = true
            check error.primaryCode == int32(abi.SQLITE_CONSTRAINT)
            check error.extendedCode == int32(abi.SQLITE_CONSTRAINT_UNIQUE)
            check error.operation == SqliteOperation.execute
            check error.sqliteMessage.len > 0
            check secret notin error.msg
            check secret notin error.sqliteMessage
        check raised

test "query errors capture SQLite state before statement cleanup":
    withDb:
        let preparedBefore = db.preparedStatementCount
        var raised = false
        try:
            discard db.all(LateRowErrorNamed, (fail: 1,))
        except SqliteError as error:
            raised = true
            check error.primaryCode == int32(abi.SQLITE_ERROR)
            check error.extendedCode == int32(abi.SQLITE_ERROR)
            check error.operation == SqliteOperation.execute
            check error.sqliteMessage.len > 0
        check raised
        check db.preparedStatementCount == preparedBefore + 1
        check db.value("SELECT 1").get.intVal == 1

test "library validation errors have structured categories without SQLite state":
    withDb:
        var raised = false
        try:
            db.exec("SELECT ?")
        except SqliteError as error:
            raised = true
            check error.primaryCode == int32(abi.SQLITE_OK)
            check error.extendedCode == int32(abi.SQLITE_OK)
            check error.operation == SqliteOperation.binding
            check error.sqliteMessage.len == 0
        check raised

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

test "toDb rejects ordinals outside SQLite INTEGER range":
    check toDb(uint64(high(int64))).intVal == high(int64)
    var raised = false
    try:
        discard toDb(high(uint64))
    except SqliteError as error:
        raised = true
        check error.msg == "Integer value is out of range for SQLite INTEGER."
        check $high(uint64) notin error.msg
        check error.primaryCode == int32(abi.SQLITE_OK)
        check error.extendedCode == int32(abi.SQLITE_OK)
        check error.operation == SqliteOperation.conversion
        check error.sqliteMessage.len == 0
    check raised
    expect SqliteError:
        discard toDb(WideUnsignedRange(high(uint64)))

    when sizeof(uint) == sizeof(uint64):
        check toDb(uint(high(int64))).intVal == high(int64)
        expect SqliteError:
            discard toDb(high(uint))

test "ordinal binding failures release statements":
    const sql = "SELECT :value"
    for cacheSize in [0, 1]:
        let db = openDatabase(":memory:", cacheSize = cacheSize)
        try:
            check db.value(sql, (value: uint64(high(int64)),)).get.intVal == high(int64)
            let statementsBefore = db.preparedStatementCount
            expectPreparedCountUnchanged(db, SqliteError):
                discard db.value(sql, (value: high(uint64),))
            check db.value(sql, (value: uint64(high(int64)),)).get.intVal == high(int64)
            check db.preparedStatementCount == statementsBefore
        finally:
            db.close()

    let db = openDatabase(":memory:")
    let statement = db.stmt(sql)
    try:
        expectPreparedCountUnchanged(db, SqliteError):
            discard statement.value((value: high(uint64),))
        check statement.value((value: 42'u64,)).get.intVal == 42
    finally:
        statement.finalize()
        db.close()

test "fromDb validates ordinal ranges":
    let minimum = DbValue(kind: sqliteInteger, intVal: low(int64))
    let maximum = DbValue(kind: sqliteInteger, intVal: high(int64))
    check minimum.fromDb(int64) == low(int64)
    check maximum.fromDb(int64) == high(int64)
    check maximum.fromDb(uint64) == uint64(high(int64))

    check toDb(-128).fromDb(int8) == -128
    check toDb(127).fromDb(int8) == 127
    expectSqliteErrorMessage(
            "SQLite INTEGER value -129 is out of range for int8."):
        discard toDb(-129).fromDb(int8)
    expectSqliteErrorMessage(
            "SQLite INTEGER value 128 is out of range for int8."):
        discard toDb(128).fromDb(int8)

    check toDb(0).fromDb(uint8) == 0
    check toDb(255).fromDb(uint8) == 255
    expect SqliteError:
        discard toDb(-1).fromDb(uint8)
    expect SqliteError:
        discard toDb(256).fromDb(uint8)

    check not toDb(0).fromDb(bool)
    check toDb(1).fromDb(bool)
    expect SqliteError:
        discard toDb(-1).fromDb(bool)
    expect SqliteError:
        discard toDb(2).fromDb(bool)

    check toDb(0).fromDb(TestEnum) == enumZero
    check toDb(2).fromDb(TestEnum) == enumTwo
    expect SqliteError:
        discard toDb(-1).fromDb(TestEnum)
    expect SqliteError:
        discard toDb(3).fromDb(TestEnum)

    check toDb(-2).fromDb(SmallIntegerRange) == -2
    check toDb(2).fromDb(SmallIntegerRange) == 2
    expect SqliteError:
        discard toDb(-3).fromDb(SmallIntegerRange)
    expect SqliteError:
        discard toDb(3).fromDb(SmallIntegerRange)

    check toDb(255).fromDb(char) == '\xff'
    expect SqliteError:
        discard toDb(256).fromDb(char)

test "ordinal decoding failures release statements":
    for cacheSize in [0, 1]:
        let db = openDatabase(":memory:", cacheSize = cacheSize)
        try:
            check db.value("SELECT 128").get.fromDb(int16) == 128
            let statementsBefore = db.preparedStatementCount
            expectPreparedCountUnchanged(db, SqliteError):
                for row in db.iterate("SELECT 128"):
                    discard row.unpack((int8,))
            check db.value("SELECT 128").get.fromDb(int16) == 128
            check db.preparedStatementCount == statementsBefore
        finally:
            db.close()

    let db = openDatabase(":memory:")
    let statement = db.stmt("SELECT 128")
    try:
        expectPreparedCountUnchanged(db, SqliteError):
            for row in statement.iterate():
                discard row.unpack((int8,))
        check statement.value().get.fromDb(int16) == 128
    finally:
        statement.finalize()
        db.close()

test "fromDb returns the requested floating-point type":
    let single: float32 = toDb(1.25).fromDb(float32)
    let double: float64 = toDb(1.25).fromDb(float64)
    check single == 1.25'f32
    check double == 1.25'f64

test "changes uses SQLite's 64-bit result API":
    withDb:
        db.exec("CREATE TABLE ChangeCount(value)")
        db.exec("INSERT INTO ChangeCount(value) VALUES (1), (2), (3)")
        let changed = db.changes
        check changed is int64
        check changed == 3'i64

test "fromDb validates the SQLite storage class":
    expect SqliteError:
        discard toDb("1").fromDb(int)
    expect SqliteError:
        discard toDb(1).fromDb(float)
    expect SqliteError:
        discard toDb(1).fromDb(string)
    expect SqliteError:
        discard toDb(1).fromDb(seq[byte])
    expect SqliteError:
        discard toDb(nil).fromDb(int)
    expect SqliteError:
        discard toDb("1").fromDb(Option[int])

    withDb:
        db.exec("CREATE TABLE MixedStorage(value)")
        db.exec("INSERT INTO MixedStorage(value) VALUES(?)", 1)
        db.exec("INSERT INTO MixedStorage(value) VALUES(?)", "not an integer")
        let rows = db.all("SELECT value FROM MixedStorage ORDER BY rowid")
        check rows[0].unpack((int,)) == (1,)
        expect SqliteError:
            discard rows[1].unpack((int,))

proc toDb(t: Time): DbValue =
    DbValue(kind: sqliteInteger, intVal: toUnix(t))

proc fromDb(value: DbValue, T: typedesc[Time]): Time =
    fromUnix(value.fromDb(int))

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
        var raised = false
        try:
            db.exec("INSERT INTO ForeignKey(personId) VALUES(100)")
        except SqliteError as error:
            raised = true
            check error.primaryCode == int32(abi.SQLITE_CONSTRAINT)
            check error.extendedCode == int32(abi.SQLITE_CONSTRAINT_FOREIGNKEY)
            check error.operation == SqliteOperation.execute
        check raised
