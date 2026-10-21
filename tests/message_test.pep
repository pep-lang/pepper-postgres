import digest;
import "../message";
import "../value";

_bytes(text: String): u8[] {
    return text.bytes();
}

[Test]
frames_carry_their_length() {
    expect_equal(digest.to_hex(_sync_message()), digest.to_hex([83 as u8, 0 as u8, 0 as u8, 0 as u8, 4 as u8]));
    var query = _query_message("SELECT 1");
    expect_equal(query.count, 14 as ulong);
    expect_equal(query[0], 'Q' as u8);
    expect_equal(query[4], 13 as u8);
    expect_equal(query[13], 0 as u8);
}

[Test]
startup_message_lists_parameters() {
    var message = _startup_message([("user", "ada"), ("database", "db")]);
    # length, version 3.0, "user\0ada\0database\0db\0", final \0
    expect_equal(message.count, (8 + 9 + 12 + 1) as ulong);
    expect_equal(message[3], message.count as u8);
    expect_equal(message[5], 3 as u8);
    expect_equal(message[message.count - 1], 0 as u8);
}

[Test]
ssl_request_is_its_code() {
    expect_equal(
        digest.to_hex(_ssl_request()),
        digest.to_hex([0 as u8, 0 as u8, 0 as u8, 8 as u8, 4 as u8, 210 as u8, 22 as u8, 47 as u8])
    );
}

[Test]
bind_sends_bytes_as_binary_and_null_as_minus_one() {
    var message = _bind_message("s1", [Value.Integer(42), Value.Null, Value.Bytes([7 as u8])]);
    var fields = _Fields(message.slice(5, message.count).to_array());
    expect_equal(fields.cstring(), "");
    expect_equal(fields.cstring(), "s1");
    expect_equal(fields.int16(), 3);
    expect_equal(fields.int16(), 0);
    expect_equal(fields.int16(), 0);
    expect_equal(fields.int16(), 1);
    expect_equal(fields.int16(), 3);
    expect_equal(fields.int32(), 2);
    expect_equal(digest.to_hex(fields.bytes(2)), digest.to_hex(_bytes("42")));
    expect_equal(fields.int32(), -1);
    expect_equal(fields.int32(), 1);
    expect_equal(fields.byte(), 7 as u8);
    expect_equal(fields.int16(), 0);
    expect_false(fields.failed);
    fields.byte();
    expect_true(fields.failed);
}

[Test]
error_response_decodes_its_fields() {
    var body = _bytes("SERROR\0VERROR\0C42P01\0Mrelation \"t\" does not exist\0HCreate it.\0\0");
    var error = _error_of(body);
    expect_equal(error.severity, "ERROR");
    expect_equal(error.code, "42P01");
    expect_equal(error.message, "relation \"t\" does not exist");
    expect_equal(error.hint.value(), "Create it.");
    expect_true(error.detail.is_empty());
}

[Test]
row_description_and_data_row_decode_by_type() {
    var description = Array<u8>();
    _put_int16(description, 3);
    for (var (name, oid) in [("id", 23), ("name", 25), ("blob", 17)]) {
        _put_cstring(description, name);
        _put_int32(description, 0);
        _put_int16(description, 0);
        _put_int32(description, oid);
        _put_int16(description, 4);
        _put_int32(description, -1);
        _put_int16(description, 0);
    }
    var columns = _columns_of(description).value();
    expect_equal(columns.count, 3 as ulong);
    expect_equal(columns[1].name, "name");
    var row = Array<u8>();
    _put_int16(row, 3);
    _put_int32(row, 2);
    row.append_all(_bytes("-7"));
    _put_int32(row, -1);
    _put_int32(row, 6);
    row.append_all(_bytes("\\x0aff"));
    var values = _values_of(row, columns).value();
    expect_equal(to_string(values[0]), to_string(Value.Integer(-7)));
    expect_true(values[1] is Null);
    expect_equal(to_string(values[2]), to_string(Value.Bytes([10 as u8, 255 as u8])));
    expect_true(_values_of(row.slice(0, 5).to_array(), columns).is_err());
}

[Test]
text_values_decode_by_type() {
    expect_equal(to_string(_decode_text(16, "t")), to_string(Value.Bool(true)));
    expect_equal(to_string(_decode_text(701, "2.5")), to_string(Value.Real(2.5)));
    expect_equal(to_string(_decode_text(1700, "12.50")), to_string(Value.Text("12.50")));
    expect_equal(to_string(_decode_text(20, "9223372036854775807")), to_string(Value.Integer(9223372036854775807)));
}
