## The frontend/backend protocol, version 3: the messages the client sends,
## built as bytes, and a reader for the fields of those the server sends.

import text;
import "error";
import "value";

# The protocol version a startup message asks for: 3.0.
const _PROTOCOL_VERSION: int = 196608;
# The request code of an SSLRequest.
const _SSL_REQUEST_CODE: int = 80877103;

_put_int32(out: u8[], value: int) {
    out.append(((value >> 24) & 0xff) as u8);
    out.append(((value >> 16) & 0xff) as u8);
    out.append(((value >> 8) & 0xff) as u8);
    out.append((value & 0xff) as u8);
}

_put_int16(out: u8[], value: int) {
    out.append(((value >> 8) & 0xff) as u8);
    out.append((value & 0xff) as u8);
}

_put_cstring(out: u8[], text: String) {
    out.append_all(text.bytes());
    out.append(0 as u8);
}

# A message: its type byte, its length (which counts itself), then `body`.
_frame(type_byte: char, body: u8[]): u8[] {
    var out = Array<u8>();
    out.append(type_byte as u8);
    _put_int32(out, (body.count + 4) as int);
    out.append_all(body);
    return out;
}

# The untyped startup message: the version, then name/value pairs.
_startup_message(parameters: Array<(String, String)>): u8[] {
    var body = Array<u8>();
    _put_int32(body, _PROTOCOL_VERSION);
    for (var (name, value) in parameters) {
        _put_cstring(body, name);
        _put_cstring(body, value);
    }
    body.append(0 as u8);
    var out = Array<u8>();
    _put_int32(out, (body.count + 4) as int);
    out.append_all(body);
    return out;
}

_ssl_request(): u8[] {
    var out = Array<u8>();
    _put_int32(out, 8);
    _put_int32(out, _SSL_REQUEST_CODE);
    return out;
}

_password_message(password: String): u8[] {
    var body = Array<u8>();
    _put_cstring(body, password);
    return _frame('p', body);
}

_sasl_initial_response(mechanism: String, data: String): u8[] {
    var body = Array<u8>();
    _put_cstring(body, mechanism);
    var bytes = data.bytes();
    _put_int32(body, bytes.count as int);
    body.append_all(bytes);
    return _frame('p', body);
}

_sasl_response(data: String): u8[] {
    return _frame('p', data.bytes());
}

_query_message(sql: String): u8[] {
    var body = Array<u8>();
    _put_cstring(body, sql);
    return _frame('Q', body);
}

# Parse: prepares `sql` as the statement `name` ("" is the unnamed one),
# leaving every parameter's type for the server to infer.
_parse_message(name: String, sql: String): u8[] {
    var body = Array<u8>();
    _put_cstring(body, name);
    _put_cstring(body, sql);
    _put_int16(body, 0);
    return _frame('P', body);
}

# Bind: binds `parameters` to the statement `name` in the unnamed portal.
# Bytes go in binary format, everything else as text; every result column
# comes back as text.
_bind_message(name: String, parameters: Value[]): u8[] {
    var body = Array<u8>();
    _put_cstring(body, "");
    _put_cstring(body, name);
    _put_int16(body, parameters.count as int);
    for (var parameter in parameters) {
        _put_int16(body, _is_binary(parameter) ? 1 : 0);
    }
    _put_int16(body, parameters.count as int);
    for (var parameter in parameters) {
        var encoded = _encode_parameter(parameter);
        if (encoded.is_empty()) {
            _put_int32(body, -1);
        } else {
            _put_int32(body, encoded.value().count as int);
            body.append_all(encoded.value());
        }
    }
    _put_int16(body, 0);
    return _frame('B', body);
}

# Describe: 'S' for a statement (its parameters and columns), 'P' for a
# portal (its columns).
_describe_message(kind: char, name: String): u8[] {
    var body = Array<u8>();
    body.append(kind as u8);
    _put_cstring(body, name);
    return _frame('D', body);
}

# Execute: runs the unnamed portal to completion.
_execute_message(): u8[] {
    var body = Array<u8>();
    _put_cstring(body, "");
    _put_int32(body, 0);
    return _frame('E', body);
}

_close_message(kind: char, name: String): u8[] {
    var body = Array<u8>();
    body.append(kind as u8);
    _put_cstring(body, name);
    return _frame('C', body);
}

_sync_message(): u8[] {
    return _frame('S', Array<u8>());
}

_terminate_message(): u8[] {
    return _frame('X', Array<u8>());
}

# One message from the server: its type byte and its body.
struct _Backend {
    var type_byte: char;
    var body: u8[];

    construct(type_byte: char, body: u8[]) {
        this.type_byte = type_byte;
        this.body = body;
    }
}

# Reads the fields of a message body in order. A read past the end yields
# zeros and sets `failed`, so a parser checks once, at the end.
struct _Fields {
    var _body: u8[];
    var _at: ulong;
    var failed: bool;

    construct(body: u8[]) {
        _body = body;
        _at = 0;
        failed = false;
    }

    _take(count: ulong): bool {
        if (_at + count > _body.count) {
            failed = true;
            _at = _body.count;
            return false;
        }
        return true;
    }

    byte(): u8 {
        if (!_take(1)) {
            return 0;
        }
        _at += 1;
        return _body[_at - 1];
    }

    int16(): int {
        if (!_take(2)) {
            return 0;
        }
        var value = ((_body[_at] as int) << 8) | (_body[_at + 1] as int);
        _at += 2;
        # Sign-extend: a column count never needs it, a format code may.
        return value >= 0x8000 ? value - 0x10000 : value;
    }

    int32(): int {
        if (!_take(4)) {
            return 0;
        }
        var value = ((_body[_at] as uint) << 24)
            | ((_body[_at + 1] as uint) << 16)
            | ((_body[_at + 2] as uint) << 8)
            | (_body[_at + 3] as uint);
        _at += 4;
        return value as int;
    }

    bytes(count: ulong): u8[] {
        if (!_take(count)) {
            return Array<u8>();
        }
        var out = _body.slice(_at, _at + count).to_array();
        _at += count;
        return out;
    }

    cstring(): String {
        var end = _at;
        while (end < _body.count && _body[end] != 0) {
            end += 1;
        }
        if (end == _body.count) {
            failed = true;
            _at = end;
            return "";
        }
        var value = text.Utf8.decode_lossy(_body.slice(_at, end).to_array());
        _at = end + 1;
        return value;
    }

    rest(): u8[] {
        return bytes(_body.count - _at);
    }
}

# The fields of an ErrorResponse or NoticeResponse.
_error_of(body: u8[]): PgError {
    var fields = _Fields(body);
    var error = PgError("XX000", "");
    while (true) {
        var field = fields.byte();
        if (field == 0) {
            break;
        }
        var value = fields.cstring();
        if (field == 'V' as u8) {
            error.severity = value;
        } else if (field == 'S' as u8 && error.severity == "ERROR") {
            error.severity = value;
        } else if (field == 'C' as u8) {
            error.code = value;
        } else if (field == 'M' as u8) {
            error.message = value;
        } else if (field == 'D' as u8) {
            error.detail = Optional<String>.Value(value);
        } else if (field == 'H' as u8) {
            error.hint = Optional<String>.Value(value);
        }
    }
    return error;
}

# One column of a RowDescription.
struct _Column {
    var name: String;
    var type_oid: int;

    construct(name: String, type_oid: int) {
        this.name = name;
        this.type_oid = type_oid;
    }
}

_columns_of(body: u8[]): PgResult<_Column[]> {
    var fields = _Fields(body);
    var count = fields.int16();
    var columns = Array<_Column>();
    for (var i in 0..count) {
        var name = fields.cstring();
        fields.int32();  # table oid
        fields.int16();  # column number
        var type_oid = fields.int32();
        fields.int16();  # type size
        fields.int32();  # type modifier
        fields.int16();  # format
        columns.append(_Column(name, type_oid));
    }
    if (fields.failed) {
        return PgResult<_Column[]>.err(_protocol_error("malformed RowDescription"));
    }
    return PgResult<_Column[]>.ok(columns);
}

# A DataRow's values, decoded by their columns' types.
_values_of(body: u8[], columns: _Column[]): PgResult<Value[]> {
    var fields = _Fields(body);
    var count = fields.int16();
    if (count != columns.count as int) {
        return PgResult<Value[]>.err(_protocol_error("DataRow does not match its RowDescription"));
    }
    var values = Array<Value>();
    for (var i in 0..columns.count) {
        var size = fields.int32();
        if (size < 0) {
            values.append(Value.Null);
        } else {
            var decoded = text.Utf8.decode_lossy(fields.bytes(size as ulong));
            values.append(_decode_text(columns[i].type_oid, decoded));
        }
    }
    if (fields.failed) {
        return PgResult<Value[]>.err(_protocol_error("malformed DataRow"));
    }
    return PgResult<Value[]>.ok(values);
}
