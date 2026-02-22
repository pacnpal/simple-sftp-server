#!/bin/sh
set -eu

SSHD_BIN="/usr/sbin/sshd"
SSHD_TEMPLATE="/etc/ssh/sshd_config.template"
SFTP_PORT="2022"

SFTP_USER="${SFTP_USER:-sftpuser}"
SFTP_GROUP="${SFTP_GROUP:-sftpgroup}"
SFTP_HOME="/home/sftpuser"
SFTP_DIRS="${SFTP_PATHS:-/data}"
SFTP_CHROOT="${SFTP_CHROOT:-true}"

PERSIST_SSH="${SSH_KEY_DIR:-/keys}"
HOST_KEY_PERSIST="${HOST_KEY_DIR:-/host_keys}"

RUNTIME_DIR="/tmp/simple-sftp-runtime"
RUNTIME_SSHD_CONFIG="${RUNTIME_DIR}/sshd_config.runtime"
RUNTIME_AUTH_KEYS="${RUNTIME_DIR}/authorized_keys"
NSS_PASSWD_FILE="${RUNTIME_DIR}/passwd"
NSS_GROUP_FILE="${RUNTIME_DIR}/group"

CURRENT_UID=""
CURRENT_GID=""
REQUESTED_UID=""
REQUESTED_GID=""
CHROOT_ENABLED=""

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

parse_bool() {
  value="$1"
  var_name="$2"
  normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "$normalized" in
    1|true|yes|on)
      printf 'true'
      ;;
    0|false|no|off)
      printf 'false'
      ;;
    *)
      fail "${var_name} must be one of: true, false, 1, 0, yes, no, on, off. Got: ${value}"
      ;;
  esac
}

validate_runtime_identity() {
  CURRENT_UID="$(id -u)"
  CURRENT_GID="$(id -g)"

  REQUESTED_UID="${PUID:-$CURRENT_UID}"
  REQUESTED_GID="${PGID:-$CURRENT_GID}"

  validate_runtime_id "$REQUESTED_UID" "PUID"
  validate_runtime_id "$REQUESTED_GID" "PGID"

  if [ "$CURRENT_UID" -eq 0 ]; then
    fail "Container must run rootless. Set user to \"${REQUESTED_UID}:${REQUESTED_GID}\" (Compose user:/docker --user)."
  fi

  if [ "$CURRENT_UID" -ne "$REQUESTED_UID" ] || [ "$CURRENT_GID" -ne "$REQUESTED_GID" ]; then
    fail "PUID/PGID (${REQUESTED_UID}:${REQUESTED_GID}) do not match runtime uid/gid (${CURRENT_UID}:${CURRENT_GID}). Start container with user \"${REQUESTED_UID}:${REQUESTED_GID}\"."
  fi
}

validate_security_paths() {
  case "$HOST_KEY_PERSIST" in
    "$SFTP_HOME"|"$SFTP_HOME"/*)
      fail "HOST_KEY_DIR must be outside ${SFTP_HOME} so SFTP sessions cannot reach private host keys."
      ;;
  esac
}

validate_chroot_layout() {
  for dir in / /home "$SFTP_HOME"; do
    [ -d "$dir" ] || fail "Required chroot path is missing: ${dir}"
    owner_uid="$(ls -nd "$dir" | awk '{print $3}')"
    [ "$owner_uid" = "0" ] || fail "Chroot path ${dir} must be owned by root (uid 0). Found uid ${owner_uid}."
  done

  if [ -w "$SFTP_HOME" ]; then
    fail "Chroot path ${SFTP_HOME} must not be writable by the runtime user."
  fi
}

validate_chroot_capability() {
  if ! command -v chroot >/dev/null 2>&1; then
    fail "chroot command is missing from the image. Cannot enforce SFTP_CHROOT=true."
  fi

  # Fast-fail if the runtime does not grant CAP_SYS_CHROOT.
  if ! chroot / /bin/sh -c 'exit 0' >/dev/null 2>&1; then
    fail "SFTP_CHROOT=true but CAP_SYS_CHROOT is unavailable. Add --cap-add SYS_CHROOT (Compose: cap_add: [SYS_CHROOT]) or set SFTP_CHROOT=false."
  fi
}

prepare_runtime_dir() {
  mkdir -p "$RUNTIME_DIR" || fail "Cannot create runtime directory ${RUNTIME_DIR}."
  chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
}

setup_nss_wrapper() {
  nss_lib=""
  for candidate in /usr/lib/libnss_wrapper.so /lib/libnss_wrapper.so; do
    if [ -f "$candidate" ]; then
      nss_lib="$candidate"
      break
    fi
  done

  [ -n "$nss_lib" ] || fail "libnss_wrapper.so not found. Install nss_wrapper in the image."

  awk -F: -v user="$SFTP_USER" '$1 != user { print }' /etc/passwd > "$NSS_PASSWD_FILE" || \
    fail "Failed to prepare NSS passwd file."
  printf '%s:x:%s:%s::%s:/bin/sh\n' "$SFTP_USER" "$CURRENT_UID" "$CURRENT_GID" "$SFTP_HOME" >> "$NSS_PASSWD_FILE"

  awk -F: -v grp="$SFTP_GROUP" '$1 != grp { print }' /etc/group > "$NSS_GROUP_FILE" || \
    fail "Failed to prepare NSS group file."
  printf '%s:x:%s:%s\n' "$SFTP_GROUP" "$CURRENT_GID" "$SFTP_USER" >> "$NSS_GROUP_FILE"

  chmod 600 "$NSS_PASSWD_FILE" "$NSS_GROUP_FILE" 2>/dev/null || true

  export NSS_WRAPPER_PASSWD="$NSS_PASSWD_FILE"
  export NSS_WRAPPER_GROUP="$NSS_GROUP_FILE"

  if [ -n "${LD_PRELOAD:-}" ]; then
    LD_PRELOAD="${nss_lib}:${LD_PRELOAD}"
  else
    LD_PRELOAD="$nss_lib"
  fi
  export LD_PRELOAD
}

ensure_host_keypair() {
  key_type="$1"
  key_file="${HOST_KEY_PERSIST}/ssh_host_${key_type}_key"
  pub_file="${key_file}.pub"
  generated=false

  if [ -f "$key_file" ]; then
    [ -r "$key_file" ] || fail "Cannot read persisted host key ${key_file}."
    if [ ! -f "$pub_file" ]; then
      if [ -w "$HOST_KEY_PERSIST" ]; then
        ssh-keygen -y -f "$key_file" > "$pub_file" 2>/dev/null || \
          fail "Failed to derive host public key from ${key_file}."
      else
        echo "WARNING: Missing ${pub_file}, but HOST_KEY_DIR is read-only. Continuing with private key only."
      fi
    fi
  else
    [ -w "$HOST_KEY_PERSIST" ] || \
      fail "Missing host key ${key_file}, and HOST_KEY_DIR is not writable."

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

  if [ -w "$HOST_KEY_PERSIST" ]; then
    chmod 600 "$key_file" 2>/dev/null || true
    if [ -f "$pub_file" ]; then
      chmod 644 "$pub_file" 2>/dev/null || true
    fi
  fi

  if [ "$generated" = true ]; then
    GENERATED_HOST_KEYS=$((GENERATED_HOST_KEYS + 1))
  fi
}

prepare_host_keys() {
  requested_host_key_dir="$HOST_KEY_PERSIST"

  mkdir -p "$requested_host_key_dir" || \
    fail "Cannot create HOST_KEY_DIR at ${requested_host_key_dir}. Check mount permissions."

  # Backward-compatible upgrade path:
  # if legacy root-owned host keys are unreadable/unwritable in rootless mode,
  # fall back to runtime-only host keys so startup still succeeds.
  if [ ! -w "$requested_host_key_dir" ]; then
    all_private_keys_readable=true
    for key_type in rsa ecdsa ed25519; do
      key_file="${requested_host_key_dir}/ssh_host_${key_type}_key"
      if [ ! -r "$key_file" ]; then
        all_private_keys_readable=false
        break
      fi
    done

    if [ "$all_private_keys_readable" = false ]; then
      fallback_host_key_dir="${RUNTIME_DIR}/host_keys"
      echo "WARNING: HOST_KEY_DIR ${requested_host_key_dir} is not writable/readable enough for managed host keys."
      echo "WARNING: Falling back to runtime host keys at ${fallback_host_key_dir} (non-persistent)."
      echo "WARNING: To restore persistent host keys, chown the host-key volume to uid:gid ${CURRENT_UID}:${CURRENT_GID}."
      HOST_KEY_PERSIST="$fallback_host_key_dir"
      mkdir -p "$HOST_KEY_PERSIST" || \
        fail "Cannot create runtime host key directory at ${HOST_KEY_PERSIST}."
    fi
  fi

  mkdir -p "$HOST_KEY_PERSIST" || \
    fail "Cannot create HOST_KEY_DIR at ${HOST_KEY_PERSIST}. Check mount permissions."

  chmod 700 "$HOST_KEY_PERSIST" 2>/dev/null || true

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
    [ -w "$PERSIST_SSH" ] || \
      fail "SSH_KEY_DIR is read-only and ${AUTH_KEYS} is missing. Mount writable or pre-provision authorized_keys."
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
    echo "  sftp -i sftp_key -P <mapped_port> ${SFTP_USER}@<host>"
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

  chmod 700 "$PERSIST_SSH" 2>/dev/null || true
  chmod 600 "$AUTH_KEYS" 2>/dev/null || true
  chmod 600 "$KEY_FILE" 2>/dev/null || true
  chmod 644 "$PUB_KEY_FILE" 2>/dev/null || true

  cp "$AUTH_KEYS" "$RUNTIME_AUTH_KEYS" || fail "Cannot copy authorized_keys into runtime directory."
  chmod 600 "$RUNTIME_AUTH_KEYS" || fail "Failed to set permissions on runtime authorized_keys."
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
      /.ssh|/.ssh/*|/.config|/.config/*|/.host_keys|/.host_keys/*|/host_keys|/host_keys/*|/keys|/keys/*)
        fail "Refusing to expose key-management path '${dir}' over SFTP."
        ;;
    esac

    path="${SFTP_HOME}${dir}"
    [ -d "$path" ] || fail "SFTP path ${path} does not exist. Create or mount it before startup."
    [ -r "$path" ] || fail "SFTP path ${path} is not readable."
    [ -x "$path" ] || fail "SFTP path ${path} is not traversable."
    if [ ! -w "$path" ]; then
      echo "WARNING: SFTP path ${path} is not writable by uid ${CURRENT_UID}."
    fi

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
  auth_keys_file_escaped="$(escape_sed "$RUNTIME_AUTH_KEYS")"
  port_escaped="$(escape_sed "$SFTP_PORT")"
  sftp_user_escaped="$(escape_sed "$SFTP_USER")"
  pid_file_escaped="$(escape_sed "${RUNTIME_DIR}/sshd.pid")"
  sftp_home_escaped="$(escape_sed "$SFTP_HOME")"

  sed \
    -e "s|__PORT__|${port_escaped}|g" \
    -e "s|__HOST_KEY_DIR__|${host_key_dir_escaped}|g" \
    -e "s|__AUTHORIZED_KEYS_FILE__|${auth_keys_file_escaped}|g" \
    -e "s|__SFTP_USER__|${sftp_user_escaped}|g" \
    -e "s|__PID_FILE__|${pid_file_escaped}|g" \
    -e "s|__SFTP_HOME__|${sftp_home_escaped}|g" \
    "$SSHD_TEMPLATE" > "$RUNTIME_SSHD_CONFIG" || fail "Failed to render sshd config."

  if [ "$CHROOT_ENABLED" != "true" ]; then
    sed -i '/^[[:space:]]*ChrootDirectory[[:space:]]/d' "$RUNTIME_SSHD_CONFIG" || \
      fail "Failed to disable ChrootDirectory in sshd config."
  fi

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
  CHROOT_ENABLED="$(parse_bool "$SFTP_CHROOT" "SFTP_CHROOT")"
  PERSIST_SSH="$(resolve_container_path "$PERSIST_SSH" "SSH_KEY_DIR")"
  HOST_KEY_PERSIST="$(resolve_container_path "$HOST_KEY_PERSIST" "HOST_KEY_DIR")"

  validate_runtime_identity
  validate_security_paths
  if [ "$CHROOT_ENABLED" = "true" ]; then
    echo "Chroot mode: enabled (recommended)."
    validate_chroot_layout
    validate_chroot_capability
  else
    echo "WARNING: Chroot mode is disabled."
    echo "WARNING: Authenticated SFTP users can browse any readable path in the container and mounted volumes."
  fi
  prepare_runtime_dir
  setup_nss_wrapper
  prepare_host_keys
  prepare_auth_keys
  prepare_sftp_paths
  render_sshd_config
  start_sshd
}

main "$@"
