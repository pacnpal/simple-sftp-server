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
  --user "$(id -u):$(id -g)" \
  --cap-add SYS_CHROOT \
  -p 2222:2022 \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e SSH_KEY_DIR=/keys \
  -e HOST_KEY_DIR=/host_keys \
  -e SFTP_CHROOT=true \
  -v /home/user/.ssh_keys/simple-sftp:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

Recommended mode is **jailed** (`SFTP_CHROOT=true`).
Chroot mode confines authenticated users to `/home/sftpuser`, which reduces accidental exposure of unrelated mounted paths.
Chroot mode requires `SYS_CHROOT` capability at runtime.
This project is provided as-is, without warranty or support. Operators are responsible for secure deployment.

This image intentionally stores generated client keys on the host for convenience. You are responsible for securing `/home/user/.ssh_keys/simple-sftp`.
Use non-overlapping host directories for `/keys`, `/host_keys`, and `/home/sftpuser/data`.

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
    user: "${PUID:-1000}:${PGID:-1000}"
    cap_add:
      - SYS_CHROOT
    ports:
      - "${SFTP_HOST_PORT:-2222}:2022"
    environment:
      - PUID=1000
      - PGID=1000
      - SSH_KEY_DIR=/keys
      - HOST_KEY_DIR=/host_keys
      - SFTP_CHROOT=true
    volumes:
      - /home/user/.ssh_keys/simple-sftp:/keys
      - /home/user/.ssh_keys/simple-sftp-host:/host_keys
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
  --user "$(id -u):$(id -g)" \
  --cap-add SYS_CHROOT \
  -p 2222:2022 \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e SSH_KEY_DIR=/keys \
  -e HOST_KEY_DIR=/host_keys \
  -e SFTP_CHROOT=true \
  -v /path/to/your/keydir:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

Replace `/path/to/your/keydir` with the directory containing `authorized_keys`.

---

## Key Handling (No Silent Rotation)

- `authorized_keys` is copied at startup to `/tmp/simple-sftp-runtime/authorized_keys` with strict runtime permissions.
- New keys are generated only on true first run (no existing key files).
- If persisted key state is unreadable, empty, or inconsistent, startup fails with a clear error instead of rotating keys.
- Host keys are persisted in `HOST_KEY_DIR` (`/host_keys` by default). Missing host key types are auto-generated on startup.
- BYO `authorized_keys` can be mounted read-only; write access is only required for first-run key generation.
- If a legacy root-owned host-key volume is unreadable in rootless mode, startup falls back to runtime-only host keys and logs migration guidance.

---

## SSHD Configuration

- The image ships a managed `sshd` template at build time (see `sshd_config.template` in this repo).
- Startup renders a concrete config from that template and starts sshd with:
  `sshd -D -e -f /tmp/simple-sftp-runtime/sshd_config.runtime`
- `AuthorizedKeysFile` is pinned to `/tmp/simple-sftp-runtime/authorized_keys` to avoid host mount permission edge cases.
- Internal SFTP listen port is fixed at `2022`; change only the host publish port (`-p <host_port>:2022`).
- The container runs rootless by default.
- `SFTP_CHROOT=true` (default/recommended): enables `ChrootDirectory /home/sftpuser`.
- `SFTP_CHROOT=false`: disables filesystem jail.
- Chroot mode requires `CAP_SYS_CHROOT` (`--cap-add SYS_CHROOT` / Compose `cap_add: [SYS_CHROOT]`).
- No chroot means authenticated users can traverse readable paths outside `/home/sftpuser`.
- Non-chroot mode is operator responsibility and is provided without warranty or support.

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
docker exec <container_name> sh -lc 'ssh-keygen -lf /tmp/simple-sftp-runtime/authorized_keys'
ssh-keygen -y -f sftp_key | ssh-keygen -lf -
```

The `authorizedkeysfile` path should be `/tmp/simple-sftp-runtime/authorized_keys`, and the two fingerprints should match.

### `server lacks privileges to chroot to ChrootDirectory`

This means `SFTP_CHROOT=true` but the container does not have `CAP_SYS_CHROOT`.

Fix:

- `docker run`: add `--cap-add SYS_CHROOT`
- Compose: add

```yaml
cap_add:
  - SYS_CHROOT
```

If your runtime policy does not allow this capability, set `SFTP_CHROOT=false` and accept the no-chroot risk model.

### Host key keeps changing

If clients warn about host key changes, your host-key mount is not persisting stable key files.

```bash
docker inspect <container_name> --format '{{range .Mounts}}{{.Destination}} <- {{.Source}}{{println}}{{end}}'
ls -l /home/user/.ssh_keys/simple-sftp-host/ssh_host_*
```

Keep `/host_keys` mounted to a stable host directory and avoid overlapping it under an SFTP-exposed parent mount.

### Permission denied reading or writing key directories

If logs include errors like:

```text
cp: can't open '/host_keys/ssh_host_rsa_key': Permission denied
```

the mounted key directories are not readable/writable by the container.

- Ensure `HOST_KEY_DIR` and `SSH_KEY_DIR` mounts are readable/writable during startup.
- Ensure any mounted SFTP data directories are writable by your selected `PUID`/`PGID`.

---

## Environment Variables

You can customize behavior with these:

| Variable | Default | What it does |
|---|---|---|
| `SFTP_PATHS` | `/data` | Comma-separated directories to create (accessible over SFTP) |
| `SSH_KEY_DIR` | `/keys` | Where user keys are stored inside the container |
| `HOST_KEY_DIR` | `/host_keys` | Where SSH host keys are persisted inside the container |
| `PUID` | `SFTP_UID` (`1000` by default) | Runtime UID to run the container as |
| `PGID` | `SFTP_GID` (`1000` by default) | Runtime GID to run the container as |
| `SFTP_CHROOT` | `true` | `true` enables filesystem jail (`ChrootDirectory`) |

`SSH_KEY_DIR` and `HOST_KEY_DIR` should be absolute paths. For backward compatibility, relative values like `keys` are interpreted as `/keys`.

### UID/GID Customization (Runtime)

To match host filesystem ownership, pass `PUID` and `PGID` at container startup:

```bash
docker run -d --name simple-sftp-server \
  --user "$(id -u):$(id -g)" \
  --cap-add SYS_CHROOT \
  -p 2222:2022 \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e SSH_KEY_DIR=/keys \
  -e HOST_KEY_DIR=/host_keys \
  -e SFTP_CHROOT=true \
  -v /home/user/.ssh_keys/simple-sftp:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

`PUID`/`PGID` must match the container runtime user (`user:` / `--user`).

Example — serve multiple directories:

```bash
docker run -d --name simple-sftp-server \
  --user "$(id -u):$(id -g)" \
  --cap-add SYS_CHROOT \
  -p 2222:2022 \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e SSH_KEY_DIR=/keys \
  -e HOST_KEY_DIR=/host_keys \
  -e SFTP_CHROOT=true \
  -e SFTP_PATHS=/data,/uploads,/backups \
  -v /home/user/.ssh_keys/simple-sftp:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  -v /home/user/sftp_uploads:/home/sftpuser/uploads \
  -v /home/user/sftp_backups:/home/sftpuser/backups \
  pacnpal/simple-sftp-server
```

### No-Chroot Opt-Out

Use this only when you intentionally accept a wider filesystem access model for authenticated users.

```bash
docker run -d --name simple-sftp-server \
  --user "$(id -u):$(id -g)" \
  -p 2222:2022 \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e SSH_KEY_DIR=/keys \
  -e HOST_KEY_DIR=/host_keys \
  -e SFTP_CHROOT=false \
  -v /home/user/.ssh_keys/simple-sftp:/keys \
  -v /home/user/.ssh_keys/simple-sftp-host:/host_keys \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

Compose equivalent:

```yaml
services:
  sftp:
    image: pacnpal/simple-sftp-server:latest
    user: "${PUID:-1000}:${PGID:-1000}"
    environment:
      - SFTP_CHROOT=false
```

### No-Chroot Risk Notice

If you run with `SFTP_CHROOT=false`, this image does **not** isolate the SFTP user to `/home/sftpuser`.

- No-chroot mode does not provide a filesystem boundary for authenticated users.
- Any user with valid credentials can access files permitted by container Unix permissions.
- Readable secrets in mounted paths are exposed to authenticated users.
- Writable key paths allow authenticated users to modify key material and preserve access.
- If you need confinement, set `SFTP_CHROOT=true` and add `SYS_CHROOT`.
- If this risk model is not acceptable, do not deploy no-chroot mode.
- This mode is provided without warranty or support.

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
- **Rootless by default** — run with `user: "${PUID}:${PGID}"` / `--user "${PUID}:${PGID}"`
- **Runtime UID/GID via env** — `PUID`/`PGID` must match container runtime uid/gid
- **Recommended default mode** — filesystem jail enabled (`SFTP_CHROOT=true`)
- **Chroot requirement** — add `cap_add: [SYS_CHROOT]` / `--cap-add SYS_CHROOT`
- **Risk model** — no chroot means authenticated users can traverse readable paths in the container/mounts
- **No-chroot policy** — operator-managed risk; provided without warranty or support
- All forwarding disabled (TCP, agent, X11, tunneling)
- Generated client keys are host-persisted by design for convenience. Secure your host client-key directory.
- Host keys are generated at first start, not baked into the image (each container gets unique keys)
- Invalid/unreadable persisted key state causes startup to fail instead of silently rotating keys

---

## License

MIT — see [LICENSE](https://github.com/pacnpal/simple-sftp-server/blob/main/LICENSE).
