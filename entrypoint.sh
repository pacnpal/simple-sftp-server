#!/bin/sh
set -eu

SSHD_BIN="/usr/sbin/sshd"
SSHD_CONFIG="/etc/ssh/sshd_config"
SFTP_USER="sftpuser"
SFTP_HOME="/home/${SFTP_USER}"
RUNTIME_SSH="/etc/ssh/sftpuser_keys"
RUNTIME_HOST_KEY_DIR="/etc/ssh"

HOST_KEY_PERSIST="${HOST_KEY_DIR:-${SFTP_HOME}/.host_keys}"
PERSIST_SSH="${SSH_KEY_DIR:-${SFTP_HOME}/.ssh}"
SFTP_DIRS="${SFTP_PATHS:-/data}"
SSH_PORT="${SFTP_PORT:-22}"

normalize_dir() {
  dir="$1"
  # Preserve "/" while trimming trailing slashes for path equality checks.
  if [ "$dir" = "/" ]; then
    printf '/'
    return
  fi
  printf '%s' "$dir" | sed 's:/*$::'
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_absolute_path() {
  path="$1"
  var_name="$2"

  case "$path" in
    /*) ;;
    *)
      fail "${var_name} must be an absolute path. Got: ${path}"
      ;;
  esac
}

validate_port() {
  case "$SSH_PORT" in
    ''|*[!0-9]*)
      fail "SFTP_PORT must be a numeric TCP port. Got: ${SSH_PORT}"
      ;;
  esac

  if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    fail "SFTP_PORT must be between 1 and 65535. Got: ${SSH_PORT}"
  fi
}

unlock_sftp_user_if_needed() {
  # Some base image/user-add combinations leave the account shadow-locked ("!"/"*"),
  # which blocks SSH public-key auth before key checks even run.
  if [ -f /etc/shadow ] && grep -q '^sftpuser:[!*]' /etc/shadow; then
    passwd -d sftpuser >/dev/null 2>&1 || true
    sed -i 's/^sftpuser:[^:]*:/sftpuser::/' /etc/shadow
  fi
}

prepare_host_keys() {
  mkdir -p "$HOST_KEY_PERSIST"
  chmod 700 "$HOST_KEY_PERSIST"

  persist_is_runtime=false
  if [ "$(normalize_dir "$HOST_KEY_PERSIST")" = "$(normalize_dir "$RUNTIME_HOST_KEY_DIR")" ]; then
    persist_is_runtime=true
  fi

  loaded_count=0
  for key_type in rsa ecdsa ed25519; do
    persisted_key="${HOST_KEY_PERSIST}/ssh_host_${key_type}_key"
    persisted_pub="${persisted_key}.pub"
    runtime_key="${RUNTIME_HOST_KEY_DIR}/ssh_host_${key_type}_key"
    runtime_pub="${runtime_key}.pub"

    if [ -f "$persisted_key" ]; then
      if [ "$persist_is_runtime" = false ]; then
        cp "$persisted_key" "$runtime_key"
      fi

      if [ -f "$persisted_pub" ]; then
        if [ "$persist_is_runtime" = false ]; then
          cp "$persisted_pub" "$runtime_pub"
        fi
      else
        # Recover missing .pub from an existing private key.
        ssh-keygen -y -f "$runtime_key" > "$runtime_pub" 2>/dev/null || \
          fail "Failed to derive host public key for ${key_type} from ${persisted_key}."
        if [ "$persist_is_runtime" = false ]; then
          cp "$runtime_pub" "$persisted_pub"
        fi
      fi

      loaded_count=$((loaded_count + 1))
      continue
    fi

    if [ -f "$persisted_pub" ]; then
      echo "WARNING: Found ${persisted_pub} without private key. A new ${key_type} host keypair will be generated."
    fi
  done

  # Generate only missing host key types in /etc/ssh.
  ssh-keygen -A >/dev/null 2>&1

  # Ensure we ended up with a complete usable set, then persist it.
  for key_type in rsa ecdsa ed25519; do
    runtime_key="${RUNTIME_HOST_KEY_DIR}/ssh_host_${key_type}_key"
    runtime_pub="${runtime_key}.pub"
    [ -f "$runtime_key" ] && [ -f "$runtime_pub" ] || \
      fail "Missing runtime ${key_type} host key after generation."
  done

  if [ "$persist_is_runtime" = false ]; then
    cp "${RUNTIME_HOST_KEY_DIR}"/ssh_host_* "$HOST_KEY_PERSIST/"
  fi

  if [ "$loaded_count" -eq 0 ]; then
    echo "Initialized new SSH host keys in ${HOST_KEY_PERSIST}."
  elif [ "$loaded_count" -lt 3 ]; then
    echo "Completed partial persisted host key set in ${HOST_KEY_PERSIST}."
  fi

  chmod 600 /etc/ssh/ssh_host_*_key
  chmod 644 /etc/ssh/ssh_host_*.pub
  chmod 600 "$HOST_KEY_PERSIST"/ssh_host_*_key
  chmod 644 "$HOST_KEY_PERSIST"/ssh_host_*.pub
}

prepare_auth_keys() {
  mkdir -p "$PERSIST_SSH"

  AUTH_KEYS="${PERSIST_SSH}/authorized_keys"
  KEY_FILE="${PERSIST_SSH}/sftpuser_key"
  PUB_KEY_FILE="${KEY_FILE}.pub"

  has_keys=false
  if [ -e "$AUTH_KEYS" ]; then
    if [ ! -r "$AUTH_KEYS" ]; then
      fail "Found ${AUTH_KEYS} but it is not readable. Fix host permissions and restart."
    fi
    if ! grep -qv '^#\|^[[:space:]]*$' "$AUTH_KEYS"; then
      fail "${AUTH_KEYS} contains no valid SSH public keys. Add at least one key and restart."
    fi
    has_keys=true
  else
    if [ -e "$KEY_FILE" ] || [ -e "$PUB_KEY_FILE" ]; then
      fail "Incomplete key state in ${PERSIST_SSH}. Found key material without ${AUTH_KEYS}."
    fi
  fi

  if [ "$has_keys" = false ]; then
    echo "=============================================="
    echo "  SFTP SERVER - FIRST RUN KEY GENERATION"
    echo "=============================================="
    echo ""

    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "sftpuser@sftp-server" >/dev/null 2>&1
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

  # Keep generated key material manageable on host bind mounts.
  # Ignore failures so read-only mounted authorized_keys does not break startup.
  chown "$SFTP_USER":"$SFTP_USER" "$PERSIST_SSH" 2>/dev/null || true
  chmod 700 "$PERSIST_SSH" 2>/dev/null || true
  chown "$SFTP_USER":"$SFTP_USER" \
    "$AUTH_KEYS" \
    "$KEY_FILE" \
    "$PUB_KEY_FILE" 2>/dev/null || true
  chmod 600 "$AUTH_KEYS" 2>/dev/null || true
  chmod 600 "$KEY_FILE" 2>/dev/null || true
  chmod 644 "$PUB_KEY_FILE" 2>/dev/null || true

  # Copy keys to a container-only directory with strict permissions.
  # This avoids SSH refusing keys due to host bind-mount permission issues.
  mkdir -p "$RUNTIME_SSH"
  cp "$AUTH_KEYS" "$RUNTIME_SSH/authorized_keys"
  chown root:root "$RUNTIME_SSH" "$RUNTIME_SSH/authorized_keys"
  chmod 755 "$RUNTIME_SSH"
  chmod 600 "$RUNTIME_SSH/authorized_keys"
}

prepare_sftp_paths() {
  # Chroot requires root-owned home, writable subdirectories below it.
  chown root:root "$SFTP_HOME"
  chmod 755 "$SFTP_HOME"

  echo ""

  served_count=0
  old_ifs=$IFS
  IFS=','
  for raw_dir in $SFTP_DIRS; do
    dir=$(printf '%s' "$raw_dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$dir" ] || continue

    case "$dir" in
      /*) ;;
      *)
        fail "Invalid SFTP path '${dir}'. Paths must start with '/'."
        ;;
    esac

    case "$dir" in
      *..*)
        fail "Invalid SFTP path '${dir}'. '..' is not allowed."
        ;;
    esac

    if [ "$dir" = "/" ]; then
      fail "SFTP_PATHS cannot contain '/'. Use subdirectories such as '/data'."
    fi

    case "$dir" in
      /.ssh|/.ssh/*|/.host_keys|/.host_keys/*)
        fail "Refusing to expose key-management path '${dir}' over SFTP."
        ;;
    esac

    mkdir -p "${SFTP_HOME}${dir}"
    chown "$SFTP_USER":"$SFTP_USER" "${SFTP_HOME}${dir}"
    chmod 755 "${SFTP_HOME}${dir}"
    echo "Serving SFTP path: ${dir}"
    served_count=$((served_count + 1))
  done
  IFS=$old_ifs

  if [ "$served_count" -eq 0 ]; then
    fail "SFTP_PATHS did not contain any usable paths."
  fi

  echo ""
}

start_sshd() {
  if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG" -p "$SSH_PORT"; then
    fail "sshd configuration is invalid. Check the logs above."
  fi

  echo "SFTP server starting on port ${SSH_PORT}..."
  echo ""

  exec "$SSHD_BIN" -D -e -f "$SSHD_CONFIG" -p "$SSH_PORT"
}

main() {
  validate_absolute_path "$PERSIST_SSH" "SSH_KEY_DIR"
  validate_absolute_path "$HOST_KEY_PERSIST" "HOST_KEY_DIR"
  validate_port
  unlock_sftp_user_if_needed
  prepare_host_keys
  prepare_auth_keys
  prepare_sftp_paths
  start_sshd
}

main "$@"
