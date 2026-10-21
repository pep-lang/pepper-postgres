import async;
import io;
import postgres;
import "../message";

# A fake server that logs the client in with no password, sending `count`
# notifications (payloads "1", "2", ...) before it is ready.
_notify_at_login(listener: io.SharedTcpListener, count: int) {
    var (stream, peer) = listener.accept().value();
    var request = Array<u8>();
    stream.read(request, 4096).value();
    var ok = Array<u8>();
    _put_int32(ok, 0);
    stream.write_all(_frame('R', ok)).value();
    for (var i in 1..count + 1) {
        var notification = Array<u8>();
        _put_int32(notification, 42);
        _put_cstring(notification, "events");
        _put_cstring(notification, $"{i}");
        stream.write_all(_frame('A', notification)).value();
    }
    var ready = Array<u8>();
    ready.append('I' as u8);
    stream.write_all(_frame('Z', ready)).value();
    stream.read(request, 4096);
}

[Test]
a_full_queue_drops_the_oldest_notifications() {
    var listener = io.SharedTcpListener.bind(io.SocketAddress.parse("127.0.0.1:0").value()).value();
    var server = async.Thread.spawn(() => {
        _notify_at_login(listener, 5);
    });
    var config = postgres.Config("ada");
    expect_equal(config.max_notifications, 10000 as ulong);
    config.host = "127.0.0.1";
    config.port = listener.local_address().value().port();
    config.max_notifications = 3;
    var connection = postgres.Connection.connect(config).value();
    expect_equal(connection.dropped_notifications(), 2 as ulong);
    var kept = connection.notifications();
    expect_equal(kept.count, 3 as ulong);
    expect_equal(kept[0].payload, "3");
    expect_equal(kept[2].payload, "5");
    expect_equal(kept[2].channel, "events");
    expect_equal(connection.notifications().count, 0 as ulong);
    connection.close();
    server.join();
}
