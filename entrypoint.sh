#!/bin/sh
set -eu

SSHD_BIN="/usr/sbin/sshd"
SSHD_TEMPLATE="/etc/ssh/sshd_config.template"
RUNTIME_SSHD_CONFIG="/etc/ssh/sshd_config.runtime"

SFTP_USER="sftpuser"
SFTP_HOME="/home/${SFTP_USER}"
SFTP_PORT="2022"
RUNTIME_SSH="/etc/ssh/sftpuser_keys"

HOST_KEY_PERSIST="${HOST_KEY_DIR:-/etc/ssh/host_keys}"
PERSIST_SSH="${SSH_KEY_DIR:-${SFTP_HOME}/.ssh}"
SFTP_DIRS="${SFTP_PATHS:-/data}"
SFTP_GROUP="sftpgroup"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

normalize_dir() {
  dir="$1"
  if [ "$dir" = "/" ]; then
    printf '/'
    return
  fi
  printf '%s' "$dir" | sed 's:/*$::'
}

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

resolve_container_path() {
  path="$1"
  var_name="$2"

  [ -n "$path" ] || fail "${var_name} cannot be empty."

  case "$path" in
    /*)
      resolved="$path"
      ;;
    *)
      resolved="/$path"
      echo "WARNING: ${var_name} should be absolute. Interpreting '${path}' as '${resolved}'." >&2
      ;;
  esac

  normalize_dir "$resolved"
}

validate_runtime_id() {
  value="$1"
  var_name="$2"

  case "$value" in
    ''|*[!0-9]*)
      fail "${var_name} must be a positive integer. Got: ${value}"
      ;;
  esac

  if [ "$value" -lt 1 ]; then
    fail "${var_name} must be >= 1. Got: ${value}"
  fi
}

require_root() {
  uid="$(id -u)"
  if [ "$uid" -ne 0 ]; then
    fail "Container must start as root to support runtime PUID/PGID remap and chroot setup."
  fi
}

configure_runtime_user_group() {
  requested_uid="${PUID:-}"
  requested_gid="${PGID:-}"

  current_uid="$(id -u "$SFTP_USER" 2>/dev/null || true)"
  current_gid="$(id -g "$SFTP_USER" 2>/dev/null || true)"
  [ -n "$current_uid" ] || fail "User ${SFTP_USER} is missing from /etc/passwd."
  [ -n "$current_gid" ] || fail "User ${SFTP_USER} has no valid primary group."

  [ -n "$requested_uid" ] || requested_uid="$current_uid"
  [ -n "$requested_gid" ] || requested_gid="$current_gid"

  validate_runtime_id "$requested_uid" "PUID"
  validate_runtime_id "$requested_gid" "PGID"

  existing_user="$(awk -F: -v uid="$requested_uid" '$3==uid {print $1; exit}' /etc/passwd)"
  if [ -n "$existing_user" ] && [ "$existing_user" != "$SFTP_USER" ]; then
    fail "Requested PUID ${requested_uid} is already used by user '${existing_user}'."
  fi

  target_group_name="$(awk -F: -v gid="$requested_gid" '$3==gid {print $1; exit}' /etc/group)"
  if [ -z "$target_group_name" ]; then
    groupmod -g "$requested_gid" sftpgroup >/dev/null 2>&1 || \
      fail "Failed to set sftpgroup GID to ${requested_gid}."
    target_group_name="sftpgroup"
  fi

  usermod -u "$requested_uid" -g "$target_group_name" "$SFTP_USER" >/dev/null 2>&1 || \
    fail "Failed to remap ${SFTP_USER} to ${requested_uid}:${requested_gid}."

  SFTP_GROUP="$(id -gn "$SFTP_USER" 2>/dev/null || true)"
  [ -n "$SFTP_GROUP" ] || fail "Failed to resolve primary group for ${SFTP_USER}."

  if [ "$requested_uid" != "$current_uid" ] || [ "$requested_gid" != "$current_gid" ]; then
    echo "Applied runtime UID/GID remap: ${SFTP_USER} -> ${requested_uid}:${requested_gid}"
  fi
}

validate_security_paths() {
  case "$HOST_KEY_PERSIST" in
    "$SFTP_HOME"|"$SFTP_HOME"/*)
      fail "HOST_KEY_DIR must be outside ${SFTP_HOME} to avoid exposing private host keys over SFTP."
      ;;
  esac
}

ensure_host_keypair() {
  key_type="$1"
  key_file="${HOST_KEY_PERSIST}/ssh_host_${key_type}_key"
  pub_file="${key_file}.pub"
  generated=false

  if [ -f "$key_file" ]; then
    [ -r "$key_file" ] || fail "Cannot read persisted host key ${key_file}."
    if [ ! -f "$pub_file" ]; then
      ssh-keygen -y -f "$key_file" > "$pub_file" 2>/dev/null || \
        fail "Failed to derive host public key from ${key_file}."
    fi
  else
    if [ -f "$pub_file" ]; then
      echo "WARNING: Found ${pub_file} without private key. Regenerating ${key_type} host keypair."
    fi

    case "$key_type" in
      rsa)
        ssh-keygen -t rsa -b 4096 -f "$key_file" -N "" >/dev/null 2>&1 || \
          fail "Failed to generate ${key_type} host keypair in ${HOST_KEY_PERSIST}."
        ;;
      ecdsa)
        ssh-keygen -t ecdsa -b 521 -f "$key_file" -N "" >/dev/null 2>&1 || \
          fail "Failed to generate ${key_type} host keypair in ${HOST_KEY_PERSIST}."
        ;;
      ed25519)
        ssh-keygen -t ed25519 -f "$key_file" -N "" >/dev/null 2>&1 || \
          fail "Failed to generate ${key_type} host keypair in ${HOST_KEY_PERSIST}."
        ;;
      *)
        fail "Unknown key type ${key_type}."
        ;;
    esac
    generated=true
  fi

  chown root:root "$key_file" "$pub_file" 2>/dev/null || true
  chmod 600 "$key_file" || fail "Failed to set permissions on ${key_file}."
  chmod 644 "$pub_file" || fail "Failed to set permissions on ${pub_file}."

  if [ "$generated" = true ]; then
    GENERATED_HOST_KEYS=$((GENERATED_HOST_KEYS + 1))
  fi
}

prepare_host_keys() {
  mkdir -p "$HOST_KEY_PERSIST" || \
    fail "Cannot create HOST_KEY_DIR at ${HOST_KEY_PERSIST}. Check mount permissions."
  chown root:root "$HOST_KEY_PERSIST" 2>/dev/null || true
  chmod 700 "$HOST_KEY_PERSIST" || fail "Failed to set permissions on ${HOST_KEY_PERSIST}."

  GENERATED_HOST_KEYS=0
  ensure_host_keypair rsa
  ensure_host_keypair ecdsa
  ensure_host_keypair ed25519

  if [ "$GENERATED_HOST_KEYS" -eq 3 ]; then
    echo "Initialized new SSH host keys in ${HOST_KEY_PERSIST}."
  elif [ "$GENERATED_HOST_KEYS" -gt 0 ]; then
    echo "Completed partial persisted host key set in ${HOST_KEY_PERSIST}."
  fi
}

prepare_auth_keys() {
  mkdir -p "$PERSIST_SSH" || \
    fail "Cannot create SSH_KEY_DIR at ${PERSIST_SSH}. Check mount permissions."

  AUTH_KEYS="${PERSIST_SSH}/authorized_keys"
  KEY_FILE="${PERSIST_SSH}/sftpuser_key"
  PUB_KEY_FILE="${KEY_FILE}.pub"

  has_keys=false
  if [ -e "$AUTH_KEYS" ]; then
    [ -r "$AUTH_KEYS" ] || fail "Found ${AUTH_KEYS} but it is not readable."
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

    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "sftpuser@sftp-server" >/dev/null 2>&1 || \
      fail "Failed to generate user keypair in ${PERSIST_SSH}."
    cp "$PUB_KEY_FILE" "$AUTH_KEYS" || fail "Failed to initialize ${AUTH_KEYS}."

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

  chown "$SFTP_USER":"$SFTP_GROUP" "$PERSIST_SSH" 2>/dev/null || true
  chmod 700 "$PERSIST_SSH" 2>/dev/null || true
  chown "$SFTP_USER":"$SFTP_GROUP" \
    "$AUTH_KEYS" \
    "$KEY_FILE" \
    "$PUB_KEY_FILE" 2>/dev/null || true
  chmod 600 "$AUTH_KEYS" 2>/dev/null || true
  chmod 600 "$KEY_FILE" 2>/dev/null || true
  chmod 644 "$PUB_KEY_FILE" 2>/dev/null || true

  mkdir -p "$RUNTIME_SSH" || fail "Cannot create runtime key directory at ${RUNTIME_SSH}."
  cp "$AUTH_KEYS" "$RUNTIME_SSH/authorized_keys" || \
    fail "Cannot copy authorized_keys into runtime directory."
  chown root:root "$RUNTIME_SSH" 2>/dev/null || true
  chmod 755 "$RUNTIME_SSH"
  chown "$SFTP_USER":"$SFTP_GROUP" "$RUNTIME_SSH/authorized_keys" 2>/dev/null || true
  chmod 600 "$RUNTIME_SSH/authorized_keys"
}

prepare_chroot_home() {
  chown root:root "$SFTP_HOME" || fail "Failed to set ${SFTP_HOME} owner to root."
  chmod 755 "$SFTP_HOME" || fail "Failed to set ${SFTP_HOME} permissions."
}

prepare_sftp_paths() {
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

    path="${SFTP_HOME}${dir}"
    mkdir -p "$path" || fail "Cannot create SFTP path ${path}."
    chown "$SFTP_USER":"$SFTP_GROUP" "$path" 2>/dev/null || true
    chmod 755 "$path" 2>/dev/null || true
    echo "Serving SFTP path: ${dir}"
    served_count=$((served_count + 1))
  done
  IFS=$old_ifs

  if [ "$served_count" -eq 0 ]; then
    fail "SFTP_PATHS did not contain any usable paths."
  fi

  echo ""
}

render_sshd_config() {
  [ -f "$SSHD_TEMPLATE" ] || fail "Missing sshd config template at ${SSHD_TEMPLATE}."

  host_key_dir_escaped="$(escape_sed "$HOST_KEY_PERSIST")"
  auth_keys_file_escaped="$(escape_sed "${RUNTIME_SSH}/authorized_keys")"
  port_escaped="$(escape_sed "$SFTP_PORT")"
  sftp_user_escaped="$(escape_sed "$SFTP_USER")"
  pid_file_escaped="$(escape_sed "/run/sshd.pid")"

  sed \
    -e "s|__PORT__|${port_escaped}|g" \
    -e "s|__HOST_KEY_DIR__|${host_key_dir_escaped}|g" \
    -e "s|__AUTHORIZED_KEYS_FILE__|${auth_keys_file_escaped}|g" \
    -e "s|__SFTP_USER__|${sftp_user_escaped}|g" \
    -e "s|__PID_FILE__|${pid_file_escaped}|g" \
    "$SSHD_TEMPLATE" > "$RUNTIME_SSHD_CONFIG" || fail "Failed to render sshd config."

  chmod 600 "$RUNTIME_SSHD_CONFIG"
}

start_sshd() {
  if ! "$SSHD_BIN" -t -f "$RUNTIME_SSHD_CONFIG"; then
    fail "sshd configuration is invalid. Check the logs above."
  fi

  echo "SFTP server starting on port ${SFTP_PORT}..."
  echo ""

  exec "$SSHD_BIN" -D -e -f "$RUNTIME_SSHD_CONFIG"
}

main() {
  PERSIST_SSH="$(resolve_container_path "$PERSIST_SSH" "SSH_KEY_DIR")"
  HOST_KEY_PERSIST="$(resolve_container_path "$HOST_KEY_PERSIST" "HOST_KEY_DIR")"

  require_root
  configure_runtime_user_group
  validate_security_paths
  prepare_host_keys
  prepare_auth_keys
  prepare_chroot_home
  prepare_sftp_paths
  render_sshd_config
  start_sshd
}

main "$@"
