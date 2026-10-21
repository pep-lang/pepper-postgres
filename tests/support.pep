## Helpers the integration tests share.

import os;
import postgres;

# The server the integration tests use, from PEPPER_POSTGRES_URL
# (`postgres://user:password@localhost:5432/db`); none when it is unset, and
# then each integration test returns without checking anything.
_server(): postgres.Config? {
    var url = os.environment("PEPPER_POSTGRES_URL");
    if (url.is_empty() || url.value().size == 0) {
        return Optional<postgres.Config>.Empty;
    }
    return Optional<postgres.Config>.Value(postgres.Config.parse(url.value()).value());
}

_connect(): postgres.Connection? {
    var config = _server();
    if (config.is_empty()) {
        return Optional<postgres.Connection>.Empty;
    }
    return Optional<postgres.Connection>.Value(postgres.Connection.connect(config.value()).value());
}
