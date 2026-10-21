import postgres;

[Test]
parse_reads_every_part() {
    var config = postgres.Config.parse(
        "postgres://ada%40x:p%3Ass@db.example.com:6543/my%20db?sslmode=verify-full&sslrootcert=ca.pem"
    ).value();
    expect_equal(config.user, "ada@x");
    expect_equal(config.password, "p:ss");
    expect_equal(config.host, "db.example.com");
    expect_equal(config.port as int, 6543);
    expect_equal(config.database, "my db");
    expect_true(config.tls);
    expect_equal(config.root_certificate.value(), "ca.pem");
}

[Test]
parse_defaults_and_rejects() {
    var config = postgres.Config.parse("postgresql://localhost?sslmode=prefer").value();
    expect_equal(config.port as int, 5432);
    expect_equal(config.user, "");
    expect_equal(config.database, "");
    expect_false(config.tls);
    expect_equal(postgres.Config.parse("mysql://localhost/x").error().code, "08000");
}
