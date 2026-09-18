# superai api installer

Public installer for the private `sgalcheung/superai-api` project.

## what it does

`install-superai-api.sh` installs and manages the superai api binary published as a GitHub release asset in the private application repository.

The installer supports:

- Linux `amd64` and `arm64`
- Latest stable GitHub release discovery
- Private GitHub release asset download using a Fine-grained PAT
- SHA-256 verification when GitHub provides an asset digest
- PostgreSQL over the internal network
- Dedicated PostgreSQL role and database defaults
- Optional Redis configuration
- systemd service installation and restart
- Upgrade with automatic binary backup and rollback
- Status, restart, and uninstall commands

## postgres

The installer now uses a dedicated PostgreSQL role and database:

```text
database: superai
user:     superai
port:     5432
network:  internal/private network
```

The PostgreSQL host must be a private/internal hostname or IP address. The installer rejects:

```text
localhost
127.0.0.1
127.x.x.x
::1
0.0.0.0
```

For example:

```text
10.0.0.20:5432
```

or:

```text
postgres.internal:5432
```

The application still receives the final PostgreSQL connection through `SQL_DSN`, but the installer can build it from the individual internal database settings.

### create the postgres role and database

Run `create-superai-database.sh` on the PostgreSQL server, or from a host that can reach PostgreSQL over the internal network.

```bash
chmod +x create-superai-database.sh
./create-superai-database.sh
```

Defaults:

```text
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=postgres
PGDATABASE=postgres

DB_USER=superai
DB_NAME=superai
```

The script prompts for the password of the `superai` database user and does not write it to disk.

For a remote PostgreSQL server on the private network:

```bash
PGHOST="10.0.0.20" \
PGPORT="5432" \
PGUSER="postgres" \
./create-superai-database.sh
```

The PostgreSQL admin connection must already be authorized to create roles and databases.

## requirements

- Linux with systemd
- `root` privileges
- Network access to GitHub
- A GitHub Fine-grained Personal Access Token with **Contents: Read** access to `sgalcheung/superai-api`
- PostgreSQL reachable through the configured internal/private network address
- The `superai` PostgreSQL role and database must exist before the application starts, unless you create them with `create-superai-database.sh`
- Redis is optional

## install

The default installation mode is interactive. Run:

```bash
curl -fsSL https://raw.githubusercontent.com/sgalsoft/superai-installer/main/install-superai-api.sh | sudo bash
```

The installer securely prompts for the GitHub Fine-grained PAT and PostgreSQL internal connection settings when they are not provided through environment variables. The GitHub token is read without echoing and is not written to the application `.env`, systemd unit, installation directory, or repository.

During interactive installation, PostgreSQL defaults are:

```text
host:     PostgreSQL internal host
port:     5432
database: superai
user:     superai
```

You can also run a local copy:

```bash
sudo bash install-superai-api.sh
```

Equivalent explicit command:

```bash
sudo bash install-superai-api.sh install
```

## github token

The installer uses a **separate Fine-grained PAT** for downloading private release assets. GitHub Actions does not provide its `GITHUB_TOKEN` to the installer.

Create a Fine-grained PAT with:

```text
Repository access:
  Only select repositories
  sgalcheung/superai-api

Repository permissions:
  Contents: Read-only
```

For the normal interactive installation, do not put the token on the command line. The installer prompts for it through `/dev/tty` so it works with the `curl | sudo bash` installation method.

### optional non-interactive mode

For automated server provisioning, use the PostgreSQL internal address and the dedicated database credentials:

```bash
GITHUB_TOKEN="YOUR_FINE_GRAINED_PAT" \
DB_HOST="10.0.0.20" \
DB_PORT="5432" \
DB_NAME="superai" \
DB_USER="superai" \
DB_PASSWORD="YOUR_DB_PASSWORD" \
REDIS_CONN_STRING="redis://127.0.0.1:6379" \
PORT="3000" \
TZ="Asia/Shanghai" \
sudo -E bash install-superai-api.sh install
```

The installer builds:

```text
postgresql://superai:<password>@10.0.0.20:5432/superai?sslmode=disable
```

Passwords are URL-encoded before the DSN is written to `/opt/superai-api/.env`.

For compatibility, a full `SQL_DSN` can still be supplied directly. When `SQL_DSN` is set, the installer uses it as an override.

```bash
GITHUB_TOKEN="YOUR_FINE_GRAINED_PAT" \
SQL_DSN="postgresql://superai:YOUR_DB_PASSWORD@10.0.0.20:5432/superai?sslmode=disable" \
sudo -E bash install-superai-api.sh install
```

The environment variable is optional; **interactive input remains the default**.

For security, never commit the GitHub token or database password to this repository.

## commands

```text
sudo bash install-superai-api.sh install
sudo bash install-superai-api.sh upgrade
sudo bash install-superai-api.sh status
sudo bash install-superai-api.sh restart
sudo bash install-superai-api.sh uninstall
sudo bash install-superai-api.sh help
```

Running the script without a command is equivalent to `install`.

## release asset names

The installer automatically detects Linux assets for the current architecture. The canonical names are:

```text
superai-api-linux-amd64
superai-api-linux-arm64
```

If the release uses another exact asset name, set `ASSET_NAME` explicitly:

```bash
ASSET_NAME="your-release-asset" sudo bash install-superai-api.sh install
```

## installation paths

```text
/opt/superai-api/
├── superai-api
├── .env
├── VERSION
├── data/
├── logs/
└── backups/
```

The systemd unit is:

```text
/etc/systemd/system/superai-api.service
```

The service runs as the dedicated `superai-api` system user.

## security notes

- Keep the GitHub token private.
- Keep the PostgreSQL password private.
- Use a Fine-grained PAT scoped only to `sgalcheung/superai-api` with **Contents: Read**.
- Keep PostgreSQL on the private/internal network and restrict port `5432` with your firewall or security group.
- The installer does not store the GitHub token in `/opt/superai-api/.env`.
- The application `.env` is created with mode `0600`.
- The systemd service runs without root privileges and uses service hardening options.
- PostgreSQL and Redis data are not deleted by `uninstall`.

## token architecture

```text
release side:
sgalcheung/superai-api
        │
        │ github actions
        │ github token
        │ contents: write
        ▼
github release
        │
        ├── superai-api-linux-amd64
        └── superai-api-linux-arm64

installer side:
sgalsoft/superai-installer
        │
        │ fine-grained pat
        │ contents: read
        ▼
private github release
        │
        ▼
/opt/superai-api
```

The actions `GITHUB_TOKEN` and the installer Fine-grained PAT are separate credentials with separate responsibilities. The installer PAT is never embedded in the public repository or GitHub Actions workflow.

## license

See [LICENSE](LICENSE).
