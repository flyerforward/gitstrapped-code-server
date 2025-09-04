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

# Force credential helper file in /config
git config --global --unset-all credential.helper || true
git config --global --add credential.helper "store --file /config/.git-credentials"

# Persist token once (optional but convenient for pulls/pushes)
if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ]; then
  CRED="/config/.git-credentials"
  if ! grep -q "github.com" "$CRED" 2>/dev/null; then
    printf "https://%s:%s@github.com\n" "$GH_USER" "$GH_PAT" >> "$CRED"
    chmod 600 "$CRED"
    log "credentials written to $CRED"
  else
    log "credentials already present in $CRED"
  fi
else
  log "GH_USER/GH_PAT not set; private clones/push will fail"
fi

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

  # build URL + dest name
  case "$repo" in
    http*://*)
      url="$repo"
      name="$(basename "$repo" .git)"
      owner_repo="$(echo "$repo" | sed -nE 's#.*github\.com/([^/]+/[^/.]+)(\.git)?$#\1#p')"
      ;;
    */*)
      name="$(basename "$repo")"
      if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ]; then
        url="https://${GH_USER}:${GH_PAT}@github.com/${repo}.git"
      else
        url="https://github.com/${repo}.git"
      fi
      owner_repo="$repo"
      ;;
    *)
      log "skip invalid spec: $spec"
      return 0
      ;;
  esac

  dest="${BASE}/${name}"
  safe_url="$(echo "$url" | sed -E 's#(https://)[^:]+:[^@]+@#\1***:***@#')"

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
    # Reset remote to token-less URL
    if [ -n "${owner_repo:-}" ]; then
      git -C "$dest" remote set-url origin "https://github.com/${owner_repo}.git" || true
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

log "final helper: $(git config --global --get credential.helper || true)"
log "done"
