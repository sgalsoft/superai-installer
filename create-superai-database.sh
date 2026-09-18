#!/usr/bin/env bash

# ============================================================
# create superai postgres database
#
# Run this on the PostgreSQL server, or from a host that can
# reach PostgreSQL over the internal network.
#
# It creates:
#   role:     superai
#   database: superai
#
# The password is prompted and is never written to disk.
# ============================================================

set -Eeuo pipefail

DB_USER="${DB_USER:-superai}"
DB_NAME="${DB_NAME:-superai}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

read_input() {
    local prompt="$1" variable="$2" value=""
    read -r -p "$prompt" value < /dev/tty
    printf -v "$variable" '%s' "$value"
}

read_secret() {
    local prompt="$1" variable="$2" value=""
    read -r -s -p "$prompt" value < /dev/tty
    echo
    printf -v "$variable" '%s' "$value"
}

require_command psql

if [[ -z "${DB_PASSWORD}" ]]; then
    read_secret "Password for database user ${DB_USER}: " DB_PASSWORD
fi
[[ -n "${DB_PASSWORD}" ]] || {
    echo "ERROR: DB_PASSWORD cannot be empty." >&2
    exit 1
}

export PGPASSWORD="${PGPASSWORD:-}"

echo
echo "PostgreSQL admin connection:"
echo "  host:     ${PGHOST}"
echo "  port:     ${PGPORT}"
echo "  user:     ${PGUSER}"
echo "  database: ${PGDATABASE}"
echo
echo "Target:"
echo "  role:     ${DB_USER}"
echo "  database: ${DB_NAME}"
echo

psql -X -v ON_ERROR_STOP=1 \
    -h "${PGHOST}" \
    -p "${PGPORT}" \
    -U "${PGUSER}" \
    -d "${PGDATABASE}" \
    -v superai_db_user="${DB_USER}" \
    -v superai_db_name="${DB_NAME}" \
    -v superai_db_password="${DB_PASSWORD}" <<'SQL'
SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'superai_db_user',
    :'superai_db_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'superai_db_user'
) gexec

SELECT format(
    'ALTER ROLE %I LOGIN PASSWORD %L',
    :'superai_db_user',
    :'superai_db_password'
) gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'superai_db_name',
    :'superai_db_user'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'superai_db_name'
) gexec

SELECT format(
    'ALTER DATABASE %I OWNER TO %I',
    :'superai_db_name',
    :'superai_db_user'
) gexec
SQL

unset PGPASSWORD DB_PASSWORD

echo
echo "superai PostgreSQL role and database are ready."
echo "  role:     ${DB_USER}"
echo "  database: ${DB_NAME}"
echo "  endpoint: ${PGHOST}:${PGPORT}"
