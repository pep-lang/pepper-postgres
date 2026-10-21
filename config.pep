## `Config`: where a connection goes and how it logs in.

import "error";

# `Config.max_notifications` unless it is set.
const _DEFAULT_MAX_NOTIFICATIONS: ulong = 10000;

## The settings of a connection: the server, the login, the database, and
## whether to use TLS.
##
## Make one with the constructor and set fields, or parse a connection URL
## with `parse`.
##
## @example
##     var config = postgres.Config("app", "secret");
##     config.host = "db.example.com";
##     config.database = "inventory";
##     config.tls = true;
export struct Config {
    ## The server's host name or address.
    var host: String;
    ## The server's port.
    var port: u16;
    ## The user to log in as.
    var user: String;
    ## The user's password; empty when the server asks for none.
    var password: String;
    ## The database to connect to; empty for the one named after the user.
    var database: String;
    ## Whether to require TLS. The server's certificate is checked against
    ## the system's trusted roots (plus `root_certificate`) and must name
    ## `host`; the connection fails when the server does not offer TLS.
    var tls: bool;
    ## A PEM file of a further root certificate to trust, such as a
    ## private CA's.
    var root_certificate: String?;
    ## The most notifications a connection keeps until `notifications()` or
    ## `wait_for_notification()` takes them: 10,000 by default, and at
    ## least 1. Past it the oldest is dropped, and counted in
    ## `Connection.dropped_notifications()`.
    var max_notifications: ulong;

    ## Creates a config for `localhost:5432` without TLS.
    ##
    ## @param user the user to log in as
    ## @param password the user's password
    construct(user: String, password: String = "") {
        host = "localhost";
        port = 5432;
        this.user = user;
        this.password = password;
        database = "";
        tls = false;
        root_certificate = Optional<String>.Empty;
        max_notifications = _DEFAULT_MAX_NOTIFICATIONS;
    }

    ## Parses a connection URL,
    ## `postgres://user:password@host:port/database?sslmode=require`, as
    ## libpq writes them (`postgresql://` too). Every part but the host is
    ## optional, and percent-escapes are decoded.
    ##
    ## `sslmode` `require`, `verify-ca` and `verify-full` set `tls` (which
    ## always verifies the certificate); `disable`, `allow` and `prefer`
    ## leave it off. `sslrootcert` sets `root_certificate`. Other
    ## parameters are ignored.
    ##
    ## @param url the connection URL
    ## @returns the config, or an error with code `08000` when the URL is
    ##   not a PostgreSQL URL
    ## @example
    ##     var config = postgres.Config.parse("postgres://app:secret@localhost/inventory").value();
    static parse(url: String): PgResult<Config> {
        var parsed = Uri.parse(url);
        if (parsed.is_err()) {
            return PgResult<Config>.err(PgError("08000", "invalid connection URL: " + parsed.error().message));
        }
        var uri = parsed.value();
        if ((uri.scheme != "postgres" && uri.scheme != "postgresql") || uri.host.is_empty()) {
            return PgResult<Config>.err(PgError("08000", "a connection URL starts with postgres://host"));
        }
        var config = Config("");
        if (uri.host.value().size > 0) {
            config.host = _decoded(uri.host.value());
        }
        if (uri.port.is_value()) {
            config.port = uri.port.value();
        }
        if (uri.user_info.is_value()) {
            var credentials = uri.user_info.value().split_once(":");
            if (credentials.is_value()) {
                var (user, password) = credentials.value();
                config.user = _decoded(user);
                config.password = _decoded(password);
            } else {
                config.user = _decoded(uri.user_info.value());
            }
        }
        if (uri.path.size > 1) {
            config.database = _decoded(uri.path.substr_bytes(1, uri.path.size - 1));
        }
        if (uri.query.is_value()) {
            var pairs = Uri.decode_form(uri.query.value());
            if (pairs.is_err()) {
                return PgResult<Config>.err(PgError("08000", "invalid connection URL query"));
            }
            for (var (name, value) in pairs.value()) {
                if (name == "sslmode") {
                    config.tls = value == "require" || value == "verify-ca" || value == "verify-full";
                } else if (name == "sslrootcert") {
                    config.root_certificate = Optional<String>.Value(value);
                }
            }
        }
        return PgResult<Config>.ok(config);
    }
}

_decoded(text: String): String {
    var decoded = Uri.decode(text);
    return decoded.is_ok() ? decoded.value() : text;
}
