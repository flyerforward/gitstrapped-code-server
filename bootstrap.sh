#!/usr/bin/env sh
set -eu

log(){ echo "[bootstrap] $*"; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

# ---- Inputs (from env) ----
: "${GH_USER:?GH_USER is required}"
: "${GH_PAT:?GH_PAT is required}"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
BASE="${GIT_BASE_DIR:-/config/workspace}"
GIT_NAME="${GIT_NAME:-$GH_USER}"         # default to GH_USER if not provided
GIT_REPOS="${GIT_REPOS:-}"               # optional
export HOME=/config                      # LSIO abc home

log "user=$GH_USER, name=$GIT_NAME, base=$BASE"

# Workspace + git defaults
mkdir -p "$BASE" && chown -R "$PUID:$PGID" "$BASE" || true
git config --global init.defaultBranch main || true
git config --global pull.ff only || true
git config --global advice.detachedHead false || true
git config --global --add safe.directory "$BASE" || true
git config --global --add safe.directory "$BASE/*" || true
git config --global user.name "$GIT_NAME" || true

# -------- Resolve email (only if GIT_EMAIL not set) --------
resolve_email(){
  EMAILS="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/emails || true)"
  PRIMARY="$(printf "%s" "$EMAILS" | awk -F'"' '/"email":/ {e=$4} /"primary": *true/ {print e; exit}')"
  [ -n "${PRIMARY:-}" ] && { echo "$PRIMARY"; return; }
  VERIFIED="$(printf "%s" "$EMAILS" | awk -F'"' '/"email":/ {e=$4} /"verified": *true/ {print e; exit}')"
  [ -n "${VERIFIED:-}" ] && { echo "$VERIFIED"; return; }
  PUB_JSON="$(curl -fsS -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GH_USER}" || true)"
  PUB_EMAIL="$(printf "%s" "$PUB_JSON" | awk -F'"' '/"email":/ {print $4; exit}')"
  [ -n "${PUB_EMAIL:-}" ] && [ "$PUB_EMAIL" != "null" ] && { echo "$PUB_EMAIL"; return; }
  echo "${GH_USER}@users.noreply.github.com"
}

if [ -z "${GIT_EMAIL:-}" ]; then
  GIT_EMAIL="$(resolve_email || true)"
fi
git config --global user.email "$GIT_EMAIL" || true
log "identity: $GIT_NAME <$GIT_EMAIL>"

# -------- SSH in /config/.ssh --------
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

umask 077
mkdir -p "$SSH_DIR" && chown -R "$PUID:$PGID" "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
  log "Generating SSH key"
  ssh-keygen -t ed25519 -f "$PRIVATE_KEY_PATH" -N "" -C "${GIT_EMAIL:-git@github.com}"
  chmod 600 "$PRIVATE_KEY_PATH"; chmod 644 "$PUBLIC_KEY_PATH"
else
  log "SSH key exists; skipping"
fi

touch "$SSH_DIR/known_hosts"
chmod 644 "$SSH_DIR/known_hosts"
chown "$PUID:$PGID" "$SSH_DIR/known_hosts"

if command -v ssh-keyscan >/dev/null 2>&1 && ! grep -q "^github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
  ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
fi

git config --global core.sshCommand \
  "ssh -i $PRIVATE_KEY_PATH -F /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new"

# -------- Upload public key to GitHub (idempotent) --------
if [ -n "${GH_PAT:-}" ]; then
  LOCAL_KEY="$(awk '{print $1" "$2}' "$PUBLIC_KEY_PATH")"
  TITLE="${GH_KEY_TITLE:-Docker SSH Key}"
  KEYS_JSON="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/keys || true)"
  if echo "$KEYS_JSON" | grep -q "\"key\": *\"$LOCAL_KEY\""; then
    log "SSH key already on GitHub"
  else
    log "Uploading SSH key to GitHub"
    RESP="$(curl -fsS -X POST -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" \
      -d "{\"title\":\"$TITLE\",\"key\":\"$LOCAL_KEY\"}" https://api.github.com/user/keys || true)"
    echo "$RESP" | grep -q '"id"' && log "SSH key added" || log "Key upload failed: $(redact "$RESP")"
  fi
fi

# -------- Clone / Pull helper --------
clone_one() {
  spec="$1"; [ -n "$spec" ] || return 0
  spec=$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -n "$spec" ] || return 0
  repo="$spec"; branch=""
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
    *) log "skip invalid spec: $spec"; return 0;;
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
  chown -R "$PUID:$PGID" "$dest" || true
}

if [ -n "$GIT_REPOS" ]; then
  IFS=,; set -- $GIT_REPOS; unset IFS
  for spec in "$@"; do clone_one "$spec"; done
else
  log "GIT_REPOS empty; skip clone"
fi

log "bootstrap done"
