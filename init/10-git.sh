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

# Add base as safe (we'll add each repo path explicitly too)
git config --global --add safe.directory "$BASE" || true

# -------- SSH under /config/.ssh --------
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

umask 077
mkdir -p "$SSH_DIR"
chown -R "${PUID:-1000}:${PGID:-1000}" "$SSH_DIR"
chmod 700 "$SSH_DIR"

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

if command -v ssh-keyscan >/dev/null 2>&1; then
  grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null || ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
fi

# Make both CLI and VS Code extension use the same SSH options
export GIT_SSH_COMMAND="ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"
git config --global core.sshCommand "$GIT_SSH_COMMAND"

# -------- Always-on GitHub upload (idempotent) --------
if [ -n "${GH_PAT:-}" ]; then
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

# -------- helpers --------
add_safe_dir() {
  p="$1"; [ -n "$p" ] || return 0
  git config --global --add safe.directory "$p" || true
}

repair_repo() {
  dest="$1"
  [ -d "$dest/.git" ] || return 0

  # Fix ownership & restrictive perms inside .git
  chown -R "${PUID:-1000}:${PGID:-1000}" "$dest" || true
  # Worktree files: ensure user can read/write/execute dirs
  chmod -R u+rwX "$dest" || true
  # .git internals should be private
  find "$dest/.git" -type d -exec chmod 700 {} \; 2>/dev/null || true
  find "$dest/.git" -type f -exec chmod 600 {} \; 2>/dev/null || true

  # Remove stale lock files that block operations
  for lf in index.lock config.lock HEAD.lock FETCH_HEAD.lock packed-refs.lock shallow.lock; do
    [ -f "$dest/.git/$lf" ] && rm -f "$dest/.git/$lf" || true
  done

  # Add as safe directory
  add_safe_dir "$dest"
}

# Normalize a repo spec into URL + dest name
normalize_spec() {
  spec="$1"
  repo="$spec"; branch=""
  case "$spec" in *'#'*) branch="${spec#*#}"; repo="${spec%%#*}";; esac

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
      url=""; name=""
      ;;
  esac

  echo "$url|$name|$branch"
}

clone_one() {
  spec="$1"
  [ -n "$spec" ] || return 0
  spec="$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$spec" ] || return 0

  IFS='|' read -r url name branch <<EOF
$(normalize_spec "$spec")
EOF

  if [ -z "$url" ] || [ -z "$name" ]; then
    log "skip invalid spec: $spec"
    return 0
  fi

  dest="${BASE}/${name}"
  safe_url="$(echo "$url" | sed -E 's#(git@github\.com:).*#\1***.git#')"

  # If repo dir exists, repair it before using git
  if [ -d "$dest" ]; then
    repair_repo "$dest"
  fi

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
    # After clone, make sure perms/safe are correct
    repair_repo "$dest"
  fi
}

# -------- Phase 0: repair any repos that already exist in the volume --------
# This catches repos not listed in GIT_REPOS but present from older runs too.
if [ -d "$BASE" ]; then
  for d in "$BASE"/*; do
    [ -d "$d/.git" ] || continue
    log "repair existing repo: $d"
    repair_repo "$d"
  done
fi

# -------- Phase 1: process the desired repo list --------
if [ -n "${GIT_REPOS:-}" ]; then
  IFS=,; set -- $GIT_REPOS; unset IFS
  for spec in "$@"; do clone_one "$spec"; done
else
  log "GIT_REPOS is empty; nothing to clone"
fi

log "done"
