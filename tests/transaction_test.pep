import postgres;
import "support";

_accounts(db: postgres.Connection) {
    db.execute_script(
        "CREATE TEMP TABLE accounts (id int PRIMARY KEY, balance int CHECK (balance >= 0));"
            + "INSERT INTO accounts VALUES (1, 100), (2, 0)"
    ).value();
}

_balance(db: postgres.Connection, id: int): String {
    return db
        .query("SELECT balance FROM accounts WHERE id = $1", [postgres.Value.Integer(id as long)])
        .value()[0]
        .get(0)
        .to_string();
}

_move(db: postgres.Connection, amount: long): postgres.PgResult<void> {
    db.execute("UPDATE accounts SET balance = balance + $1 WHERE id = 2", [postgres.Value.Integer(amount)])?;
    db.execute("UPDATE accounts SET balance = balance - $1 WHERE id = 1", [postgres.Value.Integer(amount)])?;
    return postgres.PgResult<void>.ok();
}

[Test]
begin_commit_and_rollback() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    _accounts(db);
    expect_false(db.in_transaction());
    db.begin().value();
    expect_true(db.in_transaction());
    _move(db, 30).value();
    db.commit().value();
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 1), "70");
    db.begin().value();
    _move(db, 30).value();
    db.rollback().value();
    expect_equal(_balance(db, 1), "70");
}

[Test]
a_failed_transaction_does_not_commit() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    _accounts(db);
    db.begin().value();
    expect_equal(_move(db, 500).error().code, "23514");
    expect_true(db.in_transaction());
    expect_equal(db.query("SELECT 1").error().code, "25P02");
    expect_equal(db.commit().error().code, "25P02");
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 2), "0");
}

[Test]
transaction_commits_on_ok_and_rolls_back_on_error() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    _accounts(db);
    var moved = db.transaction<long>((db): postgres.PgResult<long> => {
        _move(db, 40)?;
        return postgres.PgResult<long>.ok(40);
    });
    expect_equal(moved.value(), 40 as long);
    expect_equal(_balance(db, 1), "60");
    var failed = db.transaction<long>((db): postgres.PgResult<long> => {
        _move(db, 10)?;
        _move(db, 1000)?;
        return postgres.PgResult<long>.ok(1010);
    });
    expect_equal(failed.error().code, "23514");
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 1), "60");
}
