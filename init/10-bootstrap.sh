#!/usr/bin/env sh
set -eu

log(){ echo "[bootstrap] $*"; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

# ---- constants / paths
export HOME=/config               # linuxserver 'abc' home
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

USER_DIR="/config/.local/share/code-server/User"
TASKS_JSON="$USER_DIR/tasks.json"
KEYB_JSON="$USER_DIR/keybindings.json"

BASE="${GIT_BASE_DIR:-/config/workspace}"
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

LOCK_DIR="/run/bootstrap"
LOCK_FILE="$LOCK_DIR/autorun.lock"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

# ---- smart install/merge of Task + Keybinding
install_user_assets() {
  mkdir -p "$USER_DIR"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

  TASK_OBJ="$TMPD/task.json"
  INPUTS_ARR="$TMPD/inputs.json"
  KB_OBJ="$TMPD/keybinding.json"

  # The Task calls THIS script so palette/shortcut runs the same logic
  cat >"$TASK_OBJ" <<'JSON'
{
  "label": "Bootstrap GitHub Workspace",
  "type": "shell",
  "command": "sh",
  "args": ["/custom-cont-init.d/10-bootstrap.sh"],
  "options": {
    "env": {
      "GH_USER": "${input:gh_user}",
      "GH_PAT": "${input:gh_pat}",
      "GIT_EMAIL": "${input:git_email}",
      "GIT_NAME": "${input:git_name}",
      "GIT_REPOS": "${input:git_repos}"
    }
  },
  "problemMatcher": []
}
JSON

  cat >"$INPUTS_ARR" <<'JSON'
[
  { "id": "gh_user",   "type": "promptString", "description": "GitHub username (required)", "default": "${env:GH_USER}" },
  { "id": "gh_pat",    "type": "promptString", "description": "GitHub PAT (classic; scopes: user:email, admin:public_key)", "password": true },
  { "id": "git_email", "type": "promptString", "description": "Git email (optional; leave empty to auto-detect)", "default": "" },
  { "id": "git_name",  "type": "promptString", "description": "Git name (optional; default = GH_USER)", "default": "${env:GIT_NAME}" },
  { "id": "git_repos", "type": "promptString", "description": "Repos to clone (comma-separated owner/repo[#branch] or URLs)", "default": "${env:GIT_REPOS}" }
]
JSON

  # Safe shortcut unlikely to conflict with browser/VS Code
  cat >"$KB_OBJ" <<'JSON'
{
  "key": "ctrl+alt+g",
  "command": "workbench.action.tasks.runTask",
  "args": "Bootstrap GitHub Workspace",
  "when": "editorTextFocus"
}
JSON

  # Try precise merge with jq; otherwise create-only
  if command -v jq >/dev/null 2>&1; then
    # tasks.json
    if [ -f "$TASKS_JSON" ]; then
      tmp_out="$TMPD/tasks.out.json"
      jq \
        --slurpfile newtask "$TASK_OBJ" \
        --slurpfile newinputs "$INPUTS_ARR" '
          ( . // {} ) as $root
          | ($root.tasks // []) as $tasks
          | ($root.inputs // []) as $inputs
          | $root
          | .version = ( .version // "2.0.0" )
          | .tasks = (
              ($tasks | map(select(.label != $newtask[0].label)))
              + [ $newtask[0] ]
            )
          | .inputs = (
              reduce $newinputs[0][] as $ni (
                ($inputs // []);
                ( map(select(.id != $ni.id)) + [ $ni ] )
              )
            )
        ' "$TASKS_JSON" > "$tmp_out" && mv "$tmp_out" "$TASKS_JSON"
      log "Merged Bootstrap task into user tasks.json"
    else
      tmp_out="$TMPD/tasks.out.json"
      jq --null-input \
        --slurpfile newtask "$TASK_OBJ" \
        --slurpfile newinputs "$INPUTS_ARR" '
          { "version":"2.0.0", "tasks":[ $newtask[0] ], "inputs": $newinputs[0] }
        ' > "$tmp_out" && mv "$tmp_out" "$TASKS_JSON"
      log "Created user tasks.json with Bootstrap task"
    fi
    chown "$PUID:$PGID" "$TASKS_JSON"

    # keybindings.json
    if [ -f "$KEYB_JSON" ]; then
      tmp_out="$TMPD/keybindings.out.json"
      jq \
        --slurpfile kb "$KB_OBJ" '
          ( . // [] ) as $arr
          | ( $arr | map(select(.command != $kb[0].command or .args != $kb[0].args)) )
            + [ $kb[0] ]
        ' "$KEYB_JSON" > "$tmp_out" && mv "$tmp_out" "$KEYB_JSON"
      log "Merged Bootstrap keybinding into user keybindings.json"
    else
      cp "$KB_OBJ" "$KEYB_JSON"
      log "Created user keybindings.json with Bootstrap keybinding"
    fi
    chown "$PUID:$PGID" "$KEYB_JSON"

  else
    # No jq: only create fresh files; never overwrite existing
    if [ ! -f "$TASKS_JSON" ]; then
      cat > "$TASKS_JSON" <<'JSON'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Bootstrap GitHub Workspace",
      "type": "shell",
      "command": "sh",
      "args": ["/custom-cont-init.d/10-bootstrap.sh"],
      "options": {
        "env": {
          "GH_USER": "${input:gh_user}",
          "GH_PAT": "${input:gh_pat}",
          "GIT_EMAIL": "${input:git_email}",
          "GIT_NAME": "${input:git_name}",
          "GIT_REPOS": "${input:git_repos}"
        }
      },
      "problemMatcher": []
    }
  ],
  "inputs": [
    { "id": "gh_user", "type": "promptString", "description": "GitHub username (required)", "default": "${env:GH_USER}" },
    { "id": "gh_pat",  "type": "promptString", "description": "GitHub PAT (classic; scopes: user:email, admin:public_key)", "password": true },
    { "id": "git_email", "type": "promptString", "description": "Git email (optional; leave empty to auto-detect)", "default": "" },
    { "id": "git_name", "type": "promptString", "description": "Git name (optional; default = GH_USER)", "default": "${env:GIT_NAME}" },
    { "id": "git_repos", "type": "promptString", "description": "Repos to clone (comma-separated owner/repo[#branch] or URLs)", "default": "${env:GIT_REPOS}" }
  ]
}
JSON
      chown "$PUID:$PGID" "$TASKS_JSON"
      log "Installed user tasks.json (jq not found; created minimal file)"
    else
      log "WARNING: jq not found; tasks.json exists → skipping merge to preserve user customizations."
    fi

    if [ ! -f "$KEYB_JSON" ]; then
      cat > "$KEYB_JSON" <<'JSON'
[
  {
    "key": "ctrl+alt+g",
    "command": "workbench.action.tasks.runTask",
    "args": "Bootstrap GitHub Workspace",
    "when": "editorTextFocus"
  }
]
JSON
      chown "$PUID:$PGID" "$KEYB_JSON"
      log "Installed user keybindings.json (jq not found; created minimal file)"
    else
      log "WARNING: jq not found; keybindings.json exists → skipping merge to preserve user customizations."
    fi
  fi
}

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

do_bootstrap(){
  : "${GH_USER:?GH_USER is required}"
  : "${GH_PAT:?GH_PAT is required}"

  GIT_NAME="${GIT_NAME:-$GH_USER}"
  GIT_REPOS="${GIT_REPOS:-}"

  log "bootstrap: user=$GH_USER, name=$GIT_NAME, base=$BASE"
  mkdir -p "$BASE" && chown -R "$PUID:$PGID" "$BASE" || true

  git config --global init.defaultBranch main || true
  git config --global pull.ff only || true
  git config --global advice.detachedHead false || true
  git config --global --add safe.directory "$BASE" || true
  git config --global --add safe.directory "$BASE/*" || true
  git config --global user.name "$GIT_NAME" || true

  if [ -z "${GIT_EMAIL:-}" ]; then
    GIT_EMAIL="$(resolve_email || true)"
  fi
  git config --global user.email "$GIT_EMAIL" || true
  log "identity: $GIT_NAME <$GIT_EMAIL>"

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

  if [ -n "${GIT_REPOS:-}" ]; then
    IFS=,; set -- $GIT_REPOS; unset IFS
    for spec in "$@"; do clone_one "$spec"; done
  else
    log "GIT_REPOS empty; skip clone"
  fi

  log "bootstrap done"
}

# ---- run
install_user_assets

if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ]; then
  if [ ! -f "$LOCK_FILE" ]; then
    touch "$LOCK_FILE" 2>/dev/null || true
    log "env present and no lock → running bootstrap"
    do_bootstrap || true
  else
    log "autorun lock present → skipping duplicate bootstrap this start"
  fi
else
  log "GH_USER/GH_PAT missing → skip autorun (run via Ctrl+Alt+G or Tasks palette)"
fi
