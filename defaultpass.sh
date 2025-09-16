#!/usr/bin/env sh
set -eu

log(){ echo "[defaultpass] $*"; }

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
export HOME="${HOME:-/config}"

HASH_FILE_PATH="${FILE__HASHED_PASSWORD:-$HOME/.gitstrap/codepass.hash}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
MARKER="$HOME/.gitstrap/.firstboot-auth-restart"

[ -n "$DEFAULT_PASSWORD" ] || { log "no DEFAULT_PASSWORD; skipping"; exit 0; }

if [ -s "$HASH_FILE_PATH" ]; then
  log "hash already present at $HASH_FILE_PATH; leaving as-is"
  exit 0
fi

# wait for argon2 (installed by LSIO mod)
tries=0
until command -v argon2 >/dev/null 2>&1; do
  tries=$((tries+1))
  [ $tries -ge 20 ] && { log "ERROR: argon2 CLI not found; cannot set default hash"; exit 0; }
  sleep 1
done

dir="$(dirname "$HASH_FILE_PATH")"
mkdir -p "$dir"
chown "$PUID:$PGID" "$dir" 2>/dev/null || true

salt="$(head -c16 /dev/urandom | base64)"
hash="$(printf '%s' "$DEFAULT_PASSWORD" | argon2 "$salt" -id -e)"

printf '%s' "$hash" > "$HASH_FILE_PATH"
chmod 644 "$HASH_FILE_PATH" || true
chown "$PUID:$PGID" "$HASH_FILE_PATH" 2>/dev/null || true

head="$(printf '%s' "$hash" | cut -c1-24)"
log "wrote initial Argon2 hash to $HASH_FILE_PATH (head=${head}...)"

# queue a one-shot restart once s6 services are up
mkdir -p "$(dirname "$MARKER")"
: > "$MARKER"
log "queued first-boot restart via marker: $MARKER"
