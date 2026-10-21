import "../scram";

# RFC 7677 section 3: the SCRAM-SHA-256 example exchange.
[Test]
rfc_7677_example() {
    var scram = _Scram("user", "pencil", "rOprNGfwEbeRWgbNEkqO");
    expect_equal(scram.first(), "n,,n=user,r=rOprNGfwEbeRWgbNEkqO");
    var server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    expect_equal(
        scram.final(server_first).value(),
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
    );
    expect_true(scram.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=").is_ok());
    expect_true(scram.verify("v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=").is_err());
}
