#!/usr/bin/env sh
set -eu

log(){ echo "[git-init] $*"; }

log "start"
log "env: GIT_NAME='${GIT_NAME:-}' GIT_EMAIL='${GIT_EMAIL:-}'"
log "env: GIT_REPOS='${GIT_REPOS:-}'"

export HOME=/config
umask 022

# -------- workspace --------
BASE="${GIT_BASE_DIR:-/config/workspace}"
mkdir -p "$BASE" || true
chown -R "${PUID:-1000}:${PGID:-1000}" "$BASE" || true
git config --global --add safe.directory "$BASE" || true

# -------- git defaults --------
[ -n "${GIT_NAME:-}" ]  && git config --global user.name  "$GIT_NAME"  || true
[ -n "${GIT_EMAIL:-}" ] && git config --global user.email "$GIT_EMAIL" || true
git config --global init.defaultBranch main || true
git config --global pull.ff only || true
git config --global advice.detachedHead false || true

# -------- SSH --------
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

touch "$SSH_DIR/known_hosts"
chmod 644 "$SSH_DIR/known_hosts"
chown "${PUID:-1000}:${PGID:-1000}" "$SSH_DIR/known_hosts"
if command -v ssh-keyscan >/dev/null 2>&1; then
  grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null || ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
fi

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
    RESP="$(curl -sS -X POST -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" \
      -d "{\"title\":\"$TITLE\",\"key\":\"$LOCAL_KEY\"}" https://api.github.com/user/keys || true)"
    echo "$RESP" | grep -q '"id"' && log "SSH key added to GitHub" || log "Failed to add key: $RESP"
  fi
else
  log "GH_PAT not set; skipping GitHub key upload"
fi

# -------- helpers --------
add_safe_dir(){ git config --global --add safe.directory "$1" || true; }

log_perms(){
  p="$1"; command -v namei >/dev/null 2>&1 || return 0
  log "perms for $p:"; namei -mo "$p" 2>/dev/null | sed 's/^/[git-init]   /'
}

repair_repo(){
  dest="$1"; [ -d "$dest/.git" ] || return 0
  log "repair existing repo: $dest"
  chown -R "${PUID:-1000}:${PGID:-1000}" "$dest" || true
  if command -v find >/dev/null 2>&1; then
    find "$dest" -path "$dest/.git" -prune -o -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$dest" -path "$dest/.git" -prune -o -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$dest/.git" -type d -exec chmod 700 {} \; 2>/dev/null || true
    find "$dest/.git" -type f -exec chmod 600 {} \; 2>/dev/null || true
  else
    chmod -R u+rwX,go+rX "$dest" || true
  fi
  for lf in index.lock config.lock HEAD.lock FETCH_HEAD.lock packed-refs.lock shallow.lock; do
    [ -f "$dest/.git/$lf" ] && rm -f "$dest/.git/$lf" || true
  done
  add_safe_dir "$dest"
  log_perms "$dest"
}

normalize_spec(){
  spec="$1"; repo="$spec"; branch=""
  case "$spec" in *'#'*) branch="${spec#*#}"; repo="${spec%%#*}";; esac
  case "$repo" in
    *"git@github.com:"*) url="$repo"; name="$(basename "$repo" .git)";;
    http*://github.com/*|ssh://git@github.com/*)
      name="$(basename "$repo" .git)"
      owner_repo="$(echo "$repo" | sed -E 's#^https?://github\.com/##; s#^ssh://git@github\.com/##')"
      owner_repo="${owner_repo%.git}"
      url="git@github.com:${owner_repo}.git"
      ;;
    */*) name="$(basename "$repo")"; url="git@github.com:${repo}.git";;
    *) url=""; name="";;
  esac
  echo "$url|$name|$branch"
}

clone_one(){
  spec="$1"; [ -n "$spec" ] || return 0
  spec="$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; [ -n "$spec" ] || return 0

  IFS='|' read -r url name branch <<EOF
$(normalize_spec "$spec")
EOF
  if [ -z "$url" ] || [ -z "$name" ]; then log "skip invalid spec: $spec"; return 0; fi

  dest="${BASE}/${name}"; safe_url="$(echo "$url" | sed -E 's#(git@github\.com:).*#\1***.git#')"

  [ -d "$dest" ] && repair_repo "$dest"

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
    repair_repo "$dest"
  fi

  # prove git sees it
  git -C "$dest" rev-parse --is-inside-work-tree 2>&1 | sed 's/^/[git-init]   /' || true
  git -C "$dest" rev-parse --git-dir             2>&1 | sed 's/^/[git-init]   /' || true
}

# -------- Phase 0: repair any repos already in the volume --------
if [ -d "$BASE" ]; then
  for d in "$BASE"/*; do
    [ -d "$d/.git" ] || continue
    repair_repo "$d"
  done
fi

# -------- Phase 1: process desired repos --------
REPO_DIRS=""
if [ -n "${GIT_REPOS:-}" ]; then
  IFS=,; set -- $GIT_REPOS; unset IFS
  for spec in "$@"; do
    spec="$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$spec" ] || {
      name="$(basename "$(echo "$spec" | sed 's/#.*$//')" .git)"
      [ -n "$name" ] || name="repo"
      REPO_DIRS="$REPO_DIRS $name"
      clone_one "$spec"
    }
  done
else
  log "GIT_REPOS is empty; nothing to clone"
fi

# -------- Phase 2: write a multi-root workspace file --------
# This makes both repos show up in Source Control when opening this file.
WS_FILE="$BASE/_dev.code-workspace"
{
  echo '{'
  echo '  "folders": ['
  first=1
  for n in $REPO_DIRS; do
    [ $first -eq 0 ] && echo '    ,'
    echo "    { \"path\": \"./$n\" }"
    first=0
  done
  echo '  ],'
  echo '  "settings": {'
  echo '    "git.autoRepositoryDetection": true,'
  echo '    "git.repositoryScanMaxDepth": 4,'
  echo '    "git.openRepositoryInParentFolders": "always",'
  echo '    "security.workspace.trust.enabled": false'
  echo '  }'
  echo '}'
} > "$WS_FILE"
chown "${PUID:-1000}:${PGID:-1000}" "$WS_FILE"
chmod 644 "$WS_FILE"
log "wrote workspace: $WS_FILE"

log "done"
