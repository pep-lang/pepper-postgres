import async;
import postgres;
import "support";

[Test]
tasks_share_a_pool() {
    var server = _server();
    if (server.is_empty()) {
        return;
    }
    var setup = postgres.Connection.connect(server.value()).value();
    setup.execute_script("DROP TABLE IF EXISTS pepper_pool_hits; CREATE TABLE pepper_pool_hits (task int)").value();
    var pool = postgres.Pool.open(server.value(), 2).value();
    expect_equal(pool.size, 2 as ulong);
    async.run(() => {
        var tasks = Array<async.Task<void>>();
        for (var i in 0..8) {
            var task = i as long;
            tasks.append(async.spawn<void>(() => {
                with (var lease = pool.connection()) {
                    with (var db = lease.lock()) {
                        db.execute("INSERT INTO pepper_pool_hits VALUES ($1)", [postgres.Value.Integer(task)]).value();
                    }
                }
            }));
        }
        for (var task in tasks) {
            task.join();
        }
    });
    var count = setup.query("SELECT count(DISTINCT task) FROM pepper_pool_hits").value();
    expect_equal(count[0].get(0).to_string(), "8");
    setup.execute_script("DROP TABLE pepper_pool_hits").value();
}

[Test]
a_lease_rolls_back_what_it_left_open() {
    var server = _server();
    if (server.is_empty()) {
        return;
    }
    var pool = postgres.Pool.open(server.value(), 1).value();
    with (var lease = pool.connection()) {
        with (var db = lease.lock()) {
            db.begin().value();
        }
    }
    with (var lease = pool.connection()) {
        with (var db = lease.lock()) {
            expect_false(db.in_transaction());
        }
    }
}

# Nothing listens on port 1, so the first connection fails.
[Test]
open_returns_the_connect_error() {
    var config = postgres.Config.parse("postgres://u:p@127.0.0.1:1/db").value();
    expect_equal(postgres.Pool.open(config, 2).error().code, "08006");
}
