import postgres;
import "support";

[Test]
connects_and_selects() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    var rows = db.query("SELECT 1 AS one, 'two'::text AS two, NULL::int AS three, true AS four").value();
    expect_equal(rows.count, 1 as ulong);
    expect_equal(rows[0].get(0).to_string(), "1");
    expect_equal(rows[0].get("two").value().to_string(), "two");
    expect_equal(rows[0].get("three").value().to_string(), "NULL");
    expect_equal(rows[0].get(3).to_string(), "true");
    expect_true(db.server_parameter("server_version").is_value());
    db.close();
    expect_false(db.is_open());
}

struct Person {
    var id: long;
    var name: String;
    var nickname: String?;
    var active: bool;
}

[Test]
parameters_never_become_sql() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    var tricky = "O'Brien'); DROP TABLE x; --";
    var rows = db.query(
        "SELECT $1::text AS t, $2::bigint AS n, $3::int AS missing, $4::bytea AS b, $5::float8 AS r, $6::bool AS f",
        [
            postgres.Value.Text(tricky),
            postgres.Value.Integer(-9007199254740993),
            postgres.Value.Null,
            postgres.Value.Bytes([0 as u8, 1 as u8, 255 as u8]),
            postgres.Value.Real(0.1),
            postgres.Value.Bool(false),
        ]
    ).value();
    var row = rows[0];
    expect_equal(row.get("t").value().to_string(), tricky);
    expect_equal(row.get("n").value().to_string(), "-9007199254740993");
    expect_equal(row.get("missing").value().to_string(), "NULL");
    expect_equal(row.get("b").value().to_string(), "\\x0001ff");
    expect_equal(row.get("r").value().to_string(), "0.1");
    expect_equal(row.get("f").value().to_string(), "false");
    expect_equal(row.name(0), "t");
    expect_equal(row.count(), 6 as ulong);
    expect_true(row.get("nope").is_empty());
}

[Test]
execute_counts_rows_and_query_as_decodes() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    db.execute_script(
        "CREATE TEMP TABLE people (id bigserial PRIMARY KEY, name text NOT NULL, nickname text, active bool NOT NULL);"
            + "CREATE TEMP TABLE empty (x int)"
    ).value();
    var insert = "INSERT INTO people (name, nickname, active) VALUES ($1, $2, $3)";
    expect_equal(
        db.execute(insert, [postgres.Value.Text("Ada"), postgres.Value.Null, postgres.Value.Bool(true)]).value(),
        1 as ulong
    );
    expect_equal(
        db.execute(
            insert, [postgres.Value.Text("Grace"), postgres.Value.Text("Amazing"), postgres.Value.Bool(true)]
        ).value(),
        1 as ulong
    );
    expect_equal(db.execute("UPDATE people SET active = false").value(), 2 as ulong);
    var people = db.query_as<Person>("SELECT * FROM people ORDER BY id").value();
    expect_equal(people.count, 2 as ulong);
    expect_equal(people[0].name, "Ada");
    expect_true(people[0].nickname.is_empty());
    expect_equal(people[1].nickname.value(), "Amazing");
    expect_false(people[1].active);
    expect_equal(db.query("SELECT * FROM empty").value().count, 0 as ulong);
    var wrong = db.query_as<Person>("SELECT 'x' AS id");
    expect_equal(wrong.error().code, "22000");
}

[Test]
prepared_statements_run_again() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    var square = db.prepare("SELECT $1::int * $1::int AS square").value();
    for (var n in 1..4) {
        var rows = square.query([postgres.Value.Integer(n as long)]).value();
        expect_equal(rows[0].get("square").value().to_string(), to_string(n * n));
    }
    square.close().value();
    expect_equal(square.query([postgres.Value.Integer(2)]).error().code, "26000");
    expect_equal(db.prepare("SELEC 1").error().code, "42601");
}

[Test]
errors_carry_sqlstate_and_leave_the_connection_usable() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    var missing = db.query("SELECT * FROM no_such_table");
    expect_equal(missing.error().code, "42P01");
    expect_equal(missing.error().severity, "ERROR");
    expect_true(missing.error().message.contains("no_such_table"));
    db.execute_script("CREATE TEMP TABLE unique_names (name text PRIMARY KEY)").value();
    db.execute("INSERT INTO unique_names VALUES ($1)", [postgres.Value.Text("a")]).value();
    var duplicate = db.execute("INSERT INTO unique_names VALUES ($1)", [postgres.Value.Text("a")]);
    expect_equal(duplicate.error().code, "23505");
    expect_true(duplicate.error().detail.is_value());
    expect_equal(db.execute_script("SELECT 1; SELECT nope").error().code, "42703");
    expect_equal(db.query("SELECT 2").value()[0].get(0).to_string(), "2");
}

[Test]
login_errors_are_reported() {
    var server = _server();
    if (server.is_empty()) {
        return;
    }
    var config = server.value();
    config.password = "wrong";
    expect_equal(postgres.Connection.connect(config).error().code, "28P01");
    config = _server().value();
    config.database = "no_such_database";
    expect_equal(postgres.Connection.connect(config).error().code, "3D000");
    config = _server().value();
    config.port = 1;
    expect_equal(postgres.Connection.connect(config).error().code, "08006");
}

[Test]
listen_and_notify() {
    var first = _connect();
    if (first.is_empty()) {
        return;
    }
    var listener = first.value();
    var sender = _connect().value();
    listener.execute_script("LISTEN pepper_events").value();
    sender.execute("SELECT pg_notify('pepper_events', $1)", [postgres.Value.Text("hello")]).value();
    var notification = listener.wait_for_notification().value();
    expect_equal(notification.channel, "pepper_events");
    expect_equal(notification.payload, "hello");
    expect_equal(listener.notifications().count, 0 as ulong);
}

[Test]
copy_from_stdin_fails_instead_of_hanging() {
    var connection = _connect();
    if (connection.is_empty()) {
        return;
    }
    var db = connection.value();
    db.execute_script("CREATE TEMP TABLE copied (x int)").value();
    expect_equal(db.execute_script("COPY copied FROM STDIN").error().code, "57014");
    expect_equal(db.execute("COPY copied FROM STDIN").error().code, "57014");
    expect_equal(db.query("SELECT 3").value()[0].get(0).to_string(), "3");
}
