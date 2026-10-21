# pepper-postgres

An async PostgreSQL client for [Pepper](https://github.com/pep-lang/pepper),
written in pure Pepper: it speaks the server's wire protocol (version 3)
over the runtime's `io` and `tls`, with no libpq to install. Inside
`async.run`, a query parks only its task, so many tasks can share a pool of
connections.

One module, **`postgres`**:

- **`Connection`**: `connect` (a `Config` or a `postgres://` URL), `query`,
  `query_as<T>`, `execute`, `execute_script`, `prepare`, `begin` /
  `commit` / `rollback`, `transaction`, and LISTEN/NOTIFY with
  `wait_for_notification` and `notifications`. A connection keeps at most
  `max_notifications` waiting (10,000 by default); past that it drops the
  oldest and counts them in `dropped_notifications()`.
- **`Config`**: host, port, user, password, database, TLS,
  `max_notifications`; `Config.parse` reads a connection URL.
- **`Row`** and **`Value`**: typed rows (`boolean`, integers, floats,
  `bytea`, `NULL`; other types as text), and `Row.read<T>` to decode a row
  into a struct.
- **`Pool`**: a fixed set of connections that threads and tasks share.
- **`PgError`**: the SQLSTATE code, message, detail and hint.

```pepper
import postgres;

struct Book {
    var title: String;
    var year: long;
}

main(): int {
    var db = postgres.Connection.connect("postgres://app:secret@localhost/library").value();
    db.execute_script("CREATE TABLE IF NOT EXISTS books (title text NOT NULL, year int)").value();
    db.execute(
        "INSERT INTO books VALUES ($1, $2)",
        [postgres.Value.Text("Dune"), postgres.Value.Integer(1965)]
    ).value();
    for (var book in db.query_as<Book>("SELECT title, year FROM books").value()) {
        print($"{book.title} ({book.year})");   # Dune (1965)
    }
    return 0;
}
```

## Security

- **SQL injection.** `query`, `execute` and prepared statements send
  parameters (`$1`, `$2`, ...) apart from the SQL through the extended
  protocol, so a parameter's value is never read as SQL. `execute_script`
  uses the simple protocol and takes no parameters: its text goes to the
  server as it is, so building it from untrusted input is the caller's
  responsibility, and a mistake there is an injection.
- **Logins** use SCRAM-SHA-256 (PostgreSQL's default since 14), which never
  sends the password, or a cleartext password when the server asks for one;
  use TLS for that. MD5 is not supported.
- **TLS** (`config.tls = true`, or `?sslmode=require` in a URL) always
  verifies the server's certificate against the system's roots plus
  `root_certificate`, and that it names the host. There is no mode that
  skips the check.

## Limits

- No `COPY`, no cancel requests, no channel binding (`SCRAM-SHA-256-PLUS`),
  no Unix-socket connections.
- Results are read whole: `query` returns every row at once.
- Columns other than `boolean`, `smallint`, `integer`, `bigint`, `oid`,
  `real`, `double precision` and `bytea` come back as text
  (`numeric`, dates, `uuid`, `json`, arrays, ...).
- A password is not SASLprep-normalized, so a non-ASCII password must
  already be in Unicode NFKC form.
- A pooled connection whose socket failed stays closed; open a new pool to
  replace it.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `postgres` module. Add it to a project under the name
`postgres`:

```sh
pepper package add pep-lang/pepper-postgres --name postgres
```

which writes

```toml
[dependencies]
postgres = { github = "pep-lang/pepper-postgres" }
```

Without a project, put a folder named `postgres` that holds (or links to)
this repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test`. The protocol
and SCRAM tests (including RFC 7677's example) always run. The integration
tests run against the server in `PEPPER_POSTGRES_URL`, and return without
checking anything when it is unset. The TLS tests also need
`PEPPER_POSTGRES_CA`, the CA that signed the server's certificate. With
Docker:

```sh
docker run -d --name pepper-pg -p 5432:5432 -e POSTGRES_USER=pepper -e POSTGRES_PASSWORD=pepper postgres:17
tests/setup-postgres.sh pepper-pg pepper /tmp/pepper-pg     # turns on TLS
PEPPER_POSTGRES_URL=postgres://pepper:pepper@localhost:5432/pepper \
PEPPER_POSTGRES_CA=/tmp/pepper-pg/ca.pem tests/run.sh
```

CI runs them on Linux against a `postgres:17` service container.

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE).
