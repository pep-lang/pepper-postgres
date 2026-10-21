## `Pool`: connections to one server that threads and tasks share.

import async;
import "config";
import "connection";
import "error";

## A fixed set of connections to one server, shared between threads and
## tasks.
##
## A `Connection` belongs to one thread or task at a time, so code that
## runs many at once shares a `Pool`. The pool is `[Shared]`: a closure
## passed to `async.spawn` or `async.Thread.spawn` may capture it.
## `connection()` lends one connection at a time and waits while all are in
## use; inside `async.run` the wait parks only the task. Each connection
## sits in an `async.Mutex`, so the compiler checks the block that locks it
## as it checks any `with` over a lock: nothing made from the `Connection`,
## such as a `Statement`, can outlive the block.
##
## A connection goes back to the pool with any open transaction rolled
## back. One whose socket failed stays closed; its next query returns an
## error with code `08003`.
##
## @example
##     import async;
##     import postgres;
##
##     main(): int {
##         var config = postgres.Config.parse("postgres://app:secret@localhost/app").value();
##         var pool = postgres.Pool.open(config, 4).value();
##         async.run(() => {
##             var tasks = Array<async.Task<void>>();
##             for (var i in 0..8) {
##                 tasks.append(async.spawn<void>(() => {
##                     with (var lease = pool.connection()) {
##                         with (var db = lease.lock()) {
##                             db.execute("INSERT INTO hits DEFAULT VALUES").value();
##                         }
##                     }
##                 }));
##             }
##             for (var task in tasks) {
##                 task.join();
##             }
##         });
##         return 0;
##     }
[Shared]
export struct Pool {
    const _idle: async.Channel<async.Mutex<Connection>>;
    ## The number of connections.
    const size: ulong;

    ## Wraps connections `open` made; use `open` instead.
    ##
    ## @param idle a channel holding every connection, each in its own lock
    ## @param size the number of connections in `idle`
    construct(idle: async.Channel<async.Mutex<Connection>>, size: ulong) {
        _idle = idle;
        this.size = size;
    }

    ## Opens `size` connections to the server `config` names.
    ##
    ## @param config the server, login, database and TLS settings
    ## @param size the number of connections, at least 1
    ## @returns the pool, or the first connection's error
    ## @panics if `size` is 0
    static open(config: Config, size: ulong): PgResult<Pool> {
        assert(size > 0, "postgres: a pool needs at least one connection");
        var idle = async.Channel<async.Mutex<Connection>>();
        for (var i in 0..size) {
            # A copy per connection: a connection may keep references to its
            # config's strings, and nothing else may share a value moved
            # into a lock.
            var connection = Connection.connect(copy(config))?;
            idle.send(async.Mutex<Connection>(move(connection)));
        }
        return PgResult<Pool>.ok(Pool(idle, size));
    }

    ## Takes a connection nothing else is using, waiting while all are in
    ## use, for a `with` header. The block's binding is the connection's
    ## lock; lock it with an inner `with` to reach the `Connection`. The
    ## connection goes back to the pool when the outer block ends, by any
    ## path.
    ##
    ## @returns the lease on one connection
    ## @panics if the pool's connections are gone, which cannot happen while
    ##   the pool is alive
    ## @example
    ##     with (var lease = pool.connection()) {
    ##         with (var db = lease.lock()) {
    ##             db.execute("DELETE FROM sessions WHERE expires < now()").value();
    ##         }
    ##     }   # the connection is back in the pool
    connection(): PooledConnection {
        return PooledConnection(_idle, _idle.receive().value());
    }
}

## One connection of a `Pool`, lent to the code that took it with
## `Pool.connection()`, which a `with` block holds.
##
## `enter()` hands the block the connection's `async.Mutex<Connection>`;
## destroying the lease rolls back any transaction left open and gives the
## connection back to the pool. It is `[Isolated]`: it can only be the
## scope of a `with` header, so it cannot be kept past the block.
[Isolated]
export struct PooledConnection {
    const _idle: async.Channel<async.Mutex<Connection>>;
    const _connection: async.Mutex<Connection>;
    # True until the connection goes back to the pool.
    var _held: bool;

    ## Takes over a connection `Pool.connection()` received; use that
    ## instead.
    ##
    ## @param idle the pool's channel, which gets the connection back
    ## @param connection the connection lent
    construct(idle: async.Channel<async.Mutex<Connection>>, connection: async.Mutex<Connection>) {
        _idle = idle;
        _connection = connection;
        _held = true;
    }

    destruct {
        this.exit();
    }

    ## Returns the connection, for the `with` header to bind; lock it to
    ## reach the `Connection`.
    ##
    ## @returns the connection's lock
    enter(): async.Mutex<Connection> {
        return _connection;
    }

    ## Rolls back a transaction the borrower left open and gives the
    ## connection back to the pool. The destructor calls it; calling it
    ## again does nothing.
    exit() {
        if (_held) {
            _held = false;
            with (var db = _connection.lock()) {
                if (db.is_open() && db.in_transaction()) {
                    db.rollback();
                }
            }
            _idle.send(_connection);
        }
    }
}
