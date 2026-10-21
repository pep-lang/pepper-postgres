import async;
import io;
import postgres;
import "../message";

# A fake server that asks for SCRAM-SHA-256, reads the client's first
# message, then claims AuthenticationOk without proving it knows the
# password.
_skip_scram_proof(listener: io.SharedTcpListener) {
    var (stream, peer) = listener.accept().value();
    var request = Array<u8>();
    stream.read(request, 4096).value();
    var sasl = Array<u8>();
    _put_int32(sasl, 10);
    _put_cstring(sasl, "SCRAM-SHA-256");
    sasl.append(0 as u8);
    stream.write_all(_frame('R', sasl)).value();
    stream.read(request, 4096).value();
    var ok = Array<u8>();
    _put_int32(ok, 0);
    stream.write_all(_frame('R', ok)).value();
    var ready = Array<u8>();
    ready.append('I' as u8);
    stream.write_all(_frame('Z', ready)).value();
    stream.read(request, 4096);
}

[Test]
login_requires_the_server_scram_proof() {
    var listener = io.SharedTcpListener.bind(io.SocketAddress.parse("127.0.0.1:0").value()).value();
    var server = async.Thread.spawn(() => {
        _skip_scram_proof(listener);
    });
    var config = postgres.Config("ada", "secret");
    config.host = "127.0.0.1";
    config.port = listener.local_address().value().port();
    var connection = postgres.Connection.connect(config);
    expect_equal(connection.error().message, "the server did not complete SCRAM authentication");
    server.join();
}
