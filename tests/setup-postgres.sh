#!/usr/bin/env bash
# Turns on TLS in a running postgres container for the integration tests:
# makes a throwaway CA and a server certificate for localhost, installs them
# in the container, and reloads the server. Prints nothing else of note;
# the CA lands in <out>/ca.pem for PEPPER_POSTGRES_CA.
#
# Usage: tests/setup-postgres.sh <container> <user> <out-dir>
set -euo pipefail

container="$1"
user="$2"
out="$3"
mkdir -p "$out"
cd "$out"
# Git Bash on Windows would rewrite the container paths below.
export MSYS_NO_PATHCONV=1

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=pepper-postgres test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout ca.key -out ca.pem
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 \
    -extfile server.ext -out server.pem

data=/var/lib/postgresql/data
docker cp server.pem "$container:$data/server.crt"
docker cp server.key "$container:$data/server.key"
docker exec -u root "$container" chown postgres:postgres "$data/server.crt" "$data/server.key"
docker exec -u root "$container" chmod 600 "$data/server.key"
docker exec -u postgres "$container" psql -U "$user" -d postgres -v ON_ERROR_STOP=1 \
    -c "ALTER SYSTEM SET ssl = on" -c "SELECT pg_reload_conf()"
