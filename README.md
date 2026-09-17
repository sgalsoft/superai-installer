# superai api installer

Public installer for the private `sgalcheung/superai-api` project.

## what it does

`install-superai-api.sh` installs and manages the superai api binary published as a GitHub release asset in the private application repository.

The installer supports:

- Linux `amd64` and `arm64`
- Latest stable GitHub release discovery
- Private GitHub release asset download using a Fine-grained PAT
- SHA-256 verification when GitHub provides an asset digest
- PostgreSQL configuration
- Optional Redis configuration
- systemd service installation and restart
- Upgrade with automatic binary backup and rollback
- Status, restart, and uninstall commands

## requirements

- Linux with systemd
- `root` privileges
- Network access to GitHub
- A GitHub Fine-grained Personal Access Token with **Contents: Read** access to `sgalcheung/superai-api`
- PostgreSQL reachable using the configured `SQL_DSN`
- Redis is optional

## install

The default installation mode is interactive. Run:

```bash
curl -fsSL https://raw.githubusercontent.com/sgalsoft/superai-installer/main/install-superai-api.sh | sudo bash
```

The installer will securely prompt for the GitHub Fine-grained PAT and PostgreSQL connection string when they are not provided through environment variables. The GitHub token is read without echoing and is not written to the application `.env`, systemd unit, installation directory, or repository.

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

For automated server provisioning, `GITHUB_TOKEN` can be supplied through the environment:

```bash
GITHUB_TOKEN="YOUR_FINE_GRAINED_PAT" \
SQL_DSN="postgres://user:password@127.0.0.1:5432/newapi" \
REDIS_CONN_STRING="redis://127.0.0.1:6379" \
PORT="3000" \
TZ="Asia/Shanghai" \
sudo -E bash install-superai-api.sh install
```

The environment variable is optional; **interactive input remains the default**.

For security, never commit the token to this repository.

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
- Use a Fine-grained PAT scoped only to `sgalcheung/superai-api` with **Contents: Read**.
- The installer does not store the GitHub token in `/opt/superai-api/.env`.
- The application `.env` is created with mode `0600`.
- The systemd service runs without root privileges and uses service hardening options.
- PostgreSQL and Redis data are not deleted by `uninstall`.

## token architecture

```text
release side:
sgalcheung/superai-api
        │
        │ GitHub Actions
        │ GITHUB_TOKEN
        │ contents: write
        ▼
GitHub release
        │
        ├── superai-api-linux-amd64
        └── superai-api-linux-arm64

installer side:
sgalsoft/superai-installer
        │
        │ Fine-grained PAT
        │ contents: read
        ▼
private GitHub release
        │
        ▼
/opt/superai-api
```

The Actions `GITHUB_TOKEN` and the installer Fine-grained PAT are separate credentials with separate responsibilities. The installer PAT is never embedded in the public repository or GitHub Actions workflow.

## license

See [LICENSE](LICENSE).
