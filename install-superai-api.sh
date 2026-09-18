#!/usr/bin/env bash

# ============================================================
# superai api installer
#
# Public installer:
#   https://github.com/sgalsoft/superai-installer
#
# Private application repository:
#   https://github.com/sgalcheung/superai-api
#
# Usage:
#   sudo bash install-superai-api.sh
#   sudo bash install-superai-api.sh install
#   sudo bash install-superai-api.sh upgrade
#   sudo bash install-superai-api.sh status
#   sudo bash install-superai-api.sh restart
#   sudo bash install-superai-api.sh uninstall
#
# Environment variables:
#   GITHUB_TOKEN
#   DB_HOST
#   DB_PORT
#   DB_NAME
#   DB_USER
#   DB_PASSWORD
#   DB_ADMIN_USER
#   DB_ADMIN_PASSWORD
#   SKIP_DB_INIT
#   SQL_DSN
#   REDIS_CONN_STRING
#   PORT
#   TZ
#   ASSET_NAME
#
# ============================================================

set -Eeuo pipefail

APP_NAME="superai-api"
APP_USER="superai-api"
APP_GROUP="superai-api"
INSTALL_DIR="/opt/${APP_NAME}"
DATA_DIR="${INSTALL_DIR}/data"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
BINARY_PATH="${INSTALL_DIR}/${APP_NAME}"
ENV_FILE="${INSTALL_DIR}/.env"
VERSION_FILE="${INSTALL_DIR}/VERSION"
SYSTEMD_UNIT="/etc/systemd/system/${APP_NAME}.service"
GITHUB_OWNER="sgalcheung"
GITHUB_REPO="superai-api"
GITHUB_API="https://api.github.com"
GITHUB_API_VERSION="2026-03-10"
DEFAULT_PORT="3000"
DEFAULT_TZ="Asia/Shanghai"
DEFAULT_DB_PORT="5432"
DEFAULT_DB_NAME="superai"
DEFAULT_DB_USER="superai"
BACKUP_RETENTION="5"
PORT="${PORT:-${DEFAULT_PORT}}"
TZ="${TZ:-${DEFAULT_TZ}}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-${DEFAULT_DB_PORT}}"
DB_NAME="${DB_NAME:-${DEFAULT_DB_NAME}}"
DB_USER="${DB_USER:-${DEFAULT_DB_USER}}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
SKIP_DB_INIT="${SKIP_DB_INIT:-false}"
SQL_DSN="${SQL_DSN:-}"
SQL_DSN_EXPLICIT=false
if [[ -n "${SQL_DSN}" ]]; then SQL_DSN_EXPLICIT=true; fi
ASSET_NAME="${ASSET_NAME:-}"
TMP_DIR=""
RELEASE_FILE=""
DOWNLOAD_FILE=""
CURRENT_BACKUP=""

if [[ -t 1 ]]; then
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; BOLD="\033[1m"; RESET="\033[0m"
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

log() { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo; echo -e "${CYAN}${BOLD}==> $*${RESET}"; echo; }
die() { error "$*"; exit 1; }

cleanup() {
    local exit_code=$?
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then rm -rf "${TMP_DIR}"; fi
    unset GITHUB_TOKEN 2>/dev/null || true
    exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
on_error() { local exit_code=$?; error "Command failed at line ${BASH_LINENO[0]}"; error "Command: ${BASH_COMMAND}"; exit "${exit_code}"; }
trap on_error ERR

require_root() { [[ "${EUID}" -eq 0 ]] || die "Please run this script as root or with sudo."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

read_input() {
    local prompt="$1" variable="$2" value=""
    [[ -e /dev/tty ]] || die "Interactive input requires /dev/tty. Set ${variable} as an environment variable."
    read -r -p "${prompt}" value < /dev/tty
    printf -v "${variable}" '%s' "${value}"
}
read_secret() {
    local prompt="$1" variable="$2" value=""
    [[ -e /dev/tty ]] || die "Interactive secret input requires /dev/tty. Set ${variable} as an environment variable."
    read -r -s -p "${prompt}" value < /dev/tty
    echo
    printf -v "${variable}" '%s' "${value}"
}
confirm() {
    local prompt="$1" answer=""
    read -r -p "${prompt} [y/N]: " answer < /dev/tty
    case "${answer}" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

install_dependencies() {
    section "Checking dependencies"
    local packages=()
    command_exists curl || packages+=("curl")
    command_exists jq || packages+=("jq")
    if ! command_exists sha256sum && ! command_exists openssl; then packages+=("openssl"); fi
    command_exists psql || {
        if command_exists apt-get || command_exists apk; then
            packages+=("postgresql-client")
        elif command_exists dnf || command_exists yum; then
            packages+=("postgresql")
        else
            die "PostgreSQL client (psql) is required. Please install it manually."
        fi
    }
    if [[ "${#packages[@]}" -eq 0 ]]; then success "Required dependencies are installed."; return; fi
    log "Installing: ${packages[*]}"
    if command_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y "${packages[@]}"
    elif command_exists dnf; then dnf install -y "${packages[@]}"
    elif command_exists yum; then yum install -y "${packages[@]}"
    elif command_exists apk; then apk add --no-cache "${packages[@]}"
    else die "Unsupported package manager. Please install manually: ${packages[*]}"; fi
    success "Dependencies installed."
}

detect_arch() {
    local machine; machine="$(uname -m)"
    case "${machine}" in x86_64|amd64) BIN_ARCH="amd64";; aarch64|arm64) BIN_ARCH="arm64";; *) die "Unsupported architecture: ${machine}";; esac
    log "Architecture: ${machine} -> ${BIN_ARCH}"
}
validate_port() {
    [[ "${PORT}" =~ ^[0-9]+$ ]] || die "PORT must be a number: ${PORT}"
    (( PORT >= 1 && PORT <= 65535 )) || die "PORT must be between 1 and 65535."
}

ensure_github_token() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        return
    fi

    echo
    echo -e "${BOLD}GitHub authentication required${RESET}"
    echo
    echo "The latest superai-api release is private and requires a GitHub token."
    echo
    echo "Repository:"
    echo "  https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
    echo
    echo "Required Fine-grained PAT permission:"
    echo "  Contents: Read"
    echo
    echo "The token is used only for this installation and is not saved to disk."
    echo
    read_secret "GitHub Fine-grained PAT: " GITHUB_TOKEN
    [[ -n "${GITHUB_TOKEN}" ]] || die "GitHub token cannot be empty."
}
github_curl() {
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" "$@"
}
github_asset_curl() {
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
        -H "Accept: application/octet-stream" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" "$@"
}
verify_github_access() {
    section "Checking GitHub access"
    if ! github_curl "${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}" >/dev/null; then
        echo
        error "GitHub authentication failed or the token cannot access the private repository."
        echo
        echo "Please check:"
        echo "  - The token is valid and has not expired."
        echo "  - Repository access includes: ${GITHUB_OWNER}/${GITHUB_REPO}"
        echo "  - Repository permission: Contents: Read"
        echo
        die "Create a Fine-grained PAT with access limited to ${GITHUB_OWNER}/${GITHUB_REPO}."
    fi
    success "GitHub authentication successful."
}

prepare_tmp_dir() {
    [[ -n "${TMP_DIR}" ]] && return
    TMP_DIR="$(mktemp -d -t superai-api.XXXXXXXX)"
    chmod 700 "${TMP_DIR}"
    RELEASE_FILE="${TMP_DIR}/release.json"
    DOWNLOAD_FILE="${TMP_DIR}/download"
}
fetch_latest_release() {
    section "Fetching latest release"
    github_curl "${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest" -o "${RELEASE_FILE}"
    [[ -s "${RELEASE_FILE}" ]] || die "GitHub returned an empty release response."
    local release_id tag_name prerelease draft
    release_id="$(jq -r '.id // empty' "${RELEASE_FILE}")"
    tag_name="$(jq -r '.tag_name // empty' "${RELEASE_FILE}")"
    prerelease="$(jq -r '.prerelease // false' "${RELEASE_FILE}")"
    draft="$(jq -r '.draft // false' "${RELEASE_FILE}")"
    [[ -n "${release_id}" ]] || die "Invalid GitHub Release response."
    [[ -n "${tag_name}" ]] || die "Release tag_name is missing."
    [[ "${prerelease}" != "true" ]] || die "Latest release is marked as prerelease."
    [[ "${draft}" != "true" ]] || die "Latest release is marked as draft."
    RELEASE_VERSION="${tag_name}"
    log "Latest release: ${RELEASE_VERSION}"
}
asset_is_archive() { [[ "$1" =~ \.(zip|tar|tar\.gz|tgz|gz|bz2|xz|sha256|sha256sum|sig|asc)$ ]]; }
find_release_asset() {
    section "Selecting release asset"
    if [[ -n "${ASSET_NAME}" ]]; then
        if jq -e --arg name "${ASSET_NAME}" '.assets[] | select(.name == $name)' "${RELEASE_FILE}" >/dev/null; then
            SELECTED_ASSET_NAME="${ASSET_NAME}"; success "Using configured asset: ${SELECTED_ASSET_NAME}"; return
        fi
        die "Configured ASSET_NAME not found: ${ASSET_NAME}"
    fi
    local arch_pattern
    case "${BIN_ARCH}" in amd64) arch_pattern='(amd64|x86_64)' ;; arm64) arch_pattern='(arm64|aarch64)' ;; esac
    mapfile -t candidates < <(jq -r --arg pattern "${arch_pattern}" '.assets[] | select(.state == "uploaded") | .name | select(test("linux"; "i")) | select(test($pattern; "i"))' "${RELEASE_FILE}" | while IFS= read -r name; do if ! asset_is_archive "${name}"; then echo "${name}"; fi; done)
    if [[ "${#candidates[@]}" -eq 0 ]]; then
        echo; error "No Linux ${BIN_ARCH} binary found in the release."; echo; echo "Available assets:"; jq -r '.assets[].name' "${RELEASE_FILE}" | sed 's/^/  - /'; echo
        echo "You can specify it manually:"; echo; echo "  ASSET_NAME=\"your-file\" sudo bash install-superai-api.sh install"; echo; exit 1
    fi
    local preferred=""
    for candidate in "${candidates[@]}"; do case "${candidate}" in "${APP_NAME}-linux-${BIN_ARCH}") preferred="${candidate}"; break;; esac; done
    if [[ -z "${preferred}" ]]; then for candidate in "${candidates[@]}"; do case "${candidate}" in "${APP_NAME}"*"linux-${BIN_ARCH}") preferred="${candidate}"; break;; esac; done; fi
    if [[ -n "${preferred}" ]]; then SELECTED_ASSET_NAME="${preferred}"; success "Selected asset: ${SELECTED_ASSET_NAME}"; return; fi
    if [[ "${#candidates[@]}" -eq 1 ]]; then SELECTED_ASSET_NAME="${candidates[0]}"; success "Selected asset: ${SELECTED_ASSET_NAME}"; return; fi
    echo; error "Multiple matching Linux ${BIN_ARCH} assets were found."; echo; printf '  - %s\n' "${candidates[@]}"; echo; echo "Please specify ASSET_NAME explicitly."; echo; exit 1
}
get_asset_json() { jq -c --arg name "${SELECTED_ASSET_NAME}" '.assets[] | select(.name == $name)' "${RELEASE_FILE}"; }
calculate_sha256() {
    local file="$1"
    if command_exists sha256sum; then sha256sum "${file}" | awk '{print $1}'; return; fi
    if command_exists openssl; then openssl dgst -sha256 "${file}" | awk '{print $NF}'; return; fi
    die "Neither sha256sum nor openssl is available."
}
verify_digest() {
    local asset_json="$1" file="$2" digest expected actual
    digest="$(echo "${asset_json}" | jq -r '.digest // empty')"
    if [[ -z "${digest}" ]]; then warn "GitHub did not provide a SHA-256 digest for ${SELECTED_ASSET_NAME}."; return; fi
    if [[ "${digest}" != sha256:* ]]; then warn "Unsupported GitHub digest format: ${digest}"; return; fi
    expected="${digest#sha256:}"; actual="$(calculate_sha256 "${file}")"; log "Verifying SHA-256..."
    [[ "${expected}" == "${actual}" ]] || die "SHA-256 verification failed.\n\nAsset:\n  ${SELECTED_ASSET_NAME}\n\nExpected:\n  ${expected}\n\nActual:\n  ${actual}\n"
    success "SHA-256 verification passed."
}
download_asset() {
    section "Downloading release asset"
    local asset_json asset_id asset_size actual_size
    asset_json="$(get_asset_json)"; [[ -n "${asset_json}" ]] || die "Failed to resolve release asset."
    asset_id="$(echo "${asset_json}" | jq -r '.id // empty')"; asset_size="$(echo "${asset_json}" | jq -r '.size // empty')"
    [[ -n "${asset_id}" ]] || die "Release asset ID is missing."
    log "Asset: ${SELECTED_ASSET_NAME}"; log "Asset ID: ${asset_id}"
    [[ -n "${asset_size}" ]] && log "Expected size: ${asset_size} bytes"
    github_asset_curl "${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/assets/${asset_id}" -o "${DOWNLOAD_FILE}"
    [[ -s "${DOWNLOAD_FILE}" ]] || die "Downloaded asset is empty."
    actual_size="$(stat -c '%s' "${DOWNLOAD_FILE}" 2>/dev/null || stat -f '%z' "${DOWNLOAD_FILE}")"
    if [[ -n "${asset_size}" && "${asset_size}" != "null" && "${actual_size}" != "${asset_size}" ]]; then die "Downloaded file size mismatch.\n\nExpected:\n  ${asset_size}\n\nActual:\n  ${actual_size}\n"; fi
    verify_digest "${asset_json}" "${DOWNLOAD_FILE}"
    [[ -x "${DOWNLOAD_FILE}" ]] || chmod 0755 "${DOWNLOAD_FILE}"
    success "Download verified."
}

ensure_service_user() {
    section "Preparing service account"
    if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then groupadd --system "${APP_GROUP}"; fi
    if ! id "${APP_USER}" >/dev/null 2>&1; then useradd --system --gid "${APP_GROUP}" --home-dir "${INSTALL_DIR}" --shell /usr/sbin/nologin "${APP_USER}"; fi
    success "Service account ready: ${APP_USER}"
}
prepare_directories() {
    section "Preparing directories"
    mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
    chown -R "${APP_USER}:${APP_GROUP}" "${INSTALL_DIR}"
    chmod 0750 "${INSTALL_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
    success "Directories prepared."
}
generate_secret() { if command_exists openssl; then openssl rand -hex 32; return; fi; od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
urlencode() { jq -nr --arg value "$1" '$value|@uri'; }
env_get() { local key="$1"; [[ -f "${ENV_FILE}" ]] || return 0; awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, "", $0); print $0; exit}' "${ENV_FILE}"; }
env_has() { local key="$1"; grep -Eq "^${key}=" "${ENV_FILE}" 2>/dev/null; }
env_set_if_missing() { local key="$1" value="$2"; if ! env_has "${key}"; then printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"; fi; }

validate_db_host() {
    [[ -n "${DB_HOST}" ]] || die "DB_HOST cannot be empty."
    case "${DB_HOST}" in
        localhost|127.0.0.1|127.*|::1|0.0.0.0)
            die "DB_HOST must use the PostgreSQL internal network address, not ${DB_HOST}.";
            ;;
    esac
}

build_sql_dsn() {
    local encoded_user encoded_password encoded_db
    encoded_user="$(urlencode "${DB_USER}")"
    encoded_password="$(urlencode "${DB_PASSWORD}")"
    encoded_db="$(urlencode "${DB_NAME}")"
    SQL_DSN="postgresql://${encoded_user}:${encoded_password}@${DB_HOST}:${DB_PORT}/${encoded_db}?sslmode=disable"
}

configure_database() {
    if [[ -n "${SQL_DSN:-}" ]]; then
        log "Using SQL_DSN override."
        return
    fi

    echo
    echo -e "${BOLD}PostgreSQL internal network configuration${RESET}"
    echo
    echo "Use the private address or internal DNS name of the PostgreSQL server."
    echo "The installer does not use localhost/loopback for PostgreSQL."
    echo
    if [[ -z "${DB_HOST}" ]]; then
        read_input "PostgreSQL internal host: " DB_HOST
    fi
    validate_db_host

    read_input "PostgreSQL port [${DB_PORT}]: " input_db_port
    [[ -z "${input_db_port}" ]] || DB_PORT="${input_db_port}"

    read_input "PostgreSQL database [${DB_NAME}]: " input_db_name
    [[ -z "${input_db_name}" ]] || DB_NAME="${input_db_name}"

    read_input "PostgreSQL user [${DB_USER}]: " input_db_user
    [[ -z "${input_db_user}" ]] || DB_USER="${input_db_user}"

    if [[ -z "${DB_PASSWORD}" ]]; then
        read_secret "PostgreSQL password: " DB_PASSWORD
    fi
    [[ -n "${DB_PASSWORD}" ]] || die "DB_PASSWORD cannot be empty."

    build_sql_dsn
    log "PostgreSQL target: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
    log "PostgreSQL user: ${DB_USER}"
}


initialize_postgres_database() {
    section "Preparing PostgreSQL database"

    if [[ "${SKIP_DB_INIT}" == "true" ]]; then
        warn "SKIP_DB_INIT=true; PostgreSQL role/database initialization skipped."
        return
    fi

    if [[ "${SQL_DSN_EXPLICIT}" == "true" ]]; then
        log "SQL_DSN was provided explicitly; PostgreSQL role/database initialization skipped."
        return
    fi

    [[ -n "${DB_HOST}" ]] || die "DB_HOST cannot be empty."
    [[ -n "${DB_USER}" ]] || die "DB_USER cannot be empty."
    [[ -n "${DB_NAME}" ]] || die "DB_NAME cannot be empty."
    [[ -n "${DB_ADMIN_USER}" ]] || die "DB_ADMIN_USER cannot be empty."

    if [[ -z "${DB_PASSWORD}" ]]; then
        read_secret "PostgreSQL password (${DB_USER}): " DB_PASSWORD
    fi
    [[ -n "${DB_PASSWORD}" ]] || die "DB_PASSWORD cannot be empty."

    if [[ -z "${DB_ADMIN_PASSWORD}" ]]; then
        echo
        echo -e "${BOLD}PostgreSQL administrator credentials${RESET}"
        echo
        echo "These credentials are used only to create the dedicated"
        echo "application role/database. They are never written to ${ENV_FILE}."
        echo
        read_secret "PostgreSQL admin password (${DB_ADMIN_USER}): " DB_ADMIN_PASSWORD
    fi
    [[ -n "${DB_ADMIN_PASSWORD}" ]] || die "DB_ADMIN_PASSWORD cannot be empty."

    export SUPERAI_DB_PASSWORD="${DB_PASSWORD}"

    if ! PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -X -v ON_ERROR_STOP=1 \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_ADMIN_USER}" \
        -d "postgres" \
        -v superai_db_user="${DB_USER}" \
        -v superai_db_name="${DB_NAME}" <<'SQL'
\getenv superai_db_password SUPERAI_DB_PASSWORD

SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'superai_db_user',
    :'superai_db_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'superai_db_user'
) \gexec

SELECT format(
    'ALTER ROLE %I LOGIN PASSWORD %L',
    :'superai_db_user',
    :'superai_db_password'
) \gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'superai_db_name',
    :'superai_db_user'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'superai_db_name'
) \gexec

SELECT format(
    'ALTER DATABASE %I OWNER TO %I',
    :'superai_db_name',
    :'superai_db_user'
)
WHERE EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'superai_db_name'
      AND pg_get_userbyid(datdba) <> :'superai_db_user'
) \gexec
SQL
    then
        unset SUPERAI_DB_PASSWORD
        die "PostgreSQL role/database initialization failed."
    fi

    unset SUPERAI_DB_PASSWORD DB_ADMIN_PASSWORD

    if PGPASSWORD="${DB_PASSWORD}" psql -X -v ON_ERROR_STOP=1 \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        -c "SELECT 1;" >/dev/null 2>&1; then
        success "PostgreSQL role/database ready: ${DB_USER}/${DB_NAME}"
    else
        die "PostgreSQL initialization completed, but the application credentials could not connect to ${DB_HOST}:${DB_PORT}/${DB_NAME}."
    fi
}

create_env_file() {
    section "Configuring environment"
    umask 077
    if [[ ! -f "${ENV_FILE}" ]]; then
        configure_database
        if [[ -z "${REDIS_CONN_STRING:-}" ]]; then echo; echo "Redis is optional."; echo "Example:"; echo "  redis://127.0.0.1:6379"; echo; read_input "REDIS_CONN_STRING (press Enter to skip): " REDIS_CONN_STRING; fi
        local session_secret crypto_secret; session_secret="$(generate_secret)"; crypto_secret="$(generate_secret)"
        cat > "${ENV_FILE}" <<EOF
# ============================================================
# superai api
# generated by install-superai-api.sh
# ============================================================

# Database
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
SQL_DSN=${SQL_DSN}

# Redis
REDIS_CONN_STRING=${REDIS_CONN_STRING:-}

# Server
PORT=${PORT}
TZ=${TZ}

# Security
SESSION_SECRET=${session_secret}
CRYPTO_SECRET=${crypto_secret}

# Logging
ERROR_LOG_ENABLED=true

# Batch update
BATCH_UPDATE_ENABLED=true
EOF
    else
        if ! env_has "SQL_DSN"; then
            configure_database
            env_set_if_missing "DB_HOST" "${DB_HOST}"
            env_set_if_missing "DB_PORT" "${DB_PORT}"
            env_set_if_missing "DB_NAME" "${DB_NAME}"
            env_set_if_missing "DB_USER" "${DB_USER}"
            env_set_if_missing "SQL_DSN" "${SQL_DSN}"
        else
            SQL_DSN="$(env_get "SQL_DSN")"
            DB_HOST="$(env_get "DB_HOST")"
            DB_PORT="$(env_get "DB_PORT")"
            DB_NAME="$(env_get "DB_NAME")"
            DB_USER="$(env_get "DB_USER")"
        fi
        if ! env_has "SESSION_SECRET"; then env_set_if_missing "SESSION_SECRET" "$(generate_secret)"; fi
        if ! env_has "CRYPTO_SECRET"; then env_set_if_missing "CRYPTO_SECRET" "$(generate_secret)"; fi
        env_set_if_missing "PORT" "${PORT}"; env_set_if_missing "TZ" "${TZ}"; log "Existing .env preserved."
    fi
    chown "${APP_USER}:${APP_GROUP}" "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"; success "Environment file ready."
}
extract_db_host() {
    local dsn="$1"
    if [[ "${dsn}" =~ ^postgres(ql)?://([^@]+@)?([^/:]+|\[[^]]+\])(:[0-9]+)?/ ]]; then echo "${BASH_REMATCH[3]}" | sed 's/^\[//;s/\]$//'; return; fi
    if [[ "${dsn}" =~ (^|[[:space:]])host=([^[:space:]]+) ]]; then echo "${BASH_REMATCH[2]}"; return; fi
    echo ""
}
extract_db_port() {
    local dsn="$1"
    if [[ "${dsn}" =~ ^postgres(ql)?://([^@]+@)?([^/:]+|\[[^]]+\])(:([0-9]+))?/ ]]; then if [[ -n "${BASH_REMATCH[5]:-}" ]]; then echo "${BASH_REMATCH[5]}"; return; fi; fi
    if [[ "${dsn}" =~ (^|[[:space:]])port=([0-9]+) ]]; then echo "${BASH_REMATCH[2]}"; return; fi
    echo "5432"
}
check_postgres() {
    section "Checking PostgreSQL"
    local dsn; dsn="$(env_get "SQL_DSN")"
    [[ -n "${dsn}" ]] || { warn "SQL_DSN is not configured."; return; }
    local db_host db_port; db_host="$(extract_db_host "${dsn}")"; db_port="$(extract_db_port "${dsn}")"
    [[ -n "${db_host}" ]] || { warn "Unable to determine PostgreSQL host."; return; }
    log "PostgreSQL: ${db_host}:${db_port}"
    if timeout 5 bash -c "</dev/tcp/${db_host}/${db_port}" >/dev/null 2>&1; then success "PostgreSQL TCP connection available."; else warn "Cannot reach PostgreSQL at ${db_host}:${db_port}"; warn "The application may fail until PostgreSQL becomes available."; fi
}
backup_current_binary() {
    [[ -f "${BINARY_PATH}" ]] || { CURRENT_BACKUP=""; return; }
    local timestamp; timestamp="$(date '+%Y%m%d-%H%M%S')"; CURRENT_BACKUP="${BACKUP_DIR}/${APP_NAME}-${timestamp}"
    cp --preserve=mode,ownership,timestamps "${BINARY_PATH}" "${CURRENT_BACKUP}"; chown "${APP_USER}:${APP_GROUP}" "${CURRENT_BACKUP}"; chmod 0755 "${CURRENT_BACKUP}"
    log "Previous binary backed up:"; log "  ${CURRENT_BACKUP}"
}
cleanup_old_backups() {
    mapfile -t backups < <(find "${BACKUP_DIR}" -maxdepth 1 -type f -name "${APP_NAME}-*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR > '"${BACKUP_RETENTION}"' {print $2}')
    if [[ "${#backups[@]}" -gt 0 ]]; then
        rm -f -- "${backups[@]}"
    fi
}
install_downloaded_binary() {
    section "Installing binary"
    local temp_binary="${INSTALL_DIR}/.${APP_NAME}.new"
    install -o "${APP_USER}" -g "${APP_GROUP}" -m 0755 "${DOWNLOAD_FILE}" "${temp_binary}"
    mv -f "${temp_binary}" "${BINARY_PATH}"
    chown "${APP_USER}:${APP_GROUP}" "${BINARY_PATH}"; chmod 0755 "${BINARY_PATH}"
    printf '%s\n' "${RELEASE_VERSION}" > "${VERSION_FILE}"; chown "${APP_USER}:${APP_GROUP}" "${VERSION_FILE}"; chmod 0644 "${VERSION_FILE}"
    cleanup_old_backups; success "Binary installed: ${RELEASE_VERSION}"
}
rollback_binary() {
    [[ -n "${CURRENT_BACKUP}" && -f "${CURRENT_BACKUP}" ]] || { warn "No previous binary is available for rollback."; return 1; }
    section "Rolling back binary"
    install -o "${APP_USER}" -g "${APP_GROUP}" -m 0755 "${CURRENT_BACKUP}" "${BINARY_PATH}"; success "Previous binary restored."; return 0
}
create_systemd_service() {
    section "Configuring systemd"
    cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=superai api
Documentation=https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${BINARY_PATH}
Restart=on-failure
RestartSec=5
TimeoutStartSec=60
TimeoutStopSec=30
LimitNOFILE=65535
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectHostname=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0077
ReadWritePaths=${INSTALL_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable "${APP_NAME}.service"; success "systemd service configured."
}
start_service() { systemctl restart "${APP_NAME}.service"; }
service_active() { systemctl is-active --quiet "${APP_NAME}.service"; }
wait_for_service() {
    section "Waiting for service"
    local max_attempts=30 attempt=1
    while (( attempt <= max_attempts )); do if service_active; then success "systemd service is active."; return 0; fi; sleep 1; ((attempt++)); done
    error "Service failed to become active."; systemctl --no-pager --full status "${APP_NAME}.service" || true; echo; echo "Recent logs:"; journalctl -u "${APP_NAME}.service" -n 80 --no-pager || true; return 1
}
wait_for_port() {
    section "Checking application port"
    local port; port="$(env_get "PORT")"; [[ -n "${port}" ]] || port="${PORT}"
    [[ "${port}" =~ ^[0-9]+$ ]] || { warn "Invalid PORT value: ${port}"; return 0; }
    local max_attempts=30 attempt=1
    while (( attempt <= max_attempts )); do if timeout 1 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; then success "Application is listening on 127.0.0.1:${port}"; return 0; fi; sleep 1; ((attempt++)); done
    warn "Application port ${port} is not reachable."; warn "The process may still be starting or may use a different bind address."; return 1
}
restart_and_verify() { systemctl daemon-reload; start_service; wait_for_service || return 1; wait_for_port || true; return 0; }

install_command() {
    section "Installing superai api"
    [[ ! -e "${INSTALL_DIR}" || ! -f "${BINARY_PATH}" ]] || die "superai api is already installed. Use 'upgrade' instead."
    validate_port; detect_arch; ensure_github_token; verify_github_access; prepare_tmp_dir; fetch_latest_release; find_release_asset; download_asset
    ensure_service_user; prepare_directories; create_env_file; initialize_postgres_database; check_postgres; install_downloaded_binary; create_systemd_service
    restart_and_verify || die "Installation completed, but the service failed to start."
    section "Installation completed"
    echo; echo -e "${GREEN}${BOLD}superai api installed successfully.${RESET}"; echo; echo "Version:"; echo "  ${RELEASE_VERSION}"; echo; echo "Binary:"; echo "  ${BINARY_PATH}"; echo; echo "Config:"; echo "  ${ENV_FILE}"; echo; echo "Service:"; echo "  ${APP_NAME}.service"; echo; echo "Port:"; echo "  ${PORT}"; echo; echo "Useful commands:"; echo "  systemctl status ${APP_NAME}"; echo "  systemctl restart ${APP_NAME}"; echo "  journalctl -u ${APP_NAME} -f"; echo
}
upgrade_command() {
    section "Upgrading superai api"
    [[ -f "${BINARY_PATH}" && -f "${VERSION_FILE}" ]] || die "superai api is not installed."
    validate_port; detect_arch; ensure_github_token; verify_github_access; prepare_tmp_dir; fetch_latest_release
    local current_version; current_version="$(cat "${VERSION_FILE}")"; echo; echo "Current version:"; echo "  ${current_version}"; echo; echo "Latest version:"; echo "  ${RELEASE_VERSION}"; echo
    if [[ "${current_version}" == "${RELEASE_VERSION}" ]]; then success "Already running the latest version."; return 0; fi
    find_release_asset; download_asset; ensure_service_user; prepare_directories; create_env_file; backup_current_binary; install_downloaded_binary
    if restart_and_verify; then section "Upgrade completed"; success "${current_version} -> ${RELEASE_VERSION}"; return 0; fi
    warn "New version failed to start. Attempting automatic rollback."
    if rollback_binary && restart_and_verify; then section "Rollback completed"; warn "Upgrade was rolled back."; echo; echo "Running version:"; cat "${VERSION_FILE}"; echo; exit 1; fi
    die "Upgrade failed and automatic rollback was unsuccessful."
}
status_command() {
    echo; echo -e "${BOLD}superai api${RESET}"; echo
    if [[ -f "${VERSION_FILE}" ]]; then echo "Version:  $(cat "${VERSION_FILE}")"; else echo "Version:  unknown"; fi
    echo "Binary:   ${BINARY_PATH}"; echo "Config:   ${ENV_FILE}"; echo "Service:  ${APP_NAME}.service"
    if [[ -f "${ENV_FILE}" ]]; then local configured_port; configured_port="$(env_get "PORT")"; [[ -n "${configured_port}" ]] && echo "Port:     ${configured_port}"; fi
    echo; systemctl --no-pager --full status "${APP_NAME}.service" || true
}
restart_command() { section "Restarting ${APP_NAME}"; [[ -f "${BINARY_PATH}" ]] || die "superai api is not installed."; restart_and_verify; }
uninstall_command() {
    section "Uninstalling ${APP_NAME}"
    if [[ ! -e "${INSTALL_DIR}" && ! -e "${SYSTEMD_UNIT}" ]]; then success "superai api is not installed."; return; fi
    echo; echo "This will remove:"; echo; echo "  ${INSTALL_DIR}"; echo "  ${SYSTEMD_UNIT}"; echo; echo "The PostgreSQL database will NOT be deleted."; echo "The Redis database will NOT be deleted."; echo
    if ! confirm "Continue?"; then echo "Cancelled."; return 0; fi
    systemctl stop "${APP_NAME}.service" 2>/dev/null || true; systemctl disable "${APP_NAME}.service" 2>/dev/null || true; rm -f "${SYSTEMD_UNIT}"; systemctl daemon-reload; rm -rf "${INSTALL_DIR}"
    if id "${APP_USER}" >/dev/null 2>&1; then userdel "${APP_USER}" 2>/dev/null || true; fi
    if getent group "${APP_GROUP}" >/dev/null 2>&1; then groupdel "${APP_GROUP}" 2>/dev/null || true; fi
    success "superai api has been uninstalled."; echo; echo "PostgreSQL and Redis were not modified."
}
usage() {
    cat <<EOF

superai api installer

Usage:
  sudo bash install-superai-api.sh <command>

Commands:
  install       Install the latest stable release
  upgrade       Upgrade to the latest stable release
  status        Show service status
  restart       Restart the service
  uninstall     Remove superai api
  help          Show this help

Examples:
  sudo bash install-superai-api.sh
  sudo bash install-superai-api.sh install
  sudo bash install-superai-api.sh upgrade
  sudo bash install-superai-api.sh status
  sudo bash install-superai-api.sh restart
  sudo bash install-superai-api.sh uninstall

Environment variables:
  GITHUB_TOKEN
      GitHub Fine-grained PAT.
      Required permission:
        Contents: Read
  DB_HOST
      PostgreSQL private/internal network hostname or IP address.
      localhost/127.0.0.1 is not accepted.
  DB_PORT
      Default:
        ${DEFAULT_DB_PORT}
  DB_NAME
      Default:
        ${DEFAULT_DB_NAME}
  DB_USER
      Default:
        ${DEFAULT_DB_USER}
  DB_PASSWORD
      PostgreSQL password for DB_USER.
  DB_ADMIN_USER
      PostgreSQL administrator used to create the dedicated role/database.
      Default:
        postgres
  DB_ADMIN_PASSWORD
      Administrator password. Used only during installation and never saved.
  SKIP_DB_INIT
      Set to true to skip automatic role/database initialization.
      Default:
        false
  SQL_DSN
      Optional full PostgreSQL connection string override.
      When set, DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD are not prompted.
  REDIS_CONN_STRING
      Optional Redis connection string.
  PORT
      Default:
        ${DEFAULT_PORT}
  TZ
      Default:
        ${DEFAULT_TZ}
  ASSET_NAME
      Optional exact Release asset name.

Example:
  DB_HOST="10.0.0.20" \
  DB_NAME="superai" \
  DB_USER="superai" \
  DB_PASSWORD="YOUR_DB_PASSWORD" \
  DB_ADMIN_USER="postgres" \
  DB_ADMIN_PASSWORD="YOUR_POSTGRES_ADMIN_PASSWORD" \
  sudo -E bash install-superai-api.sh install

EOF
}
main() {
    require_root; install_dependencies
    local command="${1:-install}"
    case "${command}" in install) install_command;; upgrade) upgrade_command;; status) status_command;; restart) restart_command;; uninstall) uninstall_command;; help|-h|--help) usage;; *) error "Unknown command: ${command}"; usage; exit 1;; esac
}
main "$@"
