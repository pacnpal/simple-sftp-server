# Simple SFTP Server

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

```bash
docker run -d --name sftp \
  -p 2222:22 \
  -v /home/user/sftp_host_keys:/etc/ssh \
  -v /home/user/sftp_keys:/home/sftpuser/.ssh \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

What this does:
- Downloads the image (first time only)
- Starts an SFTP server in the background
- Maps port `2222` on your machine to the server
- Bind-mounts host directories so everything persists across container restarts and rebuilds:
  - `/home/user/sftp_host_keys` — server host keys (prevents "host key changed" warnings)
  - `/home/user/sftp_keys` — your login keys
  - `/home/user/sftp_data` — your uploaded files

### Get Your Login Key

The server generated a key for you on first start. Copy it to your current folder:

```bash
docker cp sftp:/home/sftpuser/.ssh/sftpuser_key ./sftp_key
```

Then set the permissions (required, or SSH will refuse to use it):

```bash
chmod 600 ./sftp_key
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
docker stop sftp

# Start it back up (your files and keys are still there)
docker start sftp

# Remove it completely
docker rm -f sftp
```

Your files, keys, and server config are stored on the host filesystem, so they persist across `stop`, `start`, and even `docker rm` + recreate. They only go away if you explicitly delete the directories:

```bash
# WARNING: This deletes all your uploaded files, keys, and host keys
rm -rf /home/user/sftp_host_keys /home/user/sftp_keys /home/user/sftp_data
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
    volumes:
      - /home/user/sftp_host_keys:/etc/ssh
      - /home/user/sftp_ssh:/home/sftpuser/.ssh
      - /home/user/sftp_data:/home/sftpuser/data
```

Then run:

```bash
docker compose up -d
```

Everything else is the same — get the key and connect as described above.

---

## Bring Your Own Keys

If you already have SSH keys and an `authorized_keys` file, you can skip the auto-generated key. Mount yours in:

```bash
docker run -d --name sftp \
  -p 2222:22 \
  -v /home/user/sftp_host_keys:/etc/ssh \
  -v /path/to/your/authorized_keys:/home/sftpuser/.ssh/authorized_keys:ro \
  -v /home/user/sftp_data:/home/sftpuser/data \
  pacnpal/simple-sftp-server
```

Replace `/path/to/your/authorized_keys` with the actual path to your file. Then connect using whatever private key matches.

---

## Environment Variables

You can customize behavior with these:

| Variable | Default | What it does |
|---|---|---|
| `SFTP_PORT` | `22` | Port the SFTP server listens on inside the container |
| `SFTP_PATHS` | `/data` | Comma-separated directories to create (accessible over SFTP) |
| `SSH_KEY_DIR` | `/home/sftpuser/.ssh` | Where keys are stored inside the container |

Example — serve multiple directories:

```bash
docker run -d --name sftp \
  -p 2222:22 \
  -e SFTP_PATHS=/data,/uploads,/backups \
  -v /home/user/sftp_host_keys:/etc/ssh \
  -v /home/user/sftp_keys:/home/sftpuser/.ssh \
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
- **Chrooted** — user is locked to their home directory, can't see anything else
- All forwarding disabled (TCP, agent, X11, tunneling)
- Host keys are generated at first start, not baked into the image (each container gets unique keys). Bind-mount `/etc/ssh` to a host directory to persist them across container rebuilds

---

## License

MIT — see [LICENSE](LICENSE).
