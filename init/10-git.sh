#!/usr/bin/env sh
set -eu

log(){ echo "[git-init] $*"; }

log "start"
log "env: GIT_NAME='${GIT_NAME:-}' GIT_EMAIL='${GIT_EMAIL:-}'"
log "env: GIT_REPOS='${GIT_REPOS:-}'"

# Make 'git config --global' and credential helper write under /config (LSIO user's home)
export HOME=/config

git config --global --add safe.directory /config/workspace
git config --global --add safe.directory /config/workspace/*

BASE="${GIT_BASE_DIR:-/config/workspace}"
mkdir -p "$BASE" || true
chown -R "${PUID:-1000}:${PGID:-1000}" "$BASE" || true

# Git identity + sane defaults
[ -n "${GIT_NAME:-}" ]  && git config --global user.name  "$GIT_NAME"  || true
[ -n "${GIT_EMAIL:-}" ] && git config --global user.email "$GIT_EMAIL" || true
git config --global init.defaultBranch main || true
git config --global pull.ff only || true
git config --global advice.detachedHead false || true

# SSH Key Generation and Persistence
SSH_DIR="/root/.ssh"
KEY_NAME="id_rsa"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

# Ensure the SSH directory is owned by the correct user
log "Ensuring the correct ownership for the SSH directory"
mkdir -p "$SSH_DIR"
chown -R "${PUID:-1000}:${PGID:-1000}" "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
  log "Generating new SSH key pair"
  ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY_PATH" -N "" -C "${GIT_EMAIL:-git@github.com}" # Generate key with no passphrase
  chmod 600 "$PRIVATE_KEY_PATH"
  chmod 644 "$PUBLIC_KEY_PATH"
  
  log "SSH key pair generated"

  chmod 600 /root/.ssh/id_rsa
  chmod 644 /root/.ssh/id_rsa.pub

  # Save SSH public key and prepare to upload to GitHub
  SSH_PUBLIC_KEY=$(cat "$PUBLIC_KEY_PATH")

  log "SSH Public Key:"
  log "$SSH_PUBLIC_KEY"

  # Automatically add GitHub's SSH key to known hosts to avoid "Host key verification failed"
  ssh-keyscan github.com >> /root/.ssh/known_hosts
  chmod 644 /root/.ssh/known_hosts

  # Upload the SSH public key to GitHub
  if [ -n "${GH_PAT:-}" ]; then
    log "Adding SSH key to GitHub..."
    RESPONSE=$(curl -X POST -H "Authorization: token ${GH_PAT}" \
      -d '{"title": "Docker SSH Key", "key": "'"${SSH_PUBLIC_KEY}"'"}' \
      "https://api.github.com/user/keys")

    log "GitHub Response: $RESPONSE"
    if echo "$RESPONSE" | grep -q '"id"'; then
      log "SSH key added successfully"
    else
      log "Failed to add SSH key to GitHub: $RESPONSE"
    fi
  else
    log "GH_PAT not set; SSH key was not added to GitHub"
  fi
else
  log "SSH key already exists, skipping generation."
fi

# Ensure Git is using the correct SSH key
git config --global core.sshCommand "ssh -i /root/.ssh/id_rsa -F /dev/null"

# Clone repositories using SSH
clone_one() {
  spec="$1"
  [ -n "$spec" ] || return 0

  # trim spaces
  spec=$(echo "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$spec" ] || return 0

  # parse optional '#branch'
  repo="$spec"; branch=""
  case "$spec" in
    *'#'*) branch="${spec#*#}"; repo="${spec%%#*}";;
  esac

  # build URL + dest name (using SSH)
  case "$repo" in
    *"git@github.com:"*)
      url="$repo"
      name="$(basename "$repo" .git)"
      owner_repo="$repo"
      ;;
    */*)
      name="$(basename "$repo")"
      url="git@github.com:${repo}.git"
      owner_repo="$repo"
      ;;
    *)
      log "skip invalid spec: $spec"
      return 0
      ;;
  esac

  dest="${BASE}/${name}"
  safe_url="$(echo "$url" | sed -E 's#(git@github\.com:)[^@]+@#\1***@#')"

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

# Split comma-separated GIT_REPOS and clone
if [ -n "${GIT_REPOS:-}" ]; then
  IFS=,; set -- $GIT_REPOS; unset IFS
  for spec in "$@"; do clone_one "$spec"; done
else
  log "GIT_REPOS is empty; nothing to clone"
fi

log "done"
