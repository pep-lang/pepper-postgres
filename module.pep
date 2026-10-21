## A PostgreSQL client in pure Pepper: it speaks the server's wire protocol
## (version 3) over `io` and `tls`, with no libpq.
##
## Bring it in with `import postgres`. Inside `async.run`, every call that
## waits for the server parks only its task, so many tasks can share a
## `Pool`. Every call that can fail returns a `PgResult<T>`, whose error
## holds the SQLSTATE code and the server's message.
##
## - `Connection`: a session: `connect`, `query`, `query_as<T>`, `execute`,
##   `execute_script`, `prepare`, `begin`/`commit`/`rollback`,
##   `transaction`, and LISTEN/NOTIFY through `wait_for_notification`
## - `Config`: the server, login, database and TLS settings, or `parse` a
##   `postgres://` URL
## - `Statement`: a prepared statement
## - `Row`: one result row: `get` by position or name, `read<T>` into a
##   struct
## - `Value`: a parameter or column value
## - `Pool`, `PooledConnection`: connections that threads and tasks share
## - `Notification`: a message from `NOTIFY`
## - `PgError`, `PgResult<T>`: errors
##
## Logins use SCRAM-SHA-256 or a cleartext password, as the server asks;
## MD5 is not supported. Queries with parameters go through the extended
## protocol, so a parameter's value never becomes SQL. `execute_script`
## sends its text as it is: never build it from untrusted input.
##
## @example
##     import postgres;
##
##     struct Book {
##         var title: String;
##         var year: long;
##     }
##
##     main(): int {
##         var db = postgres.Connection.connect("postgres://app:secret@localhost/library").value();
##         db.execute_script("CREATE TABLE IF NOT EXISTS books (title text NOT NULL, year int)").value();
##         db.execute(
##             "INSERT INTO books VALUES ($1, $2)",
##             [postgres.Value.Text("Dune"), postgres.Value.Integer(1965)]
##         ).value();
##         for (var book in db.query_as<Book>("SELECT title, year FROM books").value()) {
##             print($"{book.title} ({book.year})");   # Dune (1965)
##         }
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "config";
import "connection";
import "error";
import "pool";
import "row";
import "value";

export Config;
export Connection;
export Statement;
export Notification;
export Pool;
export PooledConnection;
export Row;
export Value;
export PgError;
export PgResult;
