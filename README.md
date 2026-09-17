# SuperAI API Installer

Public installer for the private `Sgalcheung/superai-api` project.

## What it does

`install-superai-api.sh` installs and manages the SuperAI API binary published as a GitHub Release asset in the private application repository.

The installer supports:

- Linux `amd64` and `arm64`
- Latest stable GitHub Release discovery
- Private GitHub Release asset download using a Fine-grained PAT
- SHA-256 verification when GitHub provides an asset digest
- PostgreSQL configuration
- Optional Redis configuration
- systemd service installation and restart
- Upgrade with automatic binary backup and rollback
- Status, restart, and uninstall commands

## Requirements

- Linux with systemd
- `root` privileges
- Network access to GitHub
- A GitHub Fine-grained Personal Access Token with **Contents: Read** access to `Sgalcheung/superai-api`
- PostgreSQL reachable using the configured `SQL_DSN`
- Redis is optional

## Install

After downloading this repository:

```bash
sudo bash install-superai-api.sh
```

Equivalent explicit command:

```bash
sudo bash install-superai-api.sh install
```

The installer prompts for the GitHub token and PostgreSQL connection string when they are not supplied through environment variables.

## Non-interactive configuration

```bash
GITHUB_TOKEN="YOUR_FINE_GRAINED_PAT" \
SQL_DSN="postgres://user:password@127.0.0.1:5432/newapi" \
REDIS_CONN_STRING="redis://127.0.0.1:6379" \
PORT="3000" \
TZ="Asia/Shanghai" \
sudo -E bash install-superai-api.sh install
```

For security, do not commit the token to this repository or place it in the installer source code.

## Commands

```text
sudo bash install-superai-api.sh install
sudo bash install-superai-api.sh upgrade
sudo bash install-superai-api.sh status
sudo bash install-superai-api.sh restart
sudo bash install-superai-api.sh uninstall
sudo bash install-superai-api.sh help
```

Running the script without a command is equivalent to `install`.

## Release asset names

The installer automatically detects Linux assets for the current architecture. The canonical names are:

```text
superai-api-linux-amd64
superai-api-linux-arm64
```

If the release uses another exact asset name, set `ASSET_NAME` explicitly:

```bash
ASSET_NAME="your-release-asset" sudo bash install-superai-api.sh install
```

## Installation paths

The installer uses:

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

## Security notes

- Keep the GitHub token private.
- Use a Fine-grained PAT scoped only to the private application repository with the minimum required permission: **Contents: Read**.
- The installer does not store the GitHub token in `/opt/superai-api/.env`.
- The application `.env` is created with mode `0600`.
- The systemd service uses several hardening options and runs without root privileges.
- PostgreSQL and Redis data are not deleted by `uninstall`.

## Architecture

```text
sgalsoft/superai-installer  (public)
            │
            │ GitHub Fine-grained PAT
            ▼
sgalcheung/superai-api      (private)
            │
            ├── Releases
            │    ├── superai-api-linux-amd64
            │    └── superai-api-linux-arm64
            │
            └── Source code
```

## License

See [LICENSE](LICENSE).
