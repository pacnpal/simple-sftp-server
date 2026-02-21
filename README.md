# Simple SFTP Server for Docker

A dead simple, minimal Alpine-based SFTP server in Docker. SFTP only — no shell, no tunneling, no forwarding.

## Features

- Minimal Alpine 3.20 image with OpenSSH
- SFTP-only access (no shell, no SCP, no port forwarding)
- Chrooted to user home directory
- Auto-generates SSH keypair on first run
- Keys persist across container restarts
- Configurable via environment variables

## Quick Start

```bash
docker compose up -d
```

On first run, keys are generated automatically. Retrieve the private key:

```bash
docker cp <container>:/home/sftpuser/.ssh/sftpuser_key ./sftp_key
chmod 600 ./sftp_key
sftp -i sftp_key -P 2222 sftpuser@localhost
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_KEY_DIR` | `/home/sftpuser/.ssh` | Path to `.ssh` directory inside the container |
| `SFTP_PATHS` | `/data` | Comma-separated directories to serve over SFTP |
| `SFTP_PORT` | `22` | SSH listen port inside the container |
| `SFTP_HOST_PORT` | `2222` | Host port mapped to the container |

## Using Your Own Keys

Mount your `authorized_keys` file into the `.ssh` volume path and the server will use it instead of generating a new keypair:

```bash
docker run -d \
  -p 2222:22 \
  -v /path/to/authorized_keys:/home/sftpuser/.ssh/authorized_keys:ro \
  pacnpal/simple-sftp-server
```

## Docker Hub / GitHub Packages

```bash
# Docker Hub
docker pull pacnpal/simple-sftp-server

# GitHub Packages
docker pull ghcr.io/pacnpal/simple-sftp-server
```

## Build

```bash
docker build -t simple-sftp-server .
```

## Security

The server is hardened with the following sshd settings:

- `ForceCommand internal-sftp` — SFTP only, no shell access
- `ChrootDirectory %h` — user is jailed to their home directory
- `AllowTcpForwarding no`
- `AllowAgentForwarding no`
- `X11Forwarding no`
- `PermitTunnel no`

## License

MIT — see [LICENSE](LICENSE).
