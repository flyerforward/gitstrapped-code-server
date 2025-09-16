#!/usr/bin/env sh
set -eu

log(){ echo "[defaultpass] $*"; }

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
export HOME="${HOME:-/config}"

# Use the same file code-server will read at boot
HASH_FILE_PATH="${FILE__HASHED_PASSWORD:-$HOME/.gitstrap/codepass.hash}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"

# Only act if DEFAULT_PASSWORD is provided
[ -n "$DEFAULT_PASSWORD" ] || { log "no DEFAULT_PASSWORD; skipping"; exit 0; }

# If a hash file already exists, never overwrite it
if [ -s "$HASH_FILE_PATH" ]; then
  log "hash already present at $HASH_FILE_PATH; leaving as-is"
  exit 0
fi

# Wait for argon2 (installed by the LinuxServer 'universal-package-install' mod)
tries=0
until command -v argon2 >/dev/null 2>&1; do
  tries=$((tries+1))
  [ $tries -ge 20 ] && { log "ERROR: argon2 CLI not found; cannot set default hash"; exit 0; }
  sleep 1
done

# Ensure destination directory exists
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
log "first-boot: requesting supervised shutdown so code-server restarts with auth enabled"

# Immediately stop s6 so Docker restarts the container; on the next boot,
# env-init will find FILE__HASHED_PASSWORD and enable auth.
if command -v s6-svscanctl >/dev/null 2>&1; then
  s6-svscanctl -t /run/s6 || true
else
  kill -TERM 1 || true
fi

# Supervisor is exiting; return success
exit 0
