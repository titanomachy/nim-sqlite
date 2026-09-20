import nim_sqlite

withDatabase(":memory:"):
  db.exec("CREATE TABLE notes(message TEXT)")
  withDeadline(db, 1_000):
    db.exec("INSERT INTO notes VALUES(?)", "saved")

  let copy = openDatabase(":memory:")
  try:
    copy.backupDatabase(db)
    echo copy.value("SELECT message FROM notes").get().fromDb(string)
  finally:
    copy.close()
