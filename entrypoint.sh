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

# Enforce correct permissions — bind-mount filesystems may not preserve them
chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
chmod 600 "$HOST_KEY_PERSIST"/ssh_host_*_key 2>/dev/null || true

PERSIST_SSH="${SSH_KEY_DIR:-/home/sftpuser/.ssh}"
RUNTIME_SSH="/etc/ssh/sftpuser_keys"
SFTP_DIRS="${SFTP_PATHS:-/data}"
SSH_PORT="${SFTP_PORT:-22}"

# Some base image/user-add combinations leave the account shadow-locked ("!"/"*"),
# which blocks SSH public-key auth before key checks even run.
if [ -f /etc/shadow ] && grep -q '^sftpuser:[!*]' /etc/shadow; then
  passwd -d sftpuser >/dev/null 2>&1 || true
  sed -i 's/^sftpuser:[^:]*:/sftpuser::/' /etc/shadow
fi

# Set sshd listen port (must be before the Match block)
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
grep -q "^Port" /etc/ssh/sshd_config || sed -i "/^Match/i Port ${SSH_PORT}" /etc/ssh/sshd_config

# Point sshd at the container-only copy of authorized_keys (before Match block)
grep -q "^AuthorizedKeysFile" /etc/ssh/sshd_config || \
  sed -i "/^Match/i AuthorizedKeysFile ${RUNTIME_SSH}/authorized_keys" /etc/ssh/sshd_config

# Setup persistent .ssh on the mounted volume
mkdir -p "$PERSIST_SSH"
AUTH_KEYS="$PERSIST_SSH/authorized_keys"
KEY_FILE="$PERSIST_SSH/sftpuser_key"
PUB_KEY_FILE="${KEY_FILE}.pub"

# Validate persisted key state to avoid silent key rotation.
# - Use existing authorized_keys when present and readable.
# - Generate keys only on true first run (no key files present).
# - Fail on partial or unreadable key state.
has_keys=false
if [ -e "$AUTH_KEYS" ]; then
  if [ ! -r "$AUTH_KEYS" ]; then
    echo "ERROR: Found ${AUTH_KEYS} but it is not readable."
    echo "Fix host permissions and restart. Refusing to rotate keys."
    exit 1
  fi
  if ! grep -qv '^#\|^[[:space:]]*$' "$AUTH_KEYS"; then
    echo "ERROR: ${AUTH_KEYS} contains no valid SSH public keys."
    echo "Add at least one key and restart."
    exit 1
  fi
  has_keys=true
else
  if [ -e "$KEY_FILE" ] || [ -e "$PUB_KEY_FILE" ]; then
    echo "ERROR: Incomplete key state in ${PERSIST_SSH}."
    echo "Found key material without ${AUTH_KEYS}. Refusing to generate new keys."
    echo "Restore ${AUTH_KEYS} or remove partial key files and restart."
    exit 1
  fi
fi

if [ "$has_keys" = false ]; then
  echo "=============================================="
  echo "  SFTP SERVER - FIRST RUN KEY GENERATION"
  echo "=============================================="
  echo ""

  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "sftpuser@sftp-server" > /dev/null 2>&1
  cp "$PUB_KEY_FILE" "$AUTH_KEYS"

  echo "A new SSH keypair has been generated."
  echo ""
  echo "WARNING: Store this private key securely on the host."
  echo "Anyone with this file can access your SFTP server."
  echo ""
  echo "Your private key is in the mounted volume at:"
  echo "  ${PERSIST_SSH}/sftpuser_key"
  echo ""
  echo "Connect with:"
  echo "  sftp -i sftp_key -P <mapped_port> sftpuser@<host>"
  echo ""
  echo "=============================================="
else
  key_count=$(grep -cv '^#\|^[[:space:]]*$' "$AUTH_KEYS" 2>/dev/null || echo 0)
  echo "=============================================="
  echo "  SFTP SERVER - USING EXISTING KEYS"
  echo "=============================================="
  echo "Found authorized_keys with ${key_count} key(s)."
  echo "=============================================="
fi

# Normalize ownership/permissions on persisted key material.
# This keeps first-run generated keys manageable from the host bind mount.
# Ignore failures so read-only mounted authorized_keys does not break startup.
chown sftpuser:sftpuser "$PERSIST_SSH" 2>/dev/null || true
chmod 700 "$PERSIST_SSH" 2>/dev/null || true
chown sftpuser:sftpuser \
  "$AUTH_KEYS" \
  "$KEY_FILE" \
  "$PUB_KEY_FILE" 2>/dev/null || true
chmod 600 "$AUTH_KEYS" 2>/dev/null || true
chmod 600 "$KEY_FILE" 2>/dev/null || true
chmod 644 "$PUB_KEY_FILE" 2>/dev/null || true

# Copy keys to a container-only directory with correct permissions.
# This avoids SSH refusing keys due to bind-mount permission issues.
rm -rf "$RUNTIME_SSH"
mkdir -p "$RUNTIME_SSH"
cp "$AUTH_KEYS" "$RUNTIME_SSH/authorized_keys"
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

# Validate config before starting — catch errors early
if ! /usr/sbin/sshd -t 2>&1; then
  echo "ERROR: sshd configuration is invalid. Check the logs above."
  exit 1
fi

echo "SFTP server starting on port ${SSH_PORT}..."
echo ""

exec /usr/sbin/sshd -D -e
