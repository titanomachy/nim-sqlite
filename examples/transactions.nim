import nim_sqlite

proc balance(db: DbConn, account: string): int =
    db.value("SELECT balance FROM Account WHERE name = ?", account).get.fromDb(int)

proc transfer(db: DbConn, source, destination: string, amount: int) =
    db.transaction:
        if db.balance(source) < amount:
            raise newException(ValueError, "insufficient funds")

        db.exec("UPDATE Account SET balance = balance - ? WHERE name = ?", amount, source)
        db.exec("UPDATE Account SET balance = balance + ? WHERE name = ?", amount, destination)

let db = openDatabase(":memory:")

try:
    db.execScript("""
        CREATE TABLE Account(
            name TEXT PRIMARY KEY,
            balance INTEGER NOT NULL
        );
        INSERT INTO Account(name, balance) VALUES('Checking', 160);
        INSERT INTO Account(name, balance) VALUES('Savings', 40);
    """)

    try:
        db.transfer("Checking", "Savings", 250)
    except ValueError as error:
        echo "Rejected transfer: ", error.msg

    db.transfer("Checking", "Savings", 40)
    echo "Checking: ", db.balance("Checking")
    echo "Savings: ", db.balance("Savings")
finally:
    db.close()
