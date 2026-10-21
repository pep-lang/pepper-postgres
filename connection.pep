## `Connection`: a session with a PostgreSQL server, its queries and
## transactions, `Statement`, a prepared statement, and `Notification`.

import io;
import math;
import text;
import tls;
import "config";
import "error";
import "message";
import "row";
import "scram";
import "value";

# How much one read asks the socket for.
const _READ_SIZE: ulong = 65536;

## A message `NOTIFY` sent to a channel this connection is listening on
## (`LISTEN channel`).
export struct Notification {
    ## The process ID of the server session that sent it.
    var process_id: int;
    ## The channel it was sent to.
    var channel: String;
    ## The payload; empty when `NOTIFY` gave none.
    var payload: String;

    ## Creates a notification; the connection makes them.
    ##
    ## @param process_id the sending session's process ID
    ## @param channel the channel
    ## @param payload the payload
    construct(process_id: int, channel: String, payload: String) {
        this.process_id = process_id;
        this.channel = channel;
        this.payload = payload;
    }
}

# What one round of the extended protocol produced.
struct _Outcome {
    var columns: _Column[];
    var rows: Row[];
    var affected: ulong;
    # Whether the extended protocol ran it, so an error waits for a Sync.
    var extended: bool;

    construct(extended: bool = false) {
        columns = Array<_Column>();
        rows = Array<Row>();
        affected = 0;
        this.extended = extended;
    }
}

## A session with a PostgreSQL server.
##
## Open one with `connect`. `query` and `execute` run one SQL statement
## with `$1`, `$2`, ... parameters through the extended protocol, so a
## parameter's value never becomes SQL; `prepare` keeps a statement on the
## server to run again; `query_as<T>` decodes each row into a struct.
## `execute_script` runs several statements through the simple protocol,
## with no parameters: never build its text from untrusted input.
##
## A connection runs one query at a time and belongs to one thread or task
## at a time; share connections through a `Pool`. Inside `async.run`, a
## call that waits for the server parks only its task. The session ends
## with `close()`, or when the last reference to the connection goes away.
##
## @example
##     import postgres;
##
##     struct User {
##         var id: long;
##         var name: String;
##     }
##
##     main(): int {
##         var db = postgres.Connection.connect("postgres://app:secret@localhost/app").value();
##         db.execute("INSERT INTO users (name) VALUES ($1)", [postgres.Value.Text("Ada")]).value();
##         for (var user in db.query_as<User>("SELECT id, name FROM users").value()) {
##             print($"{user.id}: {user.name}");
##         }
##         db.close();
##         return 0;
##     }
export struct Connection {
    var _tcp: io.TcpStream;
    var _tls: tls.TlsStream?;
    # Bytes read from the server; `_at` is where the next message starts.
    var _in: u8[];
    var _at: ulong;
    # The transaction status of the last ReadyForQuery: 'I' idle, 'T' in a
    # transaction, 'E' in a failed transaction.
    var _status: char;
    var _open: bool;
    var _parameters: Map<String, String>;
    var _notifications: Deque<Notification>;
    var _max_notifications: ulong;
    var _dropped_notifications: ulong;
    var _statement_count: ulong;

    ## Wraps a connected socket; use `connect` instead.
    ##
    ## @param tcp the socket, connected to the server
    construct(tcp: io.TcpStream) {
        _tcp = tcp;
        _tls = Optional<tls.TlsStream>.Empty;
        _in = Array<u8>();
        _at = 0;
        _status = 'I';
        _open = true;
        _parameters = Map<String, String>();
        _notifications = Deque<Notification>();
        _max_notifications = _DEFAULT_MAX_NOTIFICATIONS;
        _dropped_notifications = 0;
        _statement_count = 0;
    }

    destruct {
        close();
    }

    ## Connects and logs in to the server `config` names.
    ##
    ## The login answers what the server asks for: SCRAM-SHA-256 (the
    ## default since PostgreSQL 14) or a cleartext password. MD5 is not
    ## supported. The session's `client_encoding` is UTF-8.
    ##
    ## @param config the server, login, database and TLS settings
    ## @returns the connection, or the error: `08006` when the server
    ##   cannot be reached or TLS fails, `28000` or `28P01` when the login
    ##   fails, `3D000` when the database does not exist
    static connect(config: Config): PgResult<Connection> {
        var tcp = io.TcpStream.connect_host(config.host, config.port);
        if (tcp.is_err()) {
            return PgResult<Connection>.err(_io_error(tcp.error()));
        }
        var connection = Connection(tcp.value());
        connection._max_notifications = config.max_notifications > 0 ? config.max_notifications : 1;
        if (config.tls) {
            connection._start_tls(config)?;
        }
        connection._log_in(config)?;
        return PgResult<Connection>.ok(connection);
    }

    ## Connects to the server a connection URL names, as
    ## `Config.parse(url)` reads it.
    ##
    ## @param url the connection URL, `postgres://user:password@host/database`
    ## @returns the connection, or the error, as for `connect(Config)`
    static connect(url: String): PgResult<Connection> {
        return connect(Config.parse(url)?);
    }

    _start_tls(config: Config): PgResult<void> {
        _write(_ssl_request())?;
        var answer = Array<u8>();
        var read = _tcp.read_exact(answer, 1);
        if (read.is_err()) {
            return PgResult<void>.err(_io_error(read.error()));
        }
        if (answer[0] != 'S' as u8) {
            return PgResult<void>.err(PgError("08006", "the server does not accept TLS connections"));
        }
        var connector = tls.TlsConnector.create();
        if (connector.is_err()) {
            return PgResult<void>.err(_io_error(connector.error()));
        }
        if (config.root_certificate.is_value()) {
            var added = connector.value().add_root_certificate(io.Path(config.root_certificate.value()));
            if (added.is_err()) {
                return PgResult<void>.err(_io_error(added.error()));
            }
        }
        var stream = connector.value().connect(_tcp, config.host);
        if (stream.is_err()) {
            return PgResult<void>.err(_io_error(stream.error()));
        }
        _tls = Optional<tls.TlsStream>.Value(stream.value());
        return PgResult<void>.ok();
    }

    _log_in(config: Config): PgResult<void> {
        var parameters = Array<(String, String)>();
        parameters.append(("user", config.user));
        if (config.database.size > 0) {
            parameters.append(("database", config.database));
        }
        parameters.append(("client_encoding", "UTF8"));
        _write(_startup_message(parameters))?;
        var scram = _Scram(config.user, config.password, _scram_nonce());
        # Once SCRAM starts, the server must prove it knows the password
        # (SASLFinal) before AuthenticationOk counts.
        var scram_started = false;
        var scram_verified = false;
        while (true) {
            var message = _receive()?;
            if (message.type_byte == 'E') {
                return PgResult<void>.err(_error_of(message.body));
            }
            if (message.type_byte == 'Z') {
                _status = message.body.count > 0 ? message.body[0] as char : 'I';
                return PgResult<void>.ok();
            }
            if (message.type_byte != 'R') {
                continue;  # BackendKeyData, NoticeResponse
            }
            var fields = _Fields(message.body);
            var kind = fields.int32();
            if (kind == 0) {
                if (scram_started && !scram_verified) {
                    return PgResult<void>.err(_auth_error("the server did not complete SCRAM authentication"));
                }
            } else if (kind == 3) {
                _write(_password_message(config.password))?;
            } else if (kind == 10) {
                var offered = false;
                while (!fields.failed) {
                    var mechanism = fields.cstring();
                    if (mechanism.size == 0) {
                        break;
                    }
                    offered = offered || mechanism == "SCRAM-SHA-256";
                }
                if (!offered) {
                    return PgResult<void>.err(_auth_error("the server offers no SASL mechanism this client supports"));
                }
                scram_started = true;
                _write(_sasl_initial_response("SCRAM-SHA-256", scram.first()))?;
            } else if (kind == 11) {
                var answer = scram.final(text.Utf8.decode_lossy(fields.rest()))?;
                _write(_sasl_response(answer))?;
            } else if (kind == 12) {
                scram.verify(text.Utf8.decode_lossy(fields.rest()))?;
                scram_verified = true;
            } else if (kind == 5) {
                return PgResult<void>.err(
                    _auth_error("the server asks for MD5 authentication, which is not supported; use scram-sha-256")
                );
            } else {
                return PgResult<void>.err(_auth_error($"unsupported authentication request {kind}"));
            }
        }
        return PgResult<void>.ok();
    }

    ## Reports whether the connection is open: false after `close()`, or
    ## once a read or write to the server has failed.
    ##
    ## @returns true while the connection can run queries
    is_open(): bool {
        return _open;
    }

    ## Reports whether a transaction is open, as of the last query: true
    ## after `begin()` until `commit()` or `rollback()`, also when a
    ## statement in it failed.
    ##
    ## @returns true inside a transaction
    in_transaction(): bool {
        return _status != 'I';
    }

    ## Returns a setting the server reported, such as `server_version`,
    ## `TimeZone` or `server_encoding`.
    ##
    ## @param name the setting's name
    ## @returns its value, or none when the server has not reported it
    server_parameter(name: String): String? {
        return _parameters.try_get(name);
    }

    ## Ends the session: tells the server and closes the socket. Calling it
    ## again does nothing.
    close() {
        if (!_open) {
            return;
        }
        _write(_terminate_message());
        _open = false;
        if (_tls.is_value()) {
            _tls.value().close();
        }
        _tcp.close();
    }

    ## Runs one statement with parameters and returns its rows.
    ##
    ## `$1` in `sql` is the first parameter, `$2` the second, and so on;
    ## each one's type is the one the server infers from its use. The
    ## parameters travel apart from the SQL, so they cannot change what it
    ## does.
    ##
    ## @param sql one SQL statement
    ## @param parameters its parameters, in order
    ## @returns the rows (none for a statement that returns none), or the
    ##   server's error
    ## @example
    ##     var rows = db.query("SELECT name FROM users WHERE id = $1", [postgres.Value.Integer(7)]).value();
    query(sql: String, parameters: Value[] = []): PgResult<Row[]> {
        var outcome = _run_unnamed(sql, parameters)?;
        return PgResult<Row[]>.ok(outcome.rows);
    }

    ## Runs one statement with parameters and decodes each row into a `T`,
    ## as `Row.read<T>` does.
    ##
    ## @typeParam T the struct each row decodes into
    ## @param sql one SQL statement
    ## @param parameters its parameters, in order
    ## @returns the decoded rows, or the first error
    query_as<T>(sql: String, parameters: Value[] = []): PgResult<T[]> {
        var outcome = _run_unnamed(sql, parameters)?;
        return _read_all<T>(outcome.rows);
    }

    ## Runs one statement with parameters and returns how many rows it
    ## changed or returned.
    ##
    ## @param sql one SQL statement, such as an `INSERT`, `UPDATE` or
    ##   `DELETE`
    ## @param parameters its parameters, in order
    ## @returns the row count the server reports (0 for a statement such as
    ##   `CREATE TABLE`), or the server's error
    execute(sql: String, parameters: Value[] = []): PgResult<ulong> {
        var outcome = _run_unnamed(sql, parameters)?;
        return PgResult<ulong>.ok(outcome.affected);
    }

    ## Runs `sql`, which may hold several statements separated by `;`,
    ## through the simple query protocol, and discards any rows.
    ##
    ## It takes no parameters: the text goes to the server as it is, so
    ## never build it from input you do not control. Use `execute` with
    ## parameters for that. Unless `sql` starts a transaction itself, its
    ## statements run in one implicit transaction, which a failure rolls
    ## back.
    ##
    ## @param sql the statements, such as a schema
    ## @returns nothing, or the first statement's error
    execute_script(sql: String): PgResult<void> {
        _write(_query_message(sql))?;
        _finish(_Outcome())?;
        return PgResult<void>.ok();
    }

    ## Prepares `sql` on the server as a named statement to run many times.
    ##
    ## @param sql one SQL statement with `$1`, `$2`, ... parameters
    ## @returns the statement, or the server's error (a syntax error shows
    ##   here)
    prepare(sql: String): PgResult<Statement> {
        _statement_count += 1;
        var name = $"pepper_{_statement_count}";
        var out = _parse_message(name, sql);
        out.append_all(_describe_message('S', name));
        out.append_all(_sync_message());
        _write(out)?;
        var outcome = _Outcome();
        _finish(outcome)?;
        return PgResult<Statement>.ok(Statement(this, name, outcome.columns));
    }

    ## Starts a transaction (`BEGIN`).
    ##
    ## @returns nothing, or the server's error
    begin(): PgResult<void> {
        return execute_script("BEGIN");
    }

    ## Commits the open transaction (`COMMIT`). A transaction in which a
    ## statement failed rolls back instead, and `commit` returns an error
    ## with code `25P02`.
    ##
    ## @returns nothing, or the error
    commit(): PgResult<void> {
        var failed = _status == 'E';
        execute_script("COMMIT")?;
        if (failed) {
            return PgResult<void>.err(PgError("25P02", "the transaction failed, so COMMIT rolled it back"));
        }
        return PgResult<void>.ok();
    }

    ## Rolls back the open transaction (`ROLLBACK`).
    ##
    ## @returns nothing, or the server's error
    rollback(): PgResult<void> {
        return execute_script("ROLLBACK");
    }

    ## Runs `body` in a transaction: commits it when `body` returns a
    ## value, and rolls it back when `body` returns an error, which it then
    ## returns.
    ##
    ## @typeParam T what `body` returns
    ## @param body the work to do; it gets this connection
    ## @returns what `body` returned, or the error of `body` or the commit
    ## @example
    ##     db.transaction<void>((db): postgres.PgResult<void> => {
    ##         db.execute("UPDATE accounts SET balance = balance - 10 WHERE id = 1")?;
    ##         db.execute("UPDATE accounts SET balance = balance + 10 WHERE id = 2")?;
    ##         return postgres.PgResult<void>.ok();
    ##     }).value();
    transaction<T>(body: (Connection) => PgResult<T>): PgResult<T> {
        begin()?;
        var result = body(this);
        if (result.is_err()) {
            if (_open) {
                rollback();
            }
            return result;
        }
        commit()?;
        return result;
    }

    ## Returns the notifications that have arrived, oldest first, and
    ## forgets them. They arrive while the connection reads from the
    ## server, so this returns those that came with earlier queries;
    ## `wait_for_notification` waits for one. A connection keeps at most
    ## `Config.max_notifications` of them (10,000 by default): past that,
    ## each new one drops the oldest, which `dropped_notifications()`
    ## counts.
    ##
    ## @returns the notifications, possibly none
    notifications(): Notification[] {
        var arrived = Array<Notification>();
        for (var notification in _notifications) {
            arrived.append(notification);
        }
        _notifications.clear();
        return arrived;
    }

    ## Returns how many notifications this connection has dropped, since it
    ## connected, because `Config.max_notifications` were already waiting.
    ## A count that grows means `notifications()` is not called often
    ## enough.
    ##
    ## @returns the number dropped
    dropped_notifications(): ulong {
        return _dropped_notifications;
    }

    ## Waits until a notification arrives on a channel this connection
    ## listens on, and returns it; returns at once when one is queued.
    ## Inside `async.run` the wait parks only this task.
    ##
    ## @returns the oldest notification, or the error that ended the wait
    wait_for_notification(): PgResult<Notification> {
        while (_notifications.count == 0) {
            var message = _receive()?;
            if (message.type_byte == 'E') {
                return PgResult<Notification>.err(_error_of(message.body));
            }
        }
        return PgResult<Notification>.ok(_notifications.pop_front());
    }

    _run_unnamed(sql: String, parameters: Value[]): PgResult<_Outcome> {
        var out = _parse_message("", sql);
        out.append_all(_bind_message("", parameters));
        out.append_all(_describe_message('P', ""));
        out.append_all(_execute_message());
        out.append_all(_sync_message());
        _write(out)?;
        var outcome = _Outcome(true);
        _finish(outcome)?;
        return PgResult<_Outcome>.ok(outcome);
    }

    _run_prepared(name: String, columns: _Column[], parameters: Value[]): PgResult<_Outcome> {
        var out = _bind_message(name, parameters);
        out.append_all(_execute_message());
        out.append_all(_sync_message());
        _write(out)?;
        var outcome = _Outcome(true);
        outcome.columns = columns;
        _finish(outcome)?;
        return PgResult<_Outcome>.ok(outcome);
    }

    _close_statement(name: String): PgResult<void> {
        var out = _close_message('S', name);
        out.append_all(_sync_message());
        _write(out)?;
        _finish(_Outcome())?;
        return PgResult<void>.ok();
    }

    # Reads the server's answer up to ReadyForQuery, gathering rows into
    # `outcome`; returns the first error the server sent.
    _finish(outcome: _Outcome): PgResult<void> {
        var error = Optional<PgError>.Empty;
        var names = _names_of(outcome.columns);
        while (true) {
            var message = _receive()?;
            var type_byte = message.type_byte;
            if (type_byte == 'Z') {
                _status = message.body.count > 0 ? message.body[0] as char : 'I';
                break;
            }
            if (type_byte == 'E') {
                if (error.is_empty()) {
                    error = Optional<PgError>.Value(_error_of(message.body));
                }
            } else if (type_byte == 'T') {
                var columns = _columns_of(message.body);
                if (columns.is_err()) {
                    # The rest of the reply is unread, so the session is lost.
                    _open = false;
                    return PgResult<void>.err(columns.error());
                }
                outcome.columns = columns.value();
                names = _names_of(outcome.columns);
            } else if (type_byte == 'D') {
                var values = _values_of(message.body, outcome.columns);
                if (values.is_err()) {
                    _open = false;
                    return PgResult<void>.err(values.error());
                }
                outcome.rows.append(Row(names, values.value()));
            } else if (type_byte == 'G') {
                # COPY FROM STDIN waits for data this client cannot send.
                var body = Array<u8>();
                _put_cstring(body, "COPY FROM STDIN is not supported by this client");
                var out = _frame('f', body);
                # A Sync sent before the copy began was ignored, so the
                # extended protocol needs another; a simple query does not.
                if (outcome.extended) {
                    out.append_all(_sync_message());
                }
                _write(out)?;
            } else if (type_byte == 'C') {
                outcome.affected = _affected_of(_Fields(message.body).cstring());
            }
        }
        if (error.is_value()) {
            return PgResult<void>.err(error.value());
        }
        return PgResult<void>.ok();
    }

    # The next message from the server. ParameterStatus is stored and
    # NoticeResponse dropped here, and NotificationResponse queued, since
    # any of them may come at any time.
    _receive(): PgResult<_Backend> {
        while (true) {
            _fill(5)?;
            var type_byte = _in[_at] as char;
            var length = _Fields(_in.slice(_at + 1, _at + 5).to_array()).int32();
            if (length < 4) {
                _open = false;
                return PgResult<_Backend>.err(_protocol_error($"invalid message length {length}"));
            }
            _fill(1 + length as ulong)?;
            var body = _in.slice(_at + 5, _at + 1 + length as ulong).to_array();
            _at += 1 + length as ulong;
            if (type_byte == 'S') {
                var fields = _Fields(body);
                var name = fields.cstring();
                _parameters[name] = fields.cstring();
            } else if (type_byte == 'A') {
                var fields = _Fields(body);
                var process_id = fields.int32();
                var channel = fields.cstring();
                if (_notifications.count == _max_notifications) {
                    _notifications.pop_front();
                    _dropped_notifications += 1;
                }
                _notifications.push_back(Notification(process_id, channel, fields.cstring()));
                # Returned too, so `wait_for_notification` sees it arrive.
                return PgResult<_Backend>.ok(_Backend(type_byte, body));
            } else if (type_byte != 'N') {
                return PgResult<_Backend>.ok(_Backend(type_byte, body));
            }
        }
        return PgResult<_Backend>.err(_protocol_error("unreachable"));
    }

    # Reads until at least `count` unread bytes are buffered.
    _fill(count: ulong): PgResult<void> {
        if (!_open) {
            return PgResult<void>.err(PgError("08003", "the connection is closed"));
        }
        while (_in.count - _at < count) {
            if (_at > 0) {
                _in = _in.slice(_at, _in.count).to_array();
                _at = 0;
            }
            var read = _tls.is_value() ? _tls.value().read(_in, _READ_SIZE) : _tcp.read(_in, _READ_SIZE);
            if (read.is_err()) {
                _open = false;
                return PgResult<void>.err(_io_error(read.error()));
            }
            if (read.value() == 0) {
                _open = false;
                return PgResult<void>.err(PgError("08006", "the server closed the connection"));
            }
        }
        return PgResult<void>.ok();
    }

    _write(bytes: u8[]): PgResult<void> {
        if (!_open) {
            return PgResult<void>.err(PgError("08003", "the connection is closed"));
        }
        var written = _tls.is_value() ? _tls.value().write_all(bytes) : _tcp.write_all(bytes);
        if (written.is_err()) {
            _open = false;
            return PgResult<void>.err(_io_error(written.error()));
        }
        return PgResult<void>.ok();
    }
}

## A statement prepared on the server with `Connection.prepare`, to run
## many times with different parameters.
##
## @example
##     var insert = db.prepare("INSERT INTO hits (path) VALUES ($1)").value();
##     for (var path in paths) {
##         insert.execute([postgres.Value.Text(path)]).value();
##     }
##     insert.close().value();
export struct Statement {
    var _connection: Connection;
    var _name: String;
    var _columns: _Column[];

    ## Wraps a prepared statement; use `Connection.prepare` instead.
    ##
    ## @param connection the connection it was prepared on
    ## @param name its name on the server
    ## @param columns the columns of its result
    construct(connection: Connection, name: String, columns: _Column[]) {
        _connection = connection;
        _name = name;
        _columns = columns;
    }

    ## Runs the statement with `parameters` and returns its rows.
    ##
    ## @param parameters its parameters, in order
    ## @returns the rows, or the server's error
    query(parameters: Value[] = []): PgResult<Row[]> {
        var outcome = _connection._run_prepared(_name, _columns, parameters)?;
        return PgResult<Row[]>.ok(outcome.rows);
    }

    ## Runs the statement with `parameters` and decodes each row into a
    ## `T`, as `Row.read<T>` does.
    ##
    ## @typeParam T the struct each row decodes into
    ## @param parameters its parameters, in order
    ## @returns the decoded rows, or the first error
    query_as<T>(parameters: Value[] = []): PgResult<T[]> {
        var outcome = _connection._run_prepared(_name, _columns, parameters)?;
        return _read_all<T>(outcome.rows);
    }

    ## Runs the statement with `parameters` and returns how many rows it
    ## changed or returned.
    ##
    ## @param parameters its parameters, in order
    ## @returns the row count the server reports, or the server's error
    execute(parameters: Value[] = []): PgResult<ulong> {
        var outcome = _connection._run_prepared(_name, _columns, parameters)?;
        return PgResult<ulong>.ok(outcome.affected);
    }

    ## Frees the statement on the server. The server frees it anyway when
    ## the session ends.
    ##
    ## @returns nothing, or the server's error
    close(): PgResult<void> {
        return _connection._close_statement(_name);
    }
}

_read_all<T>(rows: Row[]): PgResult<T[]> {
    var decoded = Array<T>();
    for (var row in rows) {
        var item = row.read<T>();
        if (item.is_err()) {
            return PgResult<T[]>.err(item.error());
        }
        decoded.append(item.value());
    }
    return PgResult<T[]>.ok(decoded);
}

_names_of(columns: _Column[]): String[] {
    var names = Array<String>();
    for (var column in columns) {
        names.append(column.name);
    }
    return names;
}

# The row count at the end of a command tag (`INSERT 0 5`, `UPDATE 3`).
_affected_of(tag: String): ulong {
    var at = tag.rfind(" ");
    if (at < 0) {
        return 0;
    }
    var count = math.parse_int(tag.substr_bytes((at + 1) as ulong, tag.size - (at + 1) as ulong));
    return count.is_value() && count.value() >= 0 ? count.value() as ulong : 0;
}
