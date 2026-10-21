## `PgError`, what a failed call returns, and `PgResult<T>`.

import io;

## An error: one the server reported, or one the client met on its side
## (a lost connection, a failed login, a row that does not decode).
##
## `code` is the SQLSTATE, five characters such as `23505`
## (`unique_violation`); see
## <https://www.postgresql.org/docs/current/errcodes-appendix.html>. The
## client's own errors use the class that fits them: `08006`
## (`connection_failure`) for a failed read or write, `08P01`
## (`protocol_violation`) for a message it cannot make sense of, `28000`
## (`invalid_authorization_specification`) for a login it cannot complete,
## and `22000` (`data_exception`) for a row `read<T>` cannot decode.
export struct PgError {
    ## `ERROR`, `FATAL` or `PANIC` from the server; `ERROR` for the
    ## client's own errors.
    var severity: String;
    ## The SQLSTATE code, such as `42P01` for an undefined table.
    var code: String;
    ## What went wrong (`relation "missing" does not exist`).
    var message: String;
    ## More about the error, when the server gives it.
    var detail: String?;
    ## What to do about it, when the server suggests something.
    var hint: String?;

    ## Creates an error with no detail or hint.
    ##
    ## @param code the SQLSTATE code
    ## @param message what went wrong
    construct(code: String, message: String) {
        severity = "ERROR";
        this.code = code;
        this.message = message;
        detail = Optional<String>.Empty;
        hint = Optional<String>.Empty;
    }

    ## Returns the severity, the message and the code, as
    ## `ERROR: message (SQLSTATE 42P01)`.
    ##
    ## @returns the error as text
    to_string(): String {
        return $"{severity}: {message} (SQLSTATE {code})";
    }
}

## The result of a call that can fail: its value, or a `PgError`.
##
## @typeParam T the value on success
export type PgResult<T> = Result<T, PgError>;

_io_error(error: io.IoError): PgError {
    return PgError("08006", "connection failure: " + error.message);
}

_protocol_error(message: String): PgError {
    return PgError("08P01", message);
}

_auth_error(message: String): PgError {
    return PgError("28000", message);
}
