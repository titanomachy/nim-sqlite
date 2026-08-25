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
        activeOperations: int
        transactionSerial: uint64

    DbConn* = distinct DbConnImpl ## Encapsulates a database connection.

    SqlStatementImpl = ref object
        handle: ptr abi.sqlite3_stmt
        db: DbConn
        inUse: bool

    SqlStatement* = distinct SqlStatementImpl ## A prepared SQL statement.

    DbMode* = enum
        dbRead,
        dbReadWrite

    TransactionMode* {.pure.} = enum
        ## Controls how an outermost ``transaction`` acquires SQLite locks.
        ## Nested transactions use savepoints, so their mode is inherited from
        ## the surrounding transaction.
        deferred,
        immediate,
        exclusive

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

    TransactionScopeKind = enum
        transactionRoot,
        transactionSavepoint

    TransactionScope = object
        kind: TransactionScopeKind
        savepoint: string

    ResultRow* = object
        values: seq[DbValue]
        columns: seq[string]

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
        doAssert not SqlStatementImpl(statement).inUse,
            "Statement cannot be used while another operation is active"

proc beginOperation(db: DbConn) =
    assertCanUseDb db
    DbConnImpl(db).activeOperations.inc

proc endOperation(db: DbConn) =
    doAssert DbConnImpl(db).activeOperations > 0,
        "Database operation guard is unbalanced"
    DbConnImpl(db).activeOperations.dec

proc beginOperation(statement: SqlStatement) =
    assertCanUseStatement statement
    statement.db.beginOperation()
    SqlStatementImpl(statement).inUse = true

proc endOperation(statement: SqlStatement) =
    doAssert SqlStatementImpl(statement).inUse,
        "Statement operation guard is unbalanced"
    SqlStatementImpl(statement).inUse = false
    statement.db.endOperation()

proc newSqliteError(db: DbConn): ref SqliteError =
    ## Raises a SqliteError exception.
    (ref SqliteError)(msg: "sqlite error: " & $abi.sqlite3_errmsg(db.handle))

proc newSqliteError(msg: string): ref SqliteError =
    ## Raises a SqliteError exception.
    (ref SqliteError)(msg: msg)

template checkOk(db: DbConn, rc: Rc) =
    if rc != abi.SQLITE_OK:
        raise newSqliteError(db)

proc resetStmt(stmtHandle: ptr abi.sqlite3_stmt) =
    discard abi.sqlite3_reset(stmtHandle)
    discard abi.sqlite3_clear_bindings(stmtHandle)

#
# DbValue
#

proc toDb*[T: Ordinal](val: T): DbValue =
    ## Convert an ordinal value to a DbValue.
    ## Raises ``SqliteError`` if ``val`` cannot be represented by SQLite's
    ## signed 64-bit ``INTEGER`` storage class.
    when T is SomeUnsignedInt:
        if uint64(val) > uint64(high(int64)):
            raise newSqliteError("Integer value " & $val &
                " is out of range for SQLite INTEGER.")
    DbValue(kind: sqliteInteger, intVal: int64(val))

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

proc requireKind(value: DbValue, expected: DbValueKind, target: string) =
    if value.kind != expected:
        raise newSqliteError("Cannot convert DbValue of kind " & $value.kind &
            " to " & target & "; expected " & $expected & ".")

proc fromDb*(value: DbValue, T: typedesc[Ordinal]): T =
    ## Convert a DbValue to an ordinal.
    ## Raises ``SqliteError`` unless ``value`` has the ``sqliteInteger`` kind
    ## and its value is representable by ``T``.
    value.requireKind(sqliteInteger, $T)
    when T is SomeUnsignedInt:
        if value.intVal < 0 or uint64(value.intVal) > uint64(high(T)):
            raise newSqliteError("SQLite INTEGER value " & $value.intVal &
                " is out of range for " & $T & ".")
    else:
        if value.intVal < int64(low(T)) or value.intVal > int64(high(T)):
            raise newSqliteError("SQLite INTEGER value " & $value.intVal &
                " is out of range for " & $T & ".")
    T(value.intVal)

proc fromDb*[T: SomeFloat](value: DbValue, _: typedesc[T]): T =
    ## Convert a DbValue to the requested floating-point type.
    ## Raises ``SqliteError`` unless ``value`` has the ``sqliteReal`` kind.
    value.requireKind(sqliteReal, $T)
    T(value.floatVal)

proc fromDb*(value: DbValue, T: typedesc[string]): string =
    ## Convert a DbValue to a string.
    ## Raises ``SqliteError`` unless ``value`` has the ``sqliteText`` kind.
    value.requireKind(sqliteText, $T)
    value.strVal

proc fromDb*(value: DbValue, T: typedesc[seq[byte]]): seq[byte] =
    ## Convert a DbValue to a sequence of bytes.
    ## Raises ``SqliteError`` unless ``value`` has the ``sqliteBlob`` kind.
    value.requireKind(sqliteBlob, $T)
    value.blobVal

proc fromDb*[T](value: DbValue, _: typedesc[Option[T]]): Option[T] =
    ## Convert a DbValue to an optional value.
    ## Non-NULL values retain the storage-class validation for ``T``.
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
        result = abi.sqlite3_bind_null(stmtHandle, idx)
    of sqliteInteger:
        result = abi.sqlite3_bind_int64(stmtHandle, idx, value.intval)
    of sqliteReal:
        result = abi.sqlite3_bind_double(stmtHandle, idx, value.floatVal)
    of sqliteText:
        {.push warning[Deprecated]: off.}
        result = abi.sqlite3_bind_text64(stmtHandle, idx, value.strVal.cstring,
            uint64(value.strVal.len), abi.SQLITE_TRANSIENT, abi.SQLITE_UTF8.cuchar)
        {.pop.}
    of sqliteBlob:
        if value.blobVal.len == 0:
            result = abi.sqlite3_bind_zeroblob64(stmtHandle, idx, 0)
        else:
            result = abi.sqlite3_bind_blob64(stmtHandle, idx,
                unsafeAddr value.blobVal[0], uint64(value.blobVal.len),
                abi.SQLITE_TRANSIENT)

proc bindParams(db: DbConn, stmtHandle: ptr abi.sqlite3_stmt, params: varargs[DbValue]): Rc =
    result = abi.SQLITE_OK
    let expectedParamsLen = abi.sqlite3_bind_parameter_count(stmtHandle)
    if expectedParamsLen != params.len:
        raise newSqliteError("SQL statement contains " & $expectedParamsLen &
            " parameters but only " & $params.len & " was provided.")

    var idx = 1'i32
    for value in params:
        result = bindValue(stmtHandle, idx, value)
        if result != abi.SQLITE_OK:
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
        if result != abi.SQLITE_OK:
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

proc rejectEmbeddedNul(value, subject: string) =
    for character in value:
        if character == '\0':
            raise newSqliteError(subject & " contains an embedded NUL byte.")

proc validateCompleteSql(sql: string) =
    rejectEmbeddedNul(sql, "SQL input")
    # sqlite3_complete expects a terminating semicolon. Add one after a
    # newline so a valid final `--` comment cannot consume it. This catches
    # unterminated block comments and quoted tokens before preparation can
    # absorb them into an otherwise valid first statement.
    let terminatedSql = sql & "\n;"
    if abi.sqlite3_complete(terminatedSql.cstring) == 0:
        raise newSqliteError("sqlite error: incomplete SQL input")

proc containsSqlStatement(db: DbConn, sql: cstring): bool =
    var remaining = sql
    while not remaining.isNil and remaining[0] != '\0':
        var stmtHandle: ptr abi.sqlite3_stmt
        var tail: cstring
        try:
            let rc = abi.sqlite3_prepare_v2(db.handle, remaining, -1,
                addr stmtHandle, addr tail)
            db.checkOk(rc)
            if not stmtHandle.isNil:
                return true
        finally:
            if not stmtHandle.isNil:
                discard abi.sqlite3_finalize(stmtHandle)

        if tail.isNil or tail == remaining:
            raise newSqliteError("SQLite did not advance while parsing SQL input.")
        remaining = tail

proc prepareSql(db: DbConn, sql: string): ptr abi.sqlite3_stmt =
    var stmtHandle: ptr abi.sqlite3_stmt
    var tail: cstring
    try:
        validateCompleteSql(sql)
        let rc = abi.sqlite3_prepare_v2(db.handle, sql.cstring, -1,
            addr stmtHandle, addr tail)
        db.checkOk(rc)
        if stmtHandle.isNil:
            raise newSqliteError("SQL input contains no statement.")
        if db.containsSqlStatement(tail):
            raise newSqliteError(
                "Only a single SQL statement is allowed in this context. " &
                "To execute several SQL statements, use 'execScript'.")
        result = stmtHandle
        stmtHandle = nil
    finally:
        # Keep ownership local until preparation and validation both succeed.
        if not stmtHandle.isNil:
            discard abi.sqlite3_finalize(stmtHandle)

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
        let text = abi.sqlite3_column_text(stmtHandle, col)
        let bytes = abi.sqlite3_column_bytes(stmtHandle, col)
        if bytes < 0:
            raise newSqliteError("SQLite returned an invalid negative TEXT byte count.")
        let length = int(bytes)
        var s = newString(length)
        if bytes != 0:
            copyMem(addr(s[0]), text, length)
        result = toDb(s)
    of abi.SQLITE_BLOB:
        let blob = abi.sqlite3_column_blob(stmtHandle, col)
        let bytes = abi.sqlite3_column_bytes(stmtHandle, col)
        if bytes < 0:
            raise newSqliteError("SQLite returned an invalid negative BLOB byte count.")
        let length = int(bytes)
        var s = newSeq[byte](length)
        if bytes != 0:
            copyMem(addr(s[0]), blob, length)
        result = toDb(s)
    of abi.SQLITE_NULL:
        result = toDb(nil)
    else:
        raiseAssert "Unexpected column type: " & $columnType

proc executeToCompletion(db: DbConn, stmtHandle: ptr abi.sqlite3_stmt) =
    while true:
        let rc = abi.sqlite3_step(stmtHandle)
        case rc
        of abi.SQLITE_ROW:
            discard
        of abi.SQLITE_DONE:
            return
        else:
            raise newSqliteError(db)

iterator iterateRows(db: DbConn, stmtOrHandle: ptr abi.sqlite3_stmt | SqlStatement,
        errorRc: var int32): ResultRow =
    let stmtHandle = when stmtOrHandle is ptr abi.sqlite3_stmt: stmtOrHandle else: stmtOrHandle.handle
    if errorRc == abi.SQLITE_OK:
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
    ## Executes ``sql``, which must be a single SQL statement. Result rows are
    ## discarded, but the statement is stepped until it completes.
    ## Input without a statement or containing an embedded NUL byte raises
    ## ``SqliteError``.
    runnableExamples:
        let db = openDatabase(":memory:")
        db.exec("CREATE TABLE Person(name, age)")
        db.exec("INSERT INTO Person(name, age) VALUES(?, ?)",
            "John Doe", 23)
    db.beginOperation()
    var lease: StmtLease
    try:
        lease = db.acquireStmt(sql)
        let rc = db.bindParams(lease.handle, params)
        db.checkOk(rc)
        db.executeToCompletion(lease.handle)
    finally:
        try:
            db.releaseStmt(lease)
        finally:
            db.endOperation()

proc exec*[T: tuple](db: DbConn, sql: string, params: T) =
    ## Executes ``sql`` using a named tuple whose field names correspond to
    ## ``:name`` parameters. Tuple field order does not affect binding. Result
    ## rows are discarded, but the statement is stepped until it completes.
    ## Input without a statement or containing an embedded NUL byte raises
    ## ``SqliteError``.
    runnableExamples:
        let db = openDatabase(":memory:")
        db.exec("CREATE TABLE Person(name, age)")
        db.exec("INSERT INTO Person(name, age) VALUES(:name, :age)",
            (age: 23, name: "John Doe"))
    db.beginOperation()
    var lease: StmtLease
    try:
        lease = db.acquireStmt(sql)
        let rc = db.bindNamedParams(lease.handle, params)
        db.checkOk(rc)
        db.executeToCompletion(lease.handle)
    finally:
        try:
            db.releaseStmt(lease)
        finally:
            db.endOperation()

proc executeTransactionSql(db: DbConn, sql: string) =
    # Transaction-control statements are short-lived and, for savepoints,
    # uniquely named. Keeping them out of the user statement cache avoids
    # evicting application statements as nested scopes are entered.
    db.beginOperation()
    var stmtHandle: ptr abi.sqlite3_stmt
    try:
        let rc = abi.sqlite3_prepare_v2(db.handle, sql.cstring, -1,
            addr stmtHandle, nil)
        db.checkOk(rc)
        doAssert not stmtHandle.isNil,
            "Internal transaction SQL did not produce a statement"
        db.executeToCompletion(stmtHandle)
    finally:
        try:
            if not stmtHandle.isNil:
                discard abi.sqlite3_finalize(stmtHandle)
        finally:
            db.endOperation()

proc attachSecondaryException(primary, secondary: ref Exception) =
    ## Keep ``primary`` as the exception observed by the caller while exposing
    ## a cleanup failure through Nim's standard exception-parent chain.
    if secondary.isNil or secondary == primary:
        return
    secondary.parent = primary.parent
    primary.parent = secondary

proc nextSavepoint(db: DbConn): string =
    if DbConnImpl(db).transactionSerial == high(uint64):
        raise newSqliteError("Transaction savepoint identifier space is exhausted.")
    DbConnImpl(db).transactionSerial.inc
    "nim_sqlite_transaction_" & $DbConnImpl(db).transactionSerial

proc beginTransaction(db: DbConn, mode: TransactionMode): TransactionScope =
    if db.isInTransaction:
        result.kind = transactionSavepoint
        result.savepoint = db.nextSavepoint()
        db.executeTransactionSql("SAVEPOINT " & result.savepoint)
    else:
        result.kind = transactionRoot
        let beginSql = case mode
            of TransactionMode.deferred: "BEGIN DEFERRED"
            of TransactionMode.immediate: "BEGIN IMMEDIATE"
            of TransactionMode.exclusive: "BEGIN EXCLUSIVE"
        db.executeTransactionSql(beginSql)

proc finishTransaction(db: DbConn, scope: TransactionScope) =
    case scope.kind
    of transactionRoot:
        db.executeTransactionSql("COMMIT")
    of transactionSavepoint:
        db.executeTransactionSql("RELEASE " & scope.savepoint)

proc rollbackTransaction(db: DbConn, scope: TransactionScope) =
    if not db.isOpen or not db.isInTransaction:
        return

    case scope.kind
    of transactionRoot:
        db.executeTransactionSql("ROLLBACK")
    of transactionSavepoint:
        try:
            db.executeTransactionSql("ROLLBACK TO " & scope.savepoint)
        except Exception as rollbackError:
            # A missing or unusable savepoint makes its exact boundary
            # unknowable. Roll back the whole transaction to restore SQLite's
            # autocommit state, then keep the savepoint failure observable.
            try:
                if db.isOpen and db.isInTransaction:
                    db.executeTransactionSql("ROLLBACK")
            except Exception as cleanupError:
                attachSecondaryException(rollbackError, cleanupError)
            raise rollbackError

        try:
            db.executeTransactionSql("RELEASE " & scope.savepoint)
        except Exception as releaseError:
            # ROLLBACK TO keeps the savepoint active. If RELEASE then fails,
            # fall back to a full rollback so the connection has known state.
            try:
                if db.isOpen and db.isInTransaction:
                    db.executeTransactionSql("ROLLBACK")
            except Exception as cleanupError:
                attachSecondaryException(releaseError, cleanupError)
            raise releaseError

template transaction*(db: DbConn, mode: TransactionMode, body: untyped) =
    ## Runs ``body`` in a transaction using ``mode`` for an outermost scope.
    ## Nested scopes use unique SQLite savepoints and inherit the outer mode.
    ## If a transaction was started manually, this template creates a
    ## savepoint and leaves the manual transaction open.
    let transactionScope = db.beginTransaction(mode)
    var transactionFailed = false
    try:
        try:
            body
        except Exception as transactionError:
            transactionFailed = true
            try:
                db.rollbackTransaction(transactionScope)
            except Exception as cleanupError:
                attachSecondaryException(transactionError, cleanupError)
            raise transactionError
    finally:
        if not transactionFailed:
            try:
                db.finishTransaction(transactionScope)
            except Exception as transactionError:
                try:
                    db.rollbackTransaction(transactionScope)
                except Exception as cleanupError:
                    attachSecondaryException(transactionError, cleanupError)
                raise transactionError

template transaction*(db: DbConn, body: untyped) =
    ## Runs ``body`` in a deferred transaction. See the overload accepting
    ## ``TransactionMode`` for immediate and exclusive transactions.
    db.transaction(TransactionMode.deferred):
        body

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
    ## Each statement is stepped until completion, with result rows discarded.
    ## The statements are executed inside a transaction. Empty, semicolon-only,
    ## and comment-only scripts are no-ops; incomplete or invalid input raises
    ## ``SqliteError``. Embedded NUL bytes also raise ``SqliteError``.
    db.beginOperation()
    try:
        validateCompleteSql(sql)
        db.transaction:
            var remaining = sql.cstring
            while remaining[0] != '\0':
                var tail: cstring
                var stmtHandle: ptr abi.sqlite3_stmt
                try:
                    let rc = abi.sqlite3_prepare_v2(db.handle, remaining, -1,
                        addr stmtHandle, addr tail)
                    db.checkOk(rc)
                    if not stmtHandle.isNil:
                        db.executeToCompletion(stmtHandle)
                finally:
                    if not stmtHandle.isNil:
                        discard abi.sqlite3_finalize(stmtHandle)

                if tail.isNil or tail == remaining:
                    raise newSqliteError("SQLite did not advance while parsing SQL input.")
                remaining = tail
    finally:
        db.endOperation()

iterator iterate*(db: DbConn, sql: string, params: varargs[DbValue, toDb]): ResultRow =
    ## Executes ``sql``, which must be a single SQL statement, and yields each result row one by one.
    ## Input without a statement or containing an embedded NUL byte raises
    ## ``SqliteError``.
    db.beginOperation()
    var lease: StmtLease
    var errorRc: int32 = abi.SQLITE_OK
    try:
        lease = db.acquireStmt(sql)
        for row in db.iteratePositional(lease.handle, params, errorRc):
            yield row
    finally:
        try:
            db.releaseStmt(lease)
        finally:
            db.endOperation()
        db.checkOk(errorRc)

iterator iterate*[T: tuple](db: DbConn, sql: string, params: T): ResultRow =
    ## Executes ``sql`` using named ``:name`` parameters and yields each
    ## result row. Tuple field order does not affect binding.
    ## Input without a statement or containing an embedded NUL byte raises
    ## ``SqliteError``.
    db.beginOperation()
    var lease: StmtLease
    var errorRc: int32 = abi.SQLITE_OK
    try:
        lease = db.acquireStmt(sql)
        for row in db.iterateNamed(lease.handle, params, errorRc):
            yield row
    finally:
        try:
            db.releaseStmt(lease)
        finally:
            db.endOperation()
        db.checkOk(errorRc)

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
    ## Closing while a connection or explicit-statement operation is active
    ## raises ``AssertionDefect``.
    if not db.isOpen:
        return
    doAssert DbConnImpl(db).activeOperations == 0,
        "Database cannot be closed while an operation is active"
    db.cache.clear()
    let rc = abi.sqlite3_close_v2(db.handle)
    db.checkOk(rc)
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

proc changes*(db: DbConn): int64 =
    ## Get the number of changes triggered by the most recent INSERT, UPDATE or
    ## DELETE statement as a signed 64-bit value.
    ##
    ## For more information, refer to the SQLite documentation
    ## (https://www.sqlite.org/c3ref/changes.html).
    assertCanUseDb db
    abi.sqlite3_changes64(db.handle)

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
    ## Input without a statement or containing an embedded NUL byte raises
    ## ``SqliteError``.
    db.beginOperation()
    try:
        let handle = prepareSql(db, sql)
        result = SqlStatementImpl(handle: handle, db: db).SqlStatement
    finally:
        db.endOperation()
    
proc exec*(statement: SqlStatement, params: varargs[DbValue, toDb]) =
    ## Executes `statement` with `params` as parameters. Result rows are
    ## discarded, but the statement is stepped until it completes.
    statement.beginOperation()
    try:
        let rc = statement.db.bindParams(statement.handle, params)
        statement.db.checkOk(rc)
        statement.db.executeToCompletion(statement.handle)
    finally:
        try:
            resetStmt(statement.handle)
        finally:
            statement.endOperation()

proc exec*[T: tuple](statement: SqlStatement, params: T) =
    ## Executes `statement` using named ``:name`` parameters. Tuple field
    ## order does not affect binding. Result rows are discarded, but the
    ## statement is stepped until it completes.
    statement.beginOperation()
    try:
        let rc = statement.db.bindNamedParams(statement.handle, params)
        statement.db.checkOk(rc)
        statement.db.executeToCompletion(statement.handle)
    finally:
        try:
            resetStmt(statement.handle)
        finally:
            statement.endOperation()

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
    statement.beginOperation()
    var errorRc: int32
    try:
        for row in statement.db.iteratePositional(statement, params, errorRc):
            yield row
    finally:
        try:
            resetStmt(statement.handle)
        finally:
            statement.endOperation()
        statement.db.checkOk errorRc

iterator iterate*[T: tuple](statement: SqlStatement, params: T): ResultRow =
    ## Executes `statement` using named ``:name`` parameters and yields each row.
    statement.beginOperation()
    var errorRc: int32
    try:
        for row in statement.db.iterateNamed(statement, params, errorRc):
            yield row
    finally:
        try:
            resetStmt(statement.handle)
        finally:
            statement.endOperation()
        statement.db.checkOk errorRc

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
    ## Finalizing while the statement is active raises ``AssertionDefect``.
    if SqlStatementImpl(statement).isNil or statement.handle.isNil:
        return
    doAssert not SqlStatementImpl(statement).inUse,
        "Statement cannot be finalized while an operation is active"
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
    ## Paths containing embedded NUL bytes also raise ``SqliteError``.
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
    rejectEmbeddedNul(path, "Database path")
    var handle: ptr abi.sqlite3
    let db = new DbConnImpl
    db.handle = handle
    if cacheSize > 0:
        db.cache = initStmtCache(cacheSize)
    result = DbConn(db)
    var initialized = false
    try:
        case mode
        of dbReadWrite:
            let rc = abi.sqlite3_open(path, addr db.handle)
            result.checkOk(rc)
        of dbRead:
            let rc = abi.sqlite3_open_v2(path, addr db.handle, abi.SQLITE_OPEN_READONLY, nil)
            result.checkOk(rc)
        result.exec("PRAGMA encoding = 'UTF-8'")
        result.exec("PRAGMA foreign_keys = ON")
        initialized = true
    finally:
        if not initialized:
            # SQLite may allocate a connection handle even when opening fails.
            # Initialization can also fail after cached statements are prepared.
            db.cache.clear()
            if not db.handle.isNil:
                discard abi.sqlite3_close_v2(db.handle)
                db.handle = nil

proc loadExtension*(db: DbConn, path: string) =
    ## Load an SQLite extension. Will raise a ``SqliteError`` exception if loading fails.
    assertCanUseDb db
    rejectEmbeddedNul(path, "Extension path")
    db.checkOk abi.sqlite3_db_config(db.handle, abi.SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1, 0);
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
    doAssert idx != -1, "Column does not exist in row: '" & column & "'"
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
