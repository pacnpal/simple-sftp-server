#!/bin/sh
set -e

SSH_DIR="${SSH_KEY_DIR:-/home/sftpuser/.ssh}"
SFTP_DIRS="${SFTP_PATHS:-/data}"
SSH_PORT="${SFTP_PORT:-22}"

# Set sshd listen port
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
grep -q "^Port" /etc/ssh/sshd_config || echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config

# Setup .ssh
mkdir -p "$SSH_DIR"
chown sftpuser:sftpuser "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Check if we have real (non-comment, non-empty) keys
has_keys=false
if [ -f "$SSH_DIR/authorized_keys" ] && grep -qv '^#\|^[[:space:]]*$' "$SSH_DIR/authorized_keys" 2>/dev/null; then
  has_keys=true
fi

if [ "$has_keys" = false ]; then
  echo "=============================================="
  echo "  SFTP SERVER - FIRST RUN KEY GENERATION"
  echo "=============================================="
  echo ""

  KEY_FILE="$SSH_DIR/sftpuser_key"
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "sftpuser@sftp-server" > /dev/null 2>&1
  cp "${KEY_FILE}.pub" "$SSH_DIR/authorized_keys"

  echo "A new SSH keypair has been generated."
  echo ""
  echo "Keys are available in your mounted .ssh volume:"
  echo "  Private key: ${KEY_FILE}"
  echo "  Public key:  ${KEY_FILE}.pub"
  echo "  Authorized:  ${SSH_DIR}/authorized_keys"
  echo ""
  echo "Retrieve the private key with:"
  echo "  docker cp <container>:${KEY_FILE} ./sftp_key && chmod 600 ./sftp_key"
  echo ""
  echo "Then connect with:"
  echo "  sftp -i sftp_key -P <mapped_port> sftpuser@<host>"
  echo ""
  echo "=============================================="
else
  key_count=$(grep -cv '^#\|^[[:space:]]*$' "$SSH_DIR/authorized_keys" 2>/dev/null || echo 0)
  echo "=============================================="
  echo "  SFTP SERVER - USING EXISTING KEYS"
  echo "=============================================="
  echo "Found authorized_keys with ${key_count} key(s)."
  echo "=============================================="
fi

chown -R sftpuser:sftpuser "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
[ -f "$SSH_DIR/sftpuser_key" ] && chmod 600 "$SSH_DIR/sftpuser_key"

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
