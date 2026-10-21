import os;
import postgres;
import "support";

# The CA that signed the test server's certificate, from PEPPER_POSTGRES_CA
# (tests/setup-postgres.sh makes it); none when the server has no TLS.
_ca(): String? {
    var path = os.environment("PEPPER_POSTGRES_CA");
    if (path.is_empty() || path.value().size == 0) {
        return Optional<String>.Empty;
    }
    return path;
}

[Test]
tls_connects_and_verifies() {
    var server = _server();
    var ca = _ca();
    if (server.is_empty() || ca.is_empty()) {
        return;
    }
    var config = server.value();
    config.tls = true;
    config.root_certificate = ca;
    var db = postgres.Connection.connect(config).value();
    var rows = db.query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()").value();
    expect_equal(rows[0].get("ssl").value().to_string(), "true");
    db.close();
}

[Test]
tls_rejects_an_untrusted_certificate() {
    var server = _server();
    if (server.is_empty() || _ca().is_empty()) {
        return;
    }
    var config = server.value();
    config.tls = true;
    expect_equal(postgres.Connection.connect(config).error().code, "08006");
}
