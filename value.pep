## `Value`: one parameter or column value.

import digest;
import json;
import math;

## A value sent as a query parameter or read from a column.
##
## A column decodes by its type: `boolean` to `Bool`; `smallint`,
## `integer`, `bigint` and `oid` to `Integer`; `real` and
## `double precision` to `Real`; `bytea` to `Bytes`; SQL `NULL` to `Null`.
## Every other type, such as `numeric`, `text`, `date`, `uuid` or `json`,
## is `Text` in PostgreSQL's text form, which the caller parses as it
## needs (`"12.50"`, `"2026-10-20"`).
##
## A parameter's type is the one the server infers from where it is used,
## so `Text("42")` works for an `integer` parameter too, and `Bytes` is sent
## as binary.
##
## @example
##     import postgres;
##
##     var parameters = [postgres.Value.Integer(1), postgres.Value.Text("Ada"), postgres.Value.Null];
export enum Value {
    ## SQL `NULL`.
    Null,
    ## A `boolean`.
    ##
    ## @param value the boolean
    Bool(value: bool),
    ## A `smallint`, `integer`, `bigint` or `oid`.
    ##
    ## @param value the integer
    Integer(value: long),
    ## A `real` or `double precision`.
    ##
    ## @param value the number
    Real(value: double),
    ## Any other type, in PostgreSQL's text form.
    ##
    ## @param value the text
    Text(value: String),
    ## A `bytea`.
    ##
    ## @param bytes the bytes
    Bytes(bytes: u8[]),

    ## Returns the value as PostgreSQL writes it in text form: `NULL`,
    ## `true`, `42`, `2.5`, the text itself, or bytes as `\x` and hex.
    ##
    ## @returns the value as text
    to_string(): String {
        return match (this) {
            Null => "NULL",
            Bool(b) => b ? "true" : "false",
            Integer(n) => $"{n}",
            Real(x) => $"{x}",
            Text(text) => text,
            Bytes(bytes) => "\\x" + digest.to_hex(bytes),
        };
    }
}

# Type OIDs of the types `_decode_text` decodes (pg_type.dat).
const _BOOL_OID: int = 16;
const _BYTEA_OID: int = 17;
const _INT8_OID: int = 20;
const _INT2_OID: int = 21;
const _INT4_OID: int = 23;
const _OID_OID: int = 26;
const _FLOAT4_OID: int = 700;
const _FLOAT8_OID: int = 701;

_is_binary(value: Value): bool {
    return match (value) {
        Bytes(bytes) => true,
        else => false,
    };
}

# A parameter as the Bind message carries it: none for NULL.
_encode_parameter(value: Value): u8[]? {
    return match (value) {
        Null => Optional<u8[]>.Empty,
        Bool(b) => Optional<u8[]>.Value((b ? "t" : "f").bytes()),
        Integer(n) => Optional<u8[]>.Value(to_string(n).bytes()),
        Real(x) => Optional<u8[]>.Value(to_string(x).bytes()),
        Text(text) => Optional<u8[]>.Value(text.bytes()),
        Bytes(bytes) => Optional<u8[]>.Value(bytes),
    };
}

# A column value in text format, decoded by its type's OID. Text that does
# not parse as its type says it would stays `Text`.
_decode_text(type_oid: int, text: String): Value {
    if (type_oid == _BOOL_OID) {
        return Value.Bool(text == "t");
    }
    if (type_oid == _INT2_OID || type_oid == _INT4_OID || type_oid == _INT8_OID || type_oid == _OID_OID) {
        var n = math.parse_int(text);
        if (n.is_value()) {
            return Value.Integer(n.value());
        }
    } else if (type_oid == _FLOAT4_OID || type_oid == _FLOAT8_OID) {
        var x = double.parse(text);
        if (x.is_value()) {
            return Value.Real(x.value());
        }
    } else if (type_oid == _BYTEA_OID && text.starts_with("\\x")) {
        var bytes = digest.from_hex(text.substr_bytes(2, text.size - 2));
        if (bytes.is_ok()) {
            return Value.Bytes(bytes.value());
        }
    }
    return Value.Text(text);
}

_json_of(value: Value): json.JsonValue {
    return match (value) {
        Null => json.JsonValue.Null,
        Bool(b) => json.JsonValue.Bool(b),
        Integer(n) => json.JsonValue.Integer(n),
        Real(x) => json.JsonValue.Number(x),
        Text(text) => json.JsonValue.String(text),
        Bytes(bytes) => _json_bytes(bytes),
    };
}

_json_bytes(bytes: u8[]): json.JsonValue {
    var items = json.JsonValue.array();
    for (var item in bytes) {
        items.append(json.JsonValue.Integer(item as long));
    }
    return items;
}
