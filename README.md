# Simple SFTP Server

[![GitHub](https://img.shields.io/badge/GitHub-Source-blue?logo=github)](https://github.com/pacnpal/simple-sftp-server)
[![GHCR](https://img.shields.io/badge/GHCR-Package-blue?logo=github)](https://ghcr.io/pacnpal/simple-sftp-server)
[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-Image-blue?logo=docker)](https://hub.docker.com/r/pacnpal/simple-sftp-server)

A dead simple SFTP server in Docker. Nothing else. No shell, no tunneling, no forwarding. Just SFTP.

---

## Get the Image

These are pre-built and hosted. Pick one — they're the same image:

```
pacnpal/simple-sftp-server
```

```
ghcr.io/pacnpal/simple-sftp-server
```

---

## Quick Start

Create host directories first (recommended):

```bash
mkdir -p /home/user/.ssh_keys/simple-sftp /home/user/.ssh_keys/simple-sftp-host /home/user/sftp_data
chmod 700 /home/user/.ssh_keys /home/user/.ssh_keys/simple-sftp /home/user/.ssh_keys/simple-sftp-host
```

```bash
docker run -d --name simple-sftp-server \
  -p 2222:22 \
  -e SSH_KEY_DIR=/keys \
  -v /home/user/.ssh_keys/simple-sftp:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/home/sftpuser/.host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

This image intentionally stores generated client keys on the host for convenience. You are responsible for securing `/home/user/.ssh_keys/simple-sftp`.
Use non-overlapping host directories for `/keys`, `/home/sftpuser/.host_keys`, and `/home/sftpuser/data`.

### Get Your Login Key

On first start, a keypair is generated. The private key is already on your host:

```bash
cp /home/user/.ssh_keys/simple-sftp/sftpuser_key ./sftp_key && chmod 600 ./sftp_key
```

> **Windows users**: The `chmod` command doesn't exist on Windows. Instead, right-click the file > Properties > Security > make sure only your user has access.

### Connect

```bash
sftp -i sftp_key -P 2222 sftpuser@localhost
```

You should see:

```
Connected to sftpuser@localhost.
sftp>
```

You're in. Type `ls` to look around, `put myfile.txt` to upload, `get myfile.txt` to download, or `quit` to disconnect.

### Stop / Start / Remove

```bash
# Stop the server
docker stop simple-sftp-server

# Start it back up (your files and keys are still there)
docker start simple-sftp-server

# Remove it completely
docker rm -f simple-sftp-server
```

Your files and keys are stored on the host filesystem, so they persist across `stop`, `start`, and even `docker rm` + recreate. They only go away if you explicitly delete the directories:

```bash
# WARNING: This deletes all generated keys, host keys, and uploaded files
rm -rf /home/user/.ssh_keys/simple-sftp /home/user/.ssh_keys/simple-sftp-host /home/user/sftp_data
```

---

## Using Docker Compose (Alternative)

If you prefer Docker Compose, create a file called `docker-compose.yml`:

```yaml
services:
  sftp:
    image: pacnpal/simple-sftp-server:latest
    ports:
      - "2222:22"
    environment:
      - SSH_KEY_DIR=/keys
    volumes:
      - /home/user/.ssh_keys/simple-sftp:/keys
      - /home/user/.ssh_keys/simple-sftp-host:/home/sftpuser/.host_keys
      - /home/user/sftp_data:/home/sftpuser/data
```

Then run:

```bash
docker compose up -d
```

Everything else is the same — get the key and connect as described above.

---

## Bring Your Own Keys

If you already have SSH keys and an `authorized_keys` file, you can skip the auto-generated key.
Put `authorized_keys` inside a host directory, then mount that directory as `SSH_KEY_DIR`.

```bash
docker run -d --name simple-sftp-server \
  -p 2222:22 \
  -e SSH_KEY_DIR=/keys \
  -v /path/to/your/keydir:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/home/sftpuser/.host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

Replace `/path/to/your/keydir` with the directory containing `authorized_keys`.

---

## Key Handling (No Silent Rotation)

- `authorized_keys` is copied at startup to `/etc/ssh/sftpuser_keys/authorized_keys` with strict container-side permissions.
- New keys are generated only on true first run (no existing key files).
- If persisted key state is unreadable, empty, or inconsistent, startup fails with a clear error instead of rotating keys.
- Host keys are persisted in `HOST_KEY_DIR` (`/home/sftpuser/.host_keys` by default). Missing host key types are auto-generated on startup and synced back.

---

## SSHD Configuration

- The image ships a managed `sshd_config` at build time (see `sshd_config` in this repo).
- Startup does not patch `sshd_config` with `sed`; it starts sshd with:
  `sshd -D -e -f /etc/ssh/sshd_config -p "$SFTP_PORT"`
- `AuthorizedKeysFile` is pinned to `/etc/ssh/sftpuser_keys/authorized_keys` to avoid host mount permission edge cases.
- Runtime port changes are handled with the `-p` process argument, not by mutating config files.

---

## Troubleshooting

### Permission denied with matching key fingerprint

If this fails even with the right private key:

```bash
sftp -o IdentitiesOnly=yes -o IdentityAgent=none -i sftp_key -P 2222 sftpuser@localhost
```

Verify the runtime sshd view:

```bash
docker exec <container_name> sh -lc 'sshd -T -C user=sftpuser,host=localhost,addr=127.0.0.1 | grep authorizedkeysfile'
docker exec <container_name> sh -lc 'ssh-keygen -lf /etc/ssh/sftpuser_keys/authorized_keys'
ssh-keygen -y -f sftp_key | ssh-keygen -lf -
```

The `authorizedkeysfile` path should be `/etc/ssh/sftpuser_keys/authorized_keys`, and the two fingerprints should match.

### Host key keeps changing

If clients warn about host key changes, your host-key mount is not persisting stable key files.

```bash
docker inspect <container_name> --format '{{range .Mounts}}{{.Destination}} <- {{.Source}}{{println}}{{end}}'
ls -l /home/user/.ssh_keys/simple-sftp-host/ssh_host_*
```

Keep `/home/sftpuser/.host_keys` mounted to a stable host directory and avoid overlapping it under an SFTP-exposed parent mount.

---

## Environment Variables

You can customize behavior with these:

| Variable | Default | What it does |
|---|---|---|
| `SFTP_PORT` | `22` | Port the SFTP server listens on inside the container |
| `SFTP_PATHS` | `/data` | Comma-separated directories to create (accessible over SFTP) |
| `SSH_KEY_DIR` | `/home/sftpuser/.ssh` | Where keys are stored inside the container |
| `HOST_KEY_DIR` | `/home/sftpuser/.host_keys` | Where SSH host keys are persisted inside the container |

Example — serve multiple directories:

```bash
docker run -d --name simple-sftp-server \
  -p 2222:22 \
  -e SSH_KEY_DIR=/keys \
  -e SFTP_PATHS=/data,/uploads,/backups \
  -v /home/user/.ssh_keys/simple-sftp:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/home/sftpuser/.host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  -v /home/user/sftp_uploads:/home/sftpuser/uploads \
  -v /home/user/sftp_backups:/home/sftpuser/backups \
  pacnpal/simple-sftp-server
```

---

## Building from Source

Only needed if you want to modify the server yourself:

```bash
git clone https://github.com/pacnpal/simple-sftp-server.git
cd simple-sftp-server
docker build -t simple-sftp-server .
```

Then use `simple-sftp-server` instead of `pacnpal/simple-sftp-server` in the commands above.

---

## Security

- **SFTP only** — no shell access, no SCP
- **Key auth only** — password authentication is disabled
- **Chrooted** — user is locked to their home directory, can't see anything else
- All forwarding disabled (TCP, agent, X11, tunneling)
- Generated client keys are host-persisted by design for convenience. Secure your host client-key directory.
- Host keys are generated at first start, not baked into the image (each container gets unique keys)
- Invalid/unreadable persisted key state causes startup to fail instead of silently rotating keys

---

## License

MIT — see [LICENSE](https://github.com/pacnpal/simple-sftp-server/blob/main/LICENSE).
