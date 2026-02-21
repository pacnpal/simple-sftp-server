#!/bin/sh
set -e

# Persist host keys inside the user home so a single volume mount covers everything.
# If /etc/ssh is mounted directly, this is a no-op (keys already persist there).
HOST_KEY_PERSIST="/home/sftpuser/.host_keys"
mkdir -p "$HOST_KEY_PERSIST"
chmod 700 "$HOST_KEY_PERSIST"

if [ -f "$HOST_KEY_PERSIST/ssh_host_ed25519_key" ] && [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  cp "$HOST_KEY_PERSIST"/ssh_host_* /etc/ssh/
elif [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
  cp /etc/ssh/ssh_host_* "$HOST_KEY_PERSIST/"
fi

PERSIST_SSH="${SSH_KEY_DIR:-/home/sftpuser/.ssh}"
RUNTIME_SSH="/etc/ssh/sftpuser_keys"
SFTP_DIRS="${SFTP_PATHS:-/data}"
SSH_PORT="${SFTP_PORT:-22}"

# Set sshd listen port (must be before the Match block)
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
grep -q "^Port" /etc/ssh/sshd_config || sed -i "/^Match/i Port ${SSH_PORT}" /etc/ssh/sshd_config

# Point sshd at the container-only copy of authorized_keys (before Match block)
grep -q "^AuthorizedKeysFile" /etc/ssh/sshd_config || \
  sed -i "/^Match/i AuthorizedKeysFile ${RUNTIME_SSH}/authorized_keys" /etc/ssh/sshd_config

# Setup persistent .ssh on the mounted volume
mkdir -p "$PERSIST_SSH"

# Check if we have real (non-comment, non-empty) keys
has_keys=false
if [ -f "$PERSIST_SSH/authorized_keys" ] && grep -qv '^#\|^[[:space:]]*$' "$PERSIST_SSH/authorized_keys" 2>/dev/null; then
  has_keys=true
fi

if [ "$has_keys" = false ]; then
  echo "=============================================="
  echo "  SFTP SERVER - FIRST RUN KEY GENERATION"
  echo "=============================================="
  echo ""

  KEY_FILE="$PERSIST_SSH/sftpuser_key"
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "sftpuser@sftp-server" > /dev/null 2>&1
  cp "${KEY_FILE}.pub" "$PERSIST_SSH/authorized_keys"

  echo "A new SSH keypair has been generated."
  echo ""
  echo "Your private key is in the mounted volume at:"
  echo "  ${PERSIST_SSH}/sftpuser_key"
  echo ""
  echo "Connect with:"
  echo "  sftp -i sftp_key -P <mapped_port> sftpuser@<host>"
  echo ""
  echo "=============================================="
else
  key_count=$(grep -cv '^#\|^[[:space:]]*$' "$PERSIST_SSH/authorized_keys" 2>/dev/null || echo 0)
  echo "=============================================="
  echo "  SFTP SERVER - USING EXISTING KEYS"
  echo "=============================================="
  echo "Found authorized_keys with ${key_count} key(s)."
  echo "=============================================="
fi

# Copy keys to a container-only directory with correct permissions.
# This avoids SSH refusing keys due to bind-mount permission issues.
rm -rf "$RUNTIME_SSH"
mkdir -p "$RUNTIME_SSH"
cp "$PERSIST_SSH/authorized_keys" "$RUNTIME_SSH/authorized_keys"
chown -R sftpuser:sftpuser "$RUNTIME_SSH"
chmod 700 "$RUNTIME_SSH"
chmod 600 "$RUNTIME_SSH/authorized_keys"

# Chroot requires root-owned home, writable subdirs
chown root:root /home/sftpuser
chmod 755 /home/sftpuser

# Create SFTP directories
echo ""
IFS=','
for dir in $SFTP_DIRS; do
  mkdir -p "/home/sftpuser${dir}"
  chown sftpuser:sftpuser "/home/sftpuser${dir}"
  echo "Serving SFTP path: ${dir}"
done

echo ""
echo "SFTP server starting on port ${SSH_PORT}..."
echo ""

exec /usr/sbin/sshd -D -e
