## SCRAM-SHA-256 (RFC 5802, RFC 7677): the client side of the password
## exchange PostgreSQL asks for by default.

import base64;
import digest;
import math;
import random;
import "error";

# The client side of one SCRAM-SHA-256 exchange, without channel binding
# (`n,,`): `first()` is the client-first message, `final(server_first)`
# answers the server's challenge, and `verify(server_final)` checks that the
# server knew the password too.
# shortcut: the password is not SASLprep-normalized (RFC 4013), so a
# non-ASCII password must already be in NFKC form; normalize it here when
# the runtime gains Unicode normalization.
struct _Scram {
    var _password: String;
    var _first_bare: String;
    var _nonce: String;
    var _server_signature: u8[];

    construct(user: String, password: String, nonce: String) {
        _password = password;
        _nonce = nonce;
        _first_bare = $"n={_sasl_name(user)},r={nonce}";
        _server_signature = Array<u8>();
    }

    first(): String {
        return "n,," + _first_bare;
    }

    final(server_first: String): PgResult<String> {
        var nonce = _attribute(server_first, "r");
        var salt = _attribute(server_first, "s");
        var rounds = _attribute(server_first, "i");
        if (nonce.is_empty() || salt.is_empty() || rounds.is_empty()) {
            return PgResult<String>.err(_auth_error("malformed SCRAM server-first message"));
        }
        if (!nonce.value().starts_with(_nonce) || nonce.value().size == _nonce.size) {
            return PgResult<String>.err(_auth_error("the server's SCRAM nonce does not extend ours"));
        }
        var salt_bytes = base64.decode(salt.value());
        var count = math.parse_int(rounds.value());
        if (salt_bytes.is_err() || count.is_empty() || count.value() < 1) {
            return PgResult<String>.err(_auth_error("malformed SCRAM salt or iteration count"));
        }
        var salted = _pbkdf2_sha256(_password, salt_bytes.value(), count.value() as ulong);
        var client_key = digest.hmac_sha256(salted, "Client Key".bytes());
        var without_proof = "c=biws,r=" + nonce.value();
        var message = (_first_bare + "," + server_first + "," + without_proof).bytes();
        var signature = digest.hmac_sha256(digest.sha256(client_key), message);
        var proof = Array<u8>();
        for (var i in 0..client_key.count) {
            proof.append(client_key[i] ^ signature[i]);
        }
        var server_key = digest.hmac_sha256(salted, "Server Key".bytes());
        _server_signature = digest.hmac_sha256(server_key, message);
        return PgResult<String>.ok(without_proof + ",p=" + base64.encode(proof));
    }

    verify(server_final: String): PgResult<void> {
        var error = _attribute(server_final, "e");
        if (error.is_value()) {
            return PgResult<void>.err(_auth_error("SCRAM authentication failed: " + error.value()));
        }
        var verifier = _attribute(server_final, "v");
        if (verifier.is_empty()) {
            return PgResult<void>.err(_auth_error("malformed SCRAM server-final message"));
        }
        var signature = base64.decode(verifier.value());
        if (signature.is_err() || !digest.equal_constant_time(signature.value(), _server_signature)) {
            return PgResult<void>.err(_auth_error("the server's SCRAM signature is wrong"));
        }
        return PgResult<void>.ok();
    }
}

# The value of `name=` in a SCRAM message's comma-separated attributes.
_attribute(message: String, name: String): String? {
    for (var part in message.split(",")) {
        if (part.starts_with(name + "=")) {
            return Optional<String>.Value(part.substr_bytes(name.size + 1, part.size - name.size - 1));
        }
    }
    return Optional<String>.Empty;
}

# A user name as SCRAM writes it: `,` and `=` escaped (RFC 5802 5.1).
_sasl_name(user: String): String {
    return user.replace("=", "=3D").replace(",", "=2C");
}

# PBKDF2 (RFC 8018) with HMAC-SHA-256, one 32-byte block: SCRAM's Hi().
# shortcut: a private copy until the runtime's digest has pbkdf2_sha256
# (pep-lang/pepper#69); switch to it then.
_pbkdf2_sha256(password: String, salt: u8[], rounds: ulong): u8[] {
    var mac = digest.Hmac<digest.Sha256>(password);
    var block = salt.copy();
    block.append_all([0 as u8, 0 as u8, 0 as u8, 1 as u8]);
    mac.update(block);
    var u = mac.finish();
    var result = u.copy();
    for (var round in 1..rounds) {
        mac.update(u);
        u = mac.finish();
        for (var i in 0..result.count) {
            result[i] = result[i] ^ u[i];
        }
    }
    return result;
}

# A fresh client nonce: 18 random bytes, base64 (printable, no `,`).
_scram_nonce(): String {
    return base64.encode(random.bytes(18));
}
