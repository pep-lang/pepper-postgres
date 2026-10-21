import digest;
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

[Test]
bad_server_first_messages_are_rejected() {
    var salt = "s=W22ZaJ0SNY7soEsUEjb6gQ==";
    expect_equal(_Scram("u", "p", "abc").final("r=xyz123," + salt + ",i=4096").error().code, "28000");
    expect_equal(_Scram("u", "p", "abc").final("r=abc," + salt + ",i=4096").error().code, "28000");
    expect_equal(_Scram("u", "p", "abc").final("r=abcdef," + salt + ",i=0").error().code, "28000");
    expect_equal(_Scram("u", "p", "abc").final("r=abcdef,i=4096").error().code, "28000");
    expect_equal(_Scram("u", "p", "abc").verify("e=invalid-proof").error().code, "28000");
}

# RFC 7914 section 11: PBKDF2-HMAC-SHA256 test vectors. Their dkLen is 64;
# SCRAM's Hi() derives one 32-byte block, the first half.
[Test]
pbkdf2_matches_rfc_7914() {
    expect_equal(
        digest.to_hex(_pbkdf2_sha256("passwd", "salt".bytes(), 1)),
        "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
    );
    expect_equal(
        digest.to_hex(_pbkdf2_sha256("Password", "NaCl".bytes(), 80000)),
        "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56"
    );
}
