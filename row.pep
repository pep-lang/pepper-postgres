## `Row`: one row a query returned.

import json;
import "error";
import "value";

## One row of a query's result: its values, in column order, and the
## columns' names.
##
## `get` reads a value by position or by column name; `read<T>` decodes the
## row into a struct.
##
## @example
##     for (var row in db.query("SELECT id, name FROM users").value()) {
##         print($"{row.get(0)}: {row.get("name").value()}");
##     }
export struct Row {
    var _names: String[];
    var _values: Value[];

    ## Creates a row; `Connection.query` makes them.
    ##
    ## @param names the columns' names, shared by every row of a result
    ## @param values the row's values, one per column
    construct(names: String[], values: Value[]) {
        _names = names;
        _values = values;
    }

    ## Returns the number of columns.
    ##
    ## @returns the column count
    count(): ulong {
        return _values.count;
    }

    ## Returns the name of the column at `index`.
    ##
    ## @param index the column's position, from 0
    ## @returns the column's name, as the query's result names it
    ## @panics if `index` is not less than `count()`
    name(index: ulong): String {
        return _names[index];
    }

    ## Returns the value of the column at `index`.
    ##
    ## @param index the column's position, from 0
    ## @returns the value; `Value.Null` for SQL `NULL`
    ## @panics if `index` is not less than `count()`
    get(index: ulong): Value {
        return _values[index];
    }

    ## Returns the value of the first column named `name`.
    ##
    ## @param name the column's name, as the query's result names it
    ## @returns the value, or none when no column has that name
    get(name: String): Value? {
        var index = _names.find(name);
        if (index.is_empty()) {
            return Optional<Value>.Empty;
        }
        return Optional<Value>.Value(_values[index.value()]);
    }

    ## Decodes the row into a `T`, as `json.from_json` decodes an object
    ## whose keys are the column names.
    ##
    ## A column fills the property of its name (or of its `[Name("...")]`);
    ## `NULL` fills an `Optional` property as none. Integers fill number
    ## properties, `Text` fills `String`s, booleans `bool`s and `bytea`
    ## `u8[]` properties. A column no property names is ignored, and a
    ## property no column names keeps its default, unless it is
    ## `[Required]`.
    ##
    ## @typeParam T the struct to decode into
    ## @returns the decoded row, or an error with code `22000` whose message
    ##   is the conversion's (`$.age: expected a number, found a string`)
    read<T>(): PgResult<T> {
        var object = json.JsonValue.object();
        for (var i in 0.._values.count) {
            object[_names[i]] = _json_of(_values[i]);
        }
        var decoded = json.from_json<T>(object);
        if (decoded.is_err()) {
            return PgResult<T>.err(PgError("22000", decoded.error().message));
        }
        return PgResult<T>.ok(decoded.value());
    }
}
