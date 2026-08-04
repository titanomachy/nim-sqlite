## .. include:: ./nim_sqlite/private/documentation.rst

import std / [options, typetraits, sequtils]
from pkg / sqlite3_abi as abi import nil
import nim_sqlite / private / stmtcache

when not declared(tupleLen):
    import macros
    macro tupleLen(typ: typedesc[tuple]): int =
        let impl = getType(typ)
        result = newIntlitNode(impl[1].len - 1)

export options.get, options.isSome, options.isNone

type
    DbConnImpl = ref object 
        handle: ptr abi.sqlite3 ## The underlying SQLite3 handle
        cache: StmtCache

    DbConn* = distinct DbConnImpl ## Encapsulates a database connection.

    SqlStatementImpl = ref object
        handle: ptr abi.sqlite3_stmt
        db: DbConn

    SqlStatement* = distinct SqlStatementImpl ## A prepared SQL statement.

    DbMode* = enum
        dbRead,
        dbReadWrite

    SqliteError* = object of CatchableError ## \
        ## Raised when whenever a database related error occurs.
        ## Errors are typically a result of API misuse,
        ## e.g trying to close an already closed database connection.

    DbValueKind* = enum ## \
        ## Enum of all possible value types in a SQLite database.
        sqliteNull,
        sqliteInteger,
        sqliteReal,
        sqliteText,
        sqliteBlob

    DbValue* = object ## \
        ## Can represent any value in a SQLite database.
        case kind*: DbValueKind
        of sqliteInteger:
            intVal*: int64
        of sqliteReal:
            floatVal*: float64
        of sqliteText:
            strVal*: string
        of sqliteBlob:
            blobVal*: seq[byte]
        of sqliteNull:
            discard

    Rc = cint

    StmtLease = object
        handle: ptr abi.sqlite3_stmt
        cached: bool
        key: string

    ResultRow* = object
        values: seq[DbValue]
        columns: seq[string]

const SqliteRcOk = [ abi.SQLITE_OK, abi.SQLITE_DONE, abi.SQLITE_ROW ]

# Forward declarations
proc isInTransaction*(db: DbConn): bool {.noSideEffect.}
proc isOpen*(db: DbConn): bool {.noSideEffect, inline.}
proc isAlive*(statement: SqlStatement): bool {.noSideEffect.}

template handle(db: DbConn): ptr abi.sqlite3 = DbConnImpl(db).handle
template handle(statement: SqlStatement): ptr abi.sqlite3_stmt = SqlStatementImpl(statement).handle
template db(statement: SqlStatement): DbConn = SqlStatementImpl(statement).db
template cache(db: DbConn): StmtCache = DbConnImpl(db).cache

template hasCache(db: DbConn): bool = db.cache.capacity > 0

template assertCanUseDb(db: DbConn) =
    doAssert (not DbConnImpl(db).isNil) and (not db.handle.isNil), "Database is closed"

template assertCanUseStatement(statement: SqlStatement, busyOk: static[bool] = false) =
    doAssert (not SqlStatementImpl(statement).isNil) and (not statement.handle.isNil),
        "Statement cannot be used because it has already been finalized."
    doAssert not statement.db.handle.isNil,
        "Statement cannot be used because the database connection has been closed"
    when not busyOk:
        doAssert 0 == abi.sqlite3_stmt_busy(statement.handle),
            "Statement cannot be used while inside the 'all' iterator"

proc newSqliteError(db: DbConn): ref SqliteError =
    ## Raises a SqliteError exception.
    (ref SqliteError)(msg: "sqlite error: " & $abi.sqlite3_errmsg(db.handle))

proc newSqliteError(msg: string): ref SqliteError =
    ## Raises a SqliteError exception.
    (ref SqliteError)(msg: msg)

template checkRc(db: DbConn, rc: Rc) =
    if rc notin SqliteRcOk:
        raise newSqliteError(db)

proc skipLeadingWhiteSpaceAndComments(sql: var cstring) =
    let original = sql

    template `&+`(s: cstring, offset: int): cstring =
        cast[cstring](cast[uint](s) + offset.uint)

    while true:
        case sql[0]
        of {' ', '\t', '\v', '\r', '\l', '\f'}:
            sql = sql &+ 1
        of '-':
            if sql[1] == '-':
                sql = sql &+ 2
                while sql[0] != '\n':
                    sql = sql &+ 1
                    if sql[0] == '\0':
                        return
                sql = sql &+ 1
            else:
                return;
        of '/':
            if sql[1] == '*':
                sql = sql &+ 2
                while sql[0] != '*' or sql[1] != '/':
                    sql = sql &+ 1
                    if sql[0] == '\0':
                        sql = original
                        return
                sql = sql &+ 2
            else:
                return;
        else:
            return

proc resetStmt(stmtHandle: ptr abi.sqlite3_stmt) =
    discard abi.sqlite3_reset(stmtHandle)
    discard abi.sqlite3_clear_bindings(stmtHandle)

#
# DbValue
#

proc toDb*[T: Ordinal](val: T): DbValue =
    ## Convert an ordinal value to a DbValue.
    DbValue(kind: sqliteInteger, intVal: val.int64)

proc toDb*[T: SomeFloat](val: T): DbValue =
    ## Convert a float to a DbValue.
    DbValue(kind: sqliteReal, floatVal: val)

proc toDb*[T: string](val: T): DbValue =
    ## Convert a string to a DbValue.
    DbValue(kind: sqliteText, strVal: val)

proc toDb*[T: seq[byte]](val: T): DbValue =
    ## Convert a sequence of bytes to a DbValue.
    DbValue(kind: sqliteBlob, blobVal: val)

proc toDb*[T: Option](val: T): DbValue =
    ## Convert an optional value to a DbValue.
    if val.isNone:
        DbValue(kind: sqliteNull)
    else:
        toDb(val.get)

proc toDb*[T: type(nil)](val: T): DbValue =
    ## Convert a nil literal to a DbValue.
    DbValue(kind: sqliteNull)

proc fromDb*(value: DbValue, T: typedesc[Ordinal]): T =
    ## Convert a DbValue to an ordinal.
    value.intVal.T

proc fromDb*(value: DbValue, T: typedesc[SomeFloat]): float64 =
    ## Convert a DbValue to a float.
    value.floatVal

proc fromDb*(value: DbValue, T: typedesc[string]): string =
    ## Convert a DbValue to a string.
    value.strVal

proc fromDb*(value: DbValue, T: typedesc[seq[byte]]): seq[byte] =
    ## Convert a DbValue to a sequence of bytes.
    value.blobVal

proc fromDb*[T](value: DbValue, _: typedesc[Option[T]]): Option[T] =
    ## Convert a DbValue to an optional value.
    if value.kind == sqliteNull:
        none(T)
    else:
        some(value.fromDb(T))

proc fromDb*(value: DbValue, T: typedesc[DbValue]): T =
    ## Special overload that simply return `value`.
    ## The purpose of this overload is to do partial unpacking.
    ## For example, if the type of one column in a result row is unknown,
    ## the DbValue type can be kept just for that column.
    ## 
    ## .. code-block:: nim
    ## 
    ##   for row in db.iterate("SELECT name, extra FROM Person"):
    ##       # Type of 'extra' is unknown, so we don't unpack it.
    ##       # The 'extra' variable will be of type 'DbValue'
    ##       let (name, extra) = row.unpack((string, DbValue))
    value

proc `$`*(dbVal: DbValue): string =
    result.add "DbValue["
    case dbVal.kind
    of sqliteInteger: result.add $dbVal.intVal
    of sqliteReal:    result.add $dbVal.floatVal
    of sqliteText:    result.addQuoted dbVal.strVal
    of sqliteBlob:    result.add "<blob>"
    of sqliteNull:    result.add "nil"
    result.add "]"

proc `==`*(a, b: DbValue): bool =
    ## Returns true if `a` and `b` represents the same value.
    if a.kind != b.kind:
        false
    else:
        case a.kind
        of sqliteInteger: a.intVal == b.intVal
        of sqliteReal:    a.floatVal == b.floatVal
        of sqliteText:    a.strVal == b.strVal
        of sqliteBlob:    a.blobVal == b.blobVal
        of sqliteNull:    true

#
# PStmt
#

proc bindValue(stmtHandle: ptr abi.sqlite3_stmt, idx: int32, value: DbValue): Rc =
    case value.kind
    of sqliteNull:
        abi.sqlite3_bind_null(stmtHandle, idx)
    of sqliteInteger:
        abi.sqlite3_bind_int64(stmtHandle, idx, value.intval)
    of sqliteReal:
        abi.sqlite3_bind_double(stmtHandle, idx, value.floatVal)
    of sqliteText:
        abi.sqlite3_bind_text(stmtHandle, idx, value.strVal.cstring, value.strVal.len.int32,
            abi.SQLITE_TRANSIENT)
    of sqliteBlob:
        abi.sqlite3_bind_blob(stmtHandle, idx, cast[string](value.blobVal).cstring,
            value.blobVal.len.int32, abi.SQLITE_TRANSIENT)

proc bindParams(db: DbConn, stmtHandle: ptr abi.sqlite3_stmt, params: varargs[DbValue]): Rc =
    result = abi.SQLITE_OK
    let expectedParamsLen = abi.sqlite3_bind_parameter_count(stmtHandle)
    if expectedParamsLen != params.len:
        raise newSqliteError("SQL statement contains " & $expectedParamsLen &
            " parameters but only " & $params.len & " was provided.")

    var idx = 1'i32
    for value in params:
        result = bindValue(stmtHandle, idx, value)
        if result notin SqliteRcOk:
            return
        idx.inc

proc bindNamedParams[T: tuple](db: DbConn, stmtHandle: ptr abi.sqlite3_stmt,
        params: T): Rc =
    mixin toDb

    result = abi.SQLITE_OK
    let expectedParamsLen = abi.sqlite3_bind_parameter_count(stmtHandle)
    var bound = newSeq[bool](expectedParamsLen + 1)

    for name, value in fieldPairs(params):
        let parameterName = ":" & name
        let idx = abi.sqlite3_bind_parameter_index(stmtHandle, parameterName.cstring)
        if idx == 0:
            raise newSqliteError("SQL statement does not contain named parameter '" &
                parameterName & "'.")
        if bound[idx]:
            raise newSqliteError("Named parameter '" & parameterName &
                "' was provided more than once.")

        let dbValue =
            when value is DbValue:
                value
            else:
                toDb(value)
        result = bindValue(stmtHandle, idx, dbValue)
        if result notin SqliteRcOk:
            return
        bound[idx] = true

    for idx in 1'i32 .. expectedParamsLen:
        let parameterName = abi.sqlite3_bind_parameter_name(stmtHandle, idx)
        if parameterName.isNil:
            raise newSqliteError("Named parameter binding cannot bind positional parameter " &
                $idx & ".")
        if not bound[idx]:
            raise newSqliteError("No value was provided for named parameter '" &
                $parameterName & "'.")

proc prepareSql(db: DbConn, sql: string): ptr abi.sqlite3_stmt =
    var tail: cstring
    let rc = abi.sqlite3_prepare_v2(db.handle, sql.cstring, sql.len.cint + 1, addr result, addr tail)
    # (db.handle, sql.cstring, sql.len.cint + 1, addr result, tail)
    db.checkRc(rc)
    tail.skipLeadingWhiteSpaceAndComments()
    assert tail.len == 0,
        "Only single SQL statement is allowed in this context. " &
        "To execute several SQL statements, use 'execScript'"

proc acquireStmt(db: DbConn, sql: string): StmtLease =
    if db.hasCache:
        let cachedHandle = db.cache.tryAcquire(sql)
        if not cachedHandle.isNil:
            return StmtLease(handle: cachedHandle, cached: true, key: sql)

    result.handle = db.prepareSql(sql)
    if db.hasCache:
        result.cached = db.cache.tryAdd(sql, result.handle, leased = true)
        if result.cached:
            result.key = sql

proc releaseStmt(db: DbConn, lease: var StmtLease) =
    if lease.handle.isNil:
        return
    if lease.cached:
        # Closing the database finalizes all cache-owned statements. If the
        # database is still open, return this lease to the cache in clean state.
        if db.isOpen:
            resetStmt(lease.handle)
            db.cache.release(lease.key, lease.handle)
    else:
        # Temporary leases retain ownership across sqlite3_close_v2 and must
        # always be finalized by the operation that acquired them.
        discard abi.sqlite3_finalize(lease.handle)
    lease.handle = nil

proc readColumn(stmtHandle: ptr abi.sqlite3_stmt, col: int32): DbValue =
    let columnType = abi.sqlite3_column_type(stmtHandle, col)
    case columnType
    of abi.SQLITE_INTEGER:
        result = toDb(abi.sqlite3_column_int64(stmtHandle, col))
    of abi.SQLITE_FLOAT:
        result = toDb(abi.sqlite3_column_double(stmtHandle, col))
    of abi.SQLITE_TEXT:
        result = toDb($abi.sqlite3_column_text(stmtHandle, col))
    of abi.SQLITE_BLOB:
        let blob = abi.sqlite3_column_blob(stmtHandle, col)
        let bytes = abi.sqlite3_column_bytes(stmtHandle, col)
        var s = newSeq[byte](bytes)
        if bytes != 0:
            copyMem(addr(s[0]), blob, bytes)
        result = toDb(s)
    of abi.SQLITE_NULL:
        result = toDb(nil)
    else:
        raiseAssert "Unexpected column type: " & $columnType

iterator iterateRows(db: DbConn, stmtOrHandle: ptr abi.sqlite3_stmt | SqlStatement,
        errorRc: var int32): ResultRow =
    let stmtHandle = when stmtOrHandle is ptr abi.sqlite3_stmt: stmtOrHandle else: stmtOrHandle.handle
    if errorRc in SqliteRcOk:
        var rowLen = abi.sqlite3_column_count(stmtHandle)
        var columns = newSeq[string](rowLen)
        for idx in 0 ..< rowLen:
            columns[idx] = $abi.sqlite3_column_name(stmtHandle, idx)
        while true:
            var row = ResultRow(values: newSeq[DbValue](rowLen), columns: columns)
            when stmtOrHandle is ptr abi.sqlite3_stmt:
                assertCanUseDb db
            else:
                assertCanUseStatement stmtOrHandle, busyOk = true
            let rc = abi.sqlite3_step(stmtHandle)
            if rc == abi.SQLITE_ROW:
                for idx in 0 ..< rowLen:
                    row.values[idx] = readColumn(stmtHandle, idx)
                yield row
            elif rc == abi.SQLITE_DONE:
                break
            else:
                errorRc = rc
                break

iterator iteratePositional(db: DbConn, stmtOrHandle: ptr abi.sqlite3_stmt | SqlStatement,
        params: varargs[DbValue], errorRc: var int32): ResultRow =
    let stmtHandle = when stmtOrHandle is ptr abi.sqlite3_stmt: stmtOrHandle else: stmtOrHandle.handle
    errorRc = db.bindParams(stmtHandle, params)
    for row in db.iterateRows(stmtOrHandle, errorRc):
        yield row

iterator iterateNamed[T: tuple](db: DbConn,
        stmtOrHandle: ptr abi.sqlite3_stmt | SqlStatement, params: T,
        errorRc: var int32): ResultRow =
    let stmtHandle = when stmtOrHandle is ptr abi.sqlite3_stmt: stmtOrHandle else: stmtOrHandle.handle
    errorRc = db.bindNamedParams(stmtHandle, params)
    for row in db.iterateRows(stmtOrHandle, errorRc):
        yield row

#
# DbConn
#

proc exec*(db: DbConn, sql: string, params: varargs[DbValue, toDb]) =
    ## Executes ``sql``, which must be a single SQL statement.
    runnableExamples:
        let db = openDatabase(":memory:")
        db.exec("CREATE TABLE Person(name, age)")
        db.exec("INSERT INTO Person(name, age) VALUES(?, ?)",
            "John Doe", 23)
    assertCanUseDb db
    var lease = db.acquireStmt(sql)
    var rc: Rc = abi.SQLITE_OK
    try:
        rc = db.bindParams(lease.handle, params)
        if rc in SqliteRcOk:
            rc = abi.sqlite3_step(lease.handle)
    finally:
        db.releaseStmt(lease)
    db.checkRc(rc)

proc exec*[T: tuple](db: DbConn, sql: string, params: T) =
    ## Executes ``sql`` using a named tuple whose field names correspond to
    ## ``:name`` parameters. Tuple field order does not affect binding.
    runnableExamples:
        let db = openDatabase(":memory:")
        db.exec("CREATE TABLE Person(name, age)")
        db.exec("INSERT INTO Person(name, age) VALUES(:name, :age)",
            (age: 23, name: "John Doe"))
    assertCanUseDb db
    var lease = db.acquireStmt(sql)
    var rc: Rc = abi.SQLITE_OK
    try:
        rc = db.bindNamedParams(lease.handle, params)
        if rc in SqliteRcOk:
            rc = abi.sqlite3_step(lease.handle)
    finally:
        db.releaseStmt(lease)
    db.checkRc(rc)

template transaction*(db: DbConn, body: untyped) =
    ## Starts a transaction and runs `body` within it. At the end the transaction is commited.
    ## If an error is raised by `body` the transaction is rolled back. Nesting transactions is a no-op.
    if db.isInTransaction:
        body
    else:
        db.exec("BEGIN")
        var ok = true
        try:
            try:
                body
            except Exception:
                ok = false
                db.exec("ROLLBACK")
                raise
        finally:
            if ok:
                db.exec("COMMIT")

proc execMany*(db: DbConn, sql: string, params: seq[seq[DbValue]]) =
    ## Executes ``sql``, which must be a single SQL statement, repeatedly using each element of
    ## ``params`` as parameters. The statements are executed inside a transaction.
    assertCanUseDb db
    db.transaction:
        for p in params:
            db.exec(sql, p)

proc execMany*[T: tuple](db: DbConn, sql: string, params: openArray[T]) =
    ## Executes ``sql`` repeatedly using named tuples as parameters. Tuple
    ## field names correspond to ``:name`` parameters.
    assertCanUseDb db
    db.transaction:
        for p in params:
            db.exec(sql, p)

proc execScript*(db: DbConn, sql: string) =
    ## Executes ``sql``, which can consist of multiple SQL statements.
    ## The statements are executed inside a transaction.
    assertCanUseDb db
    db.transaction:
        var remaining = sql.cstring
        while remaining.len > 0:
            var tail: cstring
            var stmtHandle: ptr abi.sqlite3_stmt
            var rc = abi.sqlite3_prepare_v2(db.handle, remaining, -1, addr stmtHandle, addr tail)
            db.checkRc(rc)
            rc = abi.sqlite3_step(stmtHandle)
            discard abi.sqlite3_finalize(stmtHandle)
            db.checkRc(rc)
            remaining = tail
            remaining.skipLeadingWhiteSpaceAndComments()

iterator iterate*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): ResultRow =
    ## Executes ``sql``, which must be a single SQL statement, and yields each result row one by one.
    assertCanUseDb db
    var lease = db.acquireStmt(sql)
    var errorRc: int32 = abi.SQLITE_OK
    try:
        for row in db.iteratePositional(lease.handle, params, errorRc):
            yield row
    finally:
        db.releaseStmt(lease)
        db.checkRc(errorRc)

iterator iterate*[T: tuple](db: DbConn, sql: string, params: T): ResultRow =
    ## Executes ``sql`` using named ``:name`` parameters and yields each
    ## result row. Tuple field order does not affect binding.
    assertCanUseDb db
    var lease = db.acquireStmt(sql)
    var errorRc: int32 = abi.SQLITE_OK
    try:
        for row in db.iterateNamed(lease.handle, params, errorRc):
            yield row
    finally:
        db.releaseStmt(lease)
        db.checkRc(errorRc)

proc all*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): seq[ResultRow] =
    ## Executes ``sql``, which must be a single SQL statement, and returns all result rows.
    for row in db.iterate(sql, params):
        result.add row

proc all*[T: tuple](db: DbConn, sql: string, params: T): seq[ResultRow] =
    ## Executes ``sql`` using named ``:name`` parameters and returns all rows.
    for row in db.iterate(sql, params):
        result.add row

proc one*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): Option[ResultRow] =
    ## Executes `sql`, which must be a single SQL statement, and returns the first result row.
    ## Returns `none(seq[DbValue])` if the result was empty.
    for row in db.iterate(sql, params):
        return some(row)

proc one*[T: tuple](db: DbConn, sql: string, params: T): Option[ResultRow] =
    ## Executes ``sql`` using named ``:name`` parameters and returns the first row.
    for row in db.iterate(sql, params):
        return some(row)

proc value*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): Option[DbValue] =
    ## Executes `sql`, which must be a single SQL statement, and returns the first column of the first result row.
    ## Returns `none(DbValue)` if the result was empty.
    for row in db.iterate(sql, params):
        return some(row.values[0])

proc value*[T: tuple](db: DbConn, sql: string, params: T): Option[DbValue] =
    ## Executes ``sql`` using named ``:name`` parameters and returns the first
    ## column of the first row.
    for row in db.iterate(sql, params):
        return some(row.values[0])

proc close*(db: DbConn) =
    ## Logically closes the database connection. Cached statements are finalized
    ## immediately. Explicit statements created with `stmt` retain ownership of
    ## their handles and must still be finalized, even after the connection has
    ## been closed. SQLite releases the underlying connection after the last such
    ## statement is finalized.
    ##
    ## Closing an already closed database is a harmless no-op.
    if not db.isOpen:
        return
    db.cache.clear()
    let rc = abi.sqlite3_close_v2(db.handle)
    db.checkRc(rc)
    DbConnImpl(db).handle = nil

proc lastInsertRowId*(db: DbConn): int64 =
    ## Get the row id of the last inserted row.
    ## For tables with an integer primary key,
    ## the row id will be the primary key.
    ##
    ## For more information, refer to the SQLite documentation
    ## (https://www.sqlite.org/c3ref/last_insert_rowid.html).
    assertCanUseDb db
    abi.sqlite3_last_insert_rowid(db.handle)

proc changes*(db: DbConn): int32 =
    ## Get the number of changes triggered by the most recent INSERT, UPDATE or
    ## DELETE statement.
    ##
    ## For more information, refer to the SQLite documentation
    ## (https://www.sqlite.org/c3ref/changes.html).
    assertCanUseDb db
    abi.sqlite3_changes(db.handle)

proc isReadonly*(db: DbConn): bool =
    ## Returns true if ``db`` is in readonly mode.
    runnableExamples:
        let db = openDatabase(":memory:")
        doAssert not db.isReadonly
        let db2 = openDatabase(":memory:", dbRead)
        doAssert db2.isReadonly
    assertCanUseDb db
    abi.sqlite3_db_readonly(db.handle, "main") == 1

proc isOpen*(db: DbConn): bool {.inline.} =
    ## Returns true if `db` has been opened and not yet closed.
    runnableExamples:
        var db: DbConn
        doAssert not db.isOpen
        db = openDatabase(":memory:")
        doAssert db.isOpen
        db.close()
        doAssert not db.isOpen
    (not DbConnImpl(db).isNil) and (not db.handle.isNil)

proc isInTransaction*(db: DbConn): bool =
    ## Returns true if a transaction is currently active.
    runnableExamples:
        let db = openDatabase(":memory:")
        doAssert not db.isInTransaction
        db.transaction:
            doAssert db.isInTransaction
    assertCanUseDb db
    abi.sqlite3_get_autocommit(db.handle) == 0

proc unsafeHandle*(db: DbConn): ptr abi.sqlite3 {.inline.} =
    ## Returns the raw SQLite3 handle. This can be used to interact directly with the SQLite C API
    ## with the `sqlite3_abi` package. Note that the handle should not be used after `db.close` has
    ## been called as doing so would break memory safety.
    assert not DbConnImpl(db).handle.isNil, "Database is closed"
    DbConnImpl(db).handle

#
# SqlStatement
#

proc stmt*(db: DbConn, sql: string): SqlStatement =
    ## Constructs a prepared statement from `sql`. The returned statement owns
    ## its SQLite handle and must be finalized independently, including when the
    ## database connection is closed first.
    assertCanUseDb db
    let handle = prepareSql(db, sql)
    SqlStatementImpl(handle: handle, db: db).SqlStatement
    
proc exec*(statement: SqlStatement, params: varargs[DbValue, toDb]) =
    ## Executes `statement` with `params` as parameters.
    assertCanUseStatement statement
    var rc = statement.db.bindParams(statement.handle, params)
    if rc notin SqliteRcOk:
        resetStmt(statement.handle)
        statement.db.checkRc(rc)
    else:
        rc = abi.sqlite3_step(statement.handle)
        resetStmt(statement.handle)
        statement.db.checkRc(rc)

proc exec*[T: tuple](statement: SqlStatement, params: T) =
    ## Executes `statement` using named ``:name`` parameters. Tuple field
    ## order does not affect binding.
    assertCanUseStatement statement
    var rc: Rc = abi.SQLITE_OK
    try:
        rc = statement.db.bindNamedParams(statement.handle, params)
        if rc in SqliteRcOk:
            rc = abi.sqlite3_step(statement.handle)
    finally:
        resetStmt(statement.handle)
    statement.db.checkRc(rc)

proc execMany*(statement: SqlStatement, params: seq[seq[DbValue]]) =
    ## Executes ``statement`` repeatedly using each element of ``params`` as parameters.
    ## The statements are executed inside a transaction.
    assertCanUseStatement statement
    statement.db.transaction:
        for p in params:
            statement.exec(p)

proc execMany*[T: tuple](statement: SqlStatement, params: openArray[T]) =
    ## Executes `statement` repeatedly using named tuples as parameters.
    assertCanUseStatement statement
    statement.db.transaction:
        for p in params:
            statement.exec(p)

iterator iterate*(statement: SqlStatement, params: varargs[DbValue, toDb]): ResultRow =
    ## Executes ``statement`` and yields each result row one by one.
    assertCanUseStatement statement
    var errorRc: int32
    try:
        for row in statement.db.iteratePositional(statement, params, errorRc):
            yield row
    finally:
        # The database might have been closed while iterating, in which
        # case we don't need to clean up the statement.
        if statement.isAlive:
            resetStmt(statement.handle)
        statement.db.checkRc errorRc

iterator iterate*[T: tuple](statement: SqlStatement, params: T): ResultRow =
    ## Executes `statement` using named ``:name`` parameters and yields each row.
    assertCanUseStatement statement
    var errorRc: int32
    try:
        for row in statement.db.iterateNamed(statement, params, errorRc):
            yield row
    finally:
        if statement.isAlive:
            resetStmt(statement.handle)
        statement.db.checkRc errorRc

proc all*(statement: SqlStatement, params: varargs[DbValue, toDb]): seq[ResultRow] =
    ## Executes ``statement`` and returns all result rows.
    assertCanUseStatement statement
    for row in statement.iterate(params):
        result.add row

proc all*[T: tuple](statement: SqlStatement, params: T): seq[ResultRow] =
    ## Executes `statement` using named ``:name`` parameters and returns all rows.
    assertCanUseStatement statement
    for row in statement.iterate(params):
        result.add row

proc one*(statement: SqlStatement,
        params: varargs[DbValue, toDb]): Option[ResultRow] =
    ## Executes `statement` and returns the first row found.
    ## Returns `none(seq[DbValue])` if no result was found.
    assertCanUseStatement statement
    for row in statement.iterate(params):
        return some(row)

proc one*[T: tuple](statement: SqlStatement, params: T): Option[ResultRow] =
    ## Executes `statement` using named ``:name`` parameters and returns the first row.
    assertCanUseStatement statement
    for row in statement.iterate(params):
        return some(row)

proc value*(statement: SqlStatement,
        params: varargs[DbValue, toDb]): Option[DbValue] =
    ## Executes `statement` and returns the first column of the first row found. 
    ## Returns `none(DbValue)` if no result was found.
    assertCanUseStatement statement
    for row in statement.iterate(params):
        return some(row.values[0])

proc value*[T: tuple](statement: SqlStatement, params: T): Option[DbValue] =
    ## Executes `statement` using named ``:name`` parameters and returns the
    ## first column of the first row.
    assertCanUseStatement statement
    for row in statement.iterate(params):
        return some(row.values[0])

proc finalize*(statement: SqlStatement): void =
    ## Finalizes the statement and releases its SQLite handle. This must be
    ## called once the statement is no longer used, including if its database
    ## connection has already been closed. Finalizing an already finalized
    ## statement is a harmless no-op.
    if SqlStatementImpl(statement).isNil or statement.handle.isNil:
        return
    discard abi.sqlite3_finalize(statement.handle)
    SqlStatementImpl(statement).handle = nil

proc isAlive*(statement: SqlStatement): bool =
    ## Returns true if ``statement`` can be executed. A statement whose database
    ## has been closed returns false, but still owns its handle until `finalize`
    ## is called.
    (not SqlStatementImpl(statement).isNil) and (not statement.handle.isNil) and
        (not statement.db.handle.isNil)

proc openDatabase*(path: string, mode = dbReadWrite, cacheSize: Natural = 100): DbConn =
    ## Open a new database connection to a database file. To create an
    ## in-memory database the special path `":memory:"` can be used.
    ## If the database doesn't already exist and ``mode`` is ``dbReadWrite``,
    ## the database will be created. If the database doesn't exist and ``mode``
    ## is ``dbRead``, a ``SqliteError`` exception will be raised.
    ##
    ## NOTE: To avoid memory leaks, ``db.close`` must be called when the
    ## database connection is no longer needed.
    ##
    ## Connection-level operations lease cached statements exclusively. If a
    ## cached statement is already leased or busy during nested or reentrant
    ## execution, a temporary statement is used and finalized after that
    ## operation. Leased and busy statements are not evicted from the cache.
    runnableExamples:
        let memDb = openDatabase(":memory:")
    var handle: ptr abi.sqlite3
    let db = new DbConnImpl
    db.handle = handle
    if cacheSize > 0:
        db.cache = initStmtCache(cacheSize)
    result = DbConn(db)
    case mode
    of dbReadWrite:
        let rc = abi.sqlite3_open(path, addr db.handle)
        result.checkRc(rc)
    of dbRead:
        let rc = abi.sqlite3_open_v2(path, addr db.handle, abi.SQLITE_OPEN_READONLY, nil)
        result.checkRc(rc)
    result.exec("PRAGMA encoding = 'UTF-8'")
    result.exec("PRAGMA foreign_keys = ON")

proc loadExtension*(db: DbConn, path: string) =
    ## Load an SQLite extension. Will raise a ``SqliteError`` exception if loading fails.
    assertCanUseDb db
    db.checkRc abi.sqlite3_db_config(db.handle, abi.SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1, 0);
    var err: cstring
    if abi.SQLITE_ERROR == abi.sqlite3_load_extension(db.handle, path.cstring, nil, addr err):
      if err == nil:
        raise newSqliteError("Unable to load extension.")
      else:
        let msg = $err
        abi.sqlite3_free err
        raise newSqliteError(msg)

#
# ResultRow
#

proc `[]`*(row: ResultRow, idx: Natural): DbValue =
    ## Access a column in the result row based on index.
    row.values[idx]

proc `[]`*(row: ResultRow, column: string): DbValue =
    ## Access a column in the result row based on column name.
    ## The column name must be unambiguous.
    let idx = row.columns.find(column)
    assert idx != -1, "Column does not exist in row: '" & column & "'"
    doAssert count(row.columns, column) == 1, "Column exists multiple times in row: '" & column & "'"
    row.values[idx]

proc len*(row: ResultRow): int =
    ## Returns the number of columns in the result row.
    row.values.len

proc values*(row: ResultRow): seq[DbValue] =
    ## Returns all column values in the result row.
    row.values

proc columns*(row: ResultRow): seq[string] =
    ## Returns all column names in the result row.
    row.columns

proc unpack*[T: tuple](row: ResultRow, _: typedesc[T]): T =
    ## Calls ``fromDb`` on each element of ``row`` and returns it
    ## as a tuple.
    doAssert row.len == result.typeof.tupleLen,
        "Unpack expected a tuple with " & $row.len & " field(s) but found: " & $T
    var idx = 0
    for value in result.fields:
        value = row[idx].fromDb(type(value))
        idx.inc

#
# Deprecations
#

proc rows*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): seq[seq[DbValue]]
        {.deprecated: "use 'all' instead".} =
    db.all(sql, params).mapIt(it.values)
    
iterator rows*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): seq[DbValue]
        {.deprecated: "use 'iterate' instead".} =
    for row in db.all(sql, params):
        yield row.values

proc unpack*[T: tuple](row: seq[DbValue], _: typedesc[T]): T {.deprecated.} =
    ResultRow(values: row).unpack(T)
