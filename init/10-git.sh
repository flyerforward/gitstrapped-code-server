#!/usr/bin/env sh
set -eu

log(){ echo "[git-init] $*"; }

log "start"
log "env: GIT_NAME='${GIT_NAME:-}' GIT_EMAIL='${GIT_EMAIL:-}'"
log "env: GIT_REPOS='${GIT_REPOS:-}'"

# LSIO 'abc' user's HOME is /config; ensure git writes configs there.
export HOME=/config

# -------- workspace & git defaults --------
BASE="${GIT_BASE_DIR:-/config/workspace}"
mkdir -p "$BASE" || true
chown -R "${PUID:-1000}:${PGID:-1000}" "$BASE" || true

[ -n "${GIT_NAME:-}" ]  && git config --global user.name  "$GIT_NAME"  || true
[ -n "${GIT_EMAIL:-}" ] && git config --global user.email "$GIT_EMAIL" || true
git config --global init.defaultBranch main || true
git config --global pull.ff only || true
git config --global advice.detachedHead false || true
# Mark workspace as safe (avoids 'dubious ownership' warnings)
git config --global --add safe.directory "$BASE"
git config --global --add safe.directory "$BASE/*"

# -------- SSH under /config/.ssh (non-root) --------
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

umask 077
mkdir -p "$SSH_DIR"
chown -R "${PUID:-1000}:${PGID:-1000}" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate key if missing
if [ ! -f "$PRIVATE_KEY_PATH" ]; then
  log "Generating SSH key at $PRIVATE_KEY_PATH"
  ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -C "${GIT_EMAIL:-git@github.com}"
  chmod 600 "$PRIVATE_KEY_PATH"
  chmod 644 "$PUBLIC_KEY_PATH"
else
  log "SSH key already exists; skipping generation"
fi

# known_hosts + ssh options
touch "$SSH_DIR/known_hosts"
chmod 644 "$SSH_DIR/known_hosts"
chown "${PUID:-1000}:${PGID:-1000}" "$SSH_DIR/known_hosts"

# Pre-seed GitHub host key if ssh-keyscan is available (best-effort)
if command -v ssh-keyscan >/dev/null 2>&1; then
  if ! grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
    ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  fi
fi

# Force git/ssh to use our key + known_hosts, with safe first-connection behavior
git config --global core.sshCommand \
  "ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"

# -------- Always-on GitHub upload (idempotent) --------
# Requires a PAT with permission to create user SSH keys (classic PAT scope: admin:public_key)
if [ -n "${GH_PAT:-}" ]; then
  # Normalize local key to "type key" (strip comment) for reliable comparison
  LOCAL_KEY="$(awk '{print $1" "$2}' "$PUBLIC_KEY_PATH")"
  TITLE="${GH_KEY_TITLE:-Docker SSH Key}"

  log "Checking if SSH key already exists on GitHub..."
  KEYS_JSON="$(curl -sS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/keys || true)"

  if echo "$KEYS_JSON" | grep -q "\"key\": *\"$LOCAL_KEY\""; then
    log "SSH key already present on GitHub; skipping upload"
  else
    log "Adding SSH key to GitHub via API..."
    RESP="$(curl -sS -X POST \
      -H "Authorization: token ${GH_PAT}" \
      -H "Accept: application/vnd.github+json" \
      -d "{\"title\":\"$TITLE\",\"key\":\"$LOCAL_KEY\"}" \
      https://api.github.com/user/keys || true)"
    if echo "$RESP" | grep -q '"id"'; then
      log "SSH key added to GitHub"
    else
      log "Failed to add key: $RESP"
    fi
  fi
else
  log "GH_PAT not set; skipping GitHub key upload"
fi

# Ensure permissions/ownership are solid
chmod 700 "$SSH_DIR"
chmod 600 "$PRIVATE_KEY_PATH" || true
chmod 644 "$PUBLIC_KEY_PATH"  || true
chmod 644 "$SSH_DIR/known_hosts" || true
chown -R "${PUID:-1000}:${PGID:-1000}" "$SSH_DIR"

# -------- clone/pull helper --------
clone_one() {
  spec="$1"
  [ -n "$spec" ] || return 0

  # trim whitespace
  spec=$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$spec" ] || return 0

  # parse optional '#branch'
  repo="$spec"; branch=""
  case "$spec" in
    *'#'*) branch="${spec#*#}"; repo="${spec%%#*}";;
  esac

  # normalize -> SSH URL + target dir name
  case "$repo" in
    *"git@github.com:"*)
      url="$repo"
      name="$(basename "$repo" .git)"
      ;;
    http*://github.com/*|ssh://git@github.com/*)
      name="$(basename "$repo" .git)"
      owner_repo="$(echo "$repo" | sed -E 's#^https?://github\.com/##; s#^ssh://git@github\.com/##')"
      owner_repo="${owner_repo%.git}"
      url="git@github.com:${owner_repo}.git"
      ;;
    */*)
      name="$(basename "$repo")"
      url="git@github.com:${repo}.git"
      ;;
    *)
      log "skip invalid spec: $spec"
      return 0
      ;;
  esac

  dest="${BASE}/${name}"
  safe_url="$(echo "$url" | sed -E 's#(git@github\.com:).*#\1***.git#')"

  if [ -d "$dest/.git" ]; then
    log "pull: ${name}"
    git -C "$dest" fetch --all -p || true
    if [ -n "$branch" ]; then
      git -C "$dest" checkout "$branch" || true
      git -C "$dest" reset --hard "origin/${branch}" || true
    else
      git -C "$dest" pull --ff-only || true
    fi
  else
    log "clone: ${safe_url} -> ${dest} (branch='${branch:-default}')"
    if [ -n "$branch" ]; then
      git clone --branch "$branch" --single-branch "$url" "$dest" || { log "clone failed: $spec"; return 0; }
    else
      git clone "$url" "$dest" || { log "clone failed: $spec"; return 0; }
    fi
  fi

  chown -R "${PUID:-1000}:${PGID:-1000}" "$dest" || true
}

# -------- clone the list --------
if [ -n "${GIT_REPOS:-}" ]; then
  IFS=,; set -- $GIT_REPOS; unset IFS
  for spec in "$@"; do clone_one "$spec"; done
else
  log "GIT_REPOS is empty; nothing to clone"
fi

log "done"
