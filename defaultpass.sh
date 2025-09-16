#!/usr/bin/env sh
set -eu

log(){ echo "[defaultpass] $*"; }

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
export HOME="${HOME:-/config}"

# Prefer the same path code-server will read at boot
HASH_FILE_PATH="${FILE__HASHED_PASSWORD:-$HOME/.gitstrap/codepass.hash}"

DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"

# Only act if DEFAULT_PASSWORD is provided
[ -n "$DEFAULT_PASSWORD" ] || { log "no DEFAULT_PASSWORD; skipping"; exit 0; }

# If a hash file already exists, never overwrite it
if [ -s "$HASH_FILE_PATH" ]; then
  log "hash already present at $HASH_FILE_PATH; leaving as-is"
  exit 0
fi

# Ensure argon2 is available (installed by the LinuxServer 'universal-package-install' mod)
# We’ll wait up to ~20s in case the mod runs just before us.
try=0
until command -v argon2 >/dev/null 2>&1; do
  try=$((try+1))
  [ $try -ge 20 ] && { log "ERROR: argon2 CLI not found; cannot set default hash"; exit 0; }
  sleep 1
done

# Make sure the destination directory exists
dir="$(dirname "$HASH_FILE_PATH")"
mkdir -p "$dir"
chown "$PUID:$PGID" "$dir" 2>/dev/null || true

# Generate Argon2id PHC string and write it (no trailing newline)
salt="$(head -c16 /dev/urandom | base64)"
hash="$(printf '%s' "$DEFAULT_PASSWORD" | argon2 "$salt" -id -e)"

printf '%s' "$hash" > "$HASH_FILE_PATH"
chmod 644 "$HASH_FILE_PATH" || true
chown "$PUID:$PGID" "$HASH_FILE_PATH" 2>/dev/null || true

head="$(printf '%s' "$hash" | cut -c1-24)"
log "wrote initial Argon2 hash to $HASH_FILE_PATH (head=${head}...)"
