#!/usr/bin/env sh
set -eu

log(){ echo "[bootstrap] $*"; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

# ---------------------------
# CONSTANTS / PATHS
# ---------------------------
export HOME=/config
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

USER_DIR="/config/data/User"
TASKS_PATH="$USER_DIR/tasks.json"
KEYB_PATH="$USER_DIR/keybindings.json"
SETTINGS_PATH="$USER_DIR/settings.json"

REPO_SETTINGS_SRC="/config/bootstrap/bootstrap-settings.json"

STATE_DIR="/config/.bootstrap"
BASE="${GIT_BASE_DIR:-/config/workspace}"
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

LOCK_DIR="/run/bootstrap"
LOCK_FILE="$LOCK_DIR/autorun.lock"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

# ---------------------------
# UTILS
# ---------------------------
ensure_dir(){ mkdir -p "$1"; chown -R "$PUID:$PGID" "$1" 2>/dev/null || true; }
write_file(){ printf "%s" "$2" > "$1"; chown "$PUID:$PGID" "$1" 2>/dev/null || true; }

# ---------------------------
# DESIRED TASK + KEYBINDING (with __name)
# ---------------------------
TASK_JSON='{
  "__name": "Bootstrap GitHub Workspace",
  "label": "Bootstrap GitHub Workspace",
  "type": "shell",
  "command": "sh",
  "args": ["/custom-cont-init.d/10-bootstrap.sh", "force"],
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
}'
INPUTS_JSON='[
  { "id": "gh_user",   "type": "promptString", "description": "GitHub username (required)", "default": "${env:GH_USER}" },
  { "id": "gh_pat",    "type": "promptString", "description": "GitHub PAT (classic; scopes: user:email, admin:public_key)", "password": true },
  { "id": "git_email", "type": "promptString", "description": "Git email (optional; leave empty to auto-detect)", "default": "" },
  { "id": "git_name",  "type": "promptString", "description": "Git name (optional; default = GH_USER)", "default": "${env:GIT_NAME}" },
  { "id": "git_repos", "type": "promptString", "description": "Repos to clone (owner/repo[#branch] or URLs, comma-separated)", "default": "${env:GIT_REPOS}" }
]'
KEYB_JSON='{
  "__name": "Bootstrap GitHub Workspace",
  "key": "ctrl+alt+g",
  "command": "workbench.action.tasks.runTask",
  "args": "Bootstrap GitHub Workspace"
}'

# ---------------------------
# INSTALL TASKS (bootstrap-preserve + ensure present)
# ---------------------------
install_tasks() {
  ensure_dir "$USER_DIR"

  # If missing, write fresh file with our task+inputs.
  if [ ! -f "$TASKS_PATH" ]; then
    write_file "$TASKS_PATH" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)"
    log "created tasks.json → $TASKS_PATH"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; tasks.json exists → skipping merge."
    return 0
  fi

  tf="$(mktemp -d)"
  printf "%s" "$TASK_JSON"   > "$tf/desired_task.json"
  printf "%s" "$INPUTS_JSON" > "$tf/desired_inputs.json"

  cat > "$tf/filter_tasks.jq" <<'JQ'
def ensureObj(o): if (o|type)=="object" then o else {} end;
def ensureArr(a): if (a|type)=="array"  then a else [] end;

def preserve_merge(old; desired):
  ((old["bootstrap-preserve"] // []) | map(select(type=="string"))) as $keep
  | (desired + {}) as $out
  | reduce $keep[] as $k (
      $out;
      if ($k == "__name" or $k == "bootstrap-preserve") then .
      elif (old | has($k)) then .[$k] = old[$k] else . end
    )
  | if ((old["bootstrap-preserve"] | type) == "array")
      then .["bootstrap-preserve"] = old["bootstrap-preserve"]
      else .
    end;

# Compute new arrays, then rebuild root
(ensureObj(.)) as $r
| ($r.tasks  // []) as $tasks
| ($r.inputs // []) as $inputs
| ($desiredTask) as $desired
| (ensureArr($tasks) | map(select(type=="object"))) as $T
| ($T | map(select((.__name? // "") == $desired.__name)) | if length>0 then .[0] else null end) as $oldStrict
| ($T | map(select(((.command? // "") == $desired.command) and ((.args? // "") == $desired.args))) | if length>0 then .[0] else null end) as $oldLegacy
| ($oldStrict // $oldLegacy) as $old
| (if $old!=null then preserve_merge($old; $desired) else $desired end) as $merged
| ($T
   | map(select(
       ((.__name? // "") == $desired.__name)
       or (((.command? // "") == $desired.command) and ((.args? // "") == $desired.args))
     ) | not))
   + [ $merged ]) as $newTasks
| ( (ensureArr($inputs))
    as $I
    | ($desiredInputs) as $DI
    | reduce $DI[] as $ni ( $I;
        (map(.id) | index($ni.id)) as $idx
        | if $idx == null then . + [ $ni ] else . end )
  ) as $newInputs
| $r
| .version = (.version // "2.0.0")
| .tasks   = $newTasks
| .inputs  = $newInputs
JQ

  jq \
    --argfile desiredTask   "$tf/desired_task.json" \
    --argfile desiredInputs "$tf/desired_inputs.json" \
    -f "$tf/filter_tasks.jq" \
    "$TASKS_PATH" > "$tf/out.json" && mv "$tf/out.json" "$TASKS_PATH"

  # Fallback: if our task is still missing (for any reason), append it.
  if ! jq -e '
      (.tasks // []) | any(
        . as $t
        | (($t.__name // "") == "Bootstrap GitHub Workspace")
          or ( ($t.command // "") == "sh"
               and ((($t.args // []) | map(tostring) | join(",")) | contains("/custom-cont-init.d/10-bootstrap.sh")) )
      )
    ' "$TASKS_PATH" >/dev/null; then
    jq --argfile desiredTask "$tf/desired_task.json" '
      .version = (.version // "2.0.0")
      | .tasks = ((.tasks // []) + [$desiredTask])
      | .inputs = (.inputs // [])
    ' "$TASKS_PATH" > "$tf/ensure.json" && mv "$tf/ensure.json" "$TASKS_PATH"
    log "tasks.json fallback: appended bootstrap task"
  fi

  chown "$PUID:$PGID" "$TASKS_PATH" 2>/dev/null || true
  rm -rf "$tf"
  log "merged tasks.json (bootstrap-preserve honored; bootstrap task ensured) → $TASKS_PATH"
}

# ---------------------------
# INSTALL KEYBINDING (bootstrap-preserve + ensure present)
# ---------------------------
install_keybinding() {
  ensure_dir "$USER_DIR"

  if [ ! -f "$KEYB_PATH" ]; then
    write_file "$KEYB_PATH" "$(printf '[%s]\n' "$KEYB_JSON")"
    log "created keybindings.json → $KEYB_PATH"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; keybindings.json exists → skipping merge."
    return 0
  fi

  tf="$(mktemp -d)"
  printf "%s" "$KEYB_JSON" > "$tf/desired_kb.json"

  cat > "$tf/filter_keyb.jq" <<'JQ'
def ensureArr(a): if (a|type)=="array" then a else [] end;

def preserve_merge(old; desired):
  ((old["bootstrap-preserve"] // []) | map(select(type=="string"))) as $keep
  | (desired + {}) as $out
  | reduce $keep[] as $k (
      $out;
      if ($k == "__name" or $k == "bootstrap-preserve") then .
      elif (old | has($k)) then .[$k] = old[$k] else . end
    )
  | if ((old["bootstrap-preserve"] | type) == "array")
      then .["bootstrap-preserve"] = old["bootstrap-preserve"]
      else .
    end;

(ensureArr(.)) as $arr
| ($desiredKB) as $desired
| ($arr | map(select(type=="object" and ((.__name? // "") == $desired.__name))) | if length>0 then .[0] else null end) as $oldStrict
| ($arr | map(select(type=="object"
                     and ((.command? // "") == $desired.command)
                     and ((.args? // "") == $desired.args))) | if length>0 then .[0] else null end) as $oldLegacy
| ($oldStrict // $oldLegacy) as $old
| (if $old!=null then preserve_merge($old; $desired) else $desired end) as $merged
| ( $arr
    | map(select(type=="object"))
    | map(select(
        ((.__name? // "") == $desired.__name)
        or (((.command? // "") == $desired.command) and ((.args? // "") == $desired.args))
      ) | not))
    + [ $merged ]
JQ

  jq \
    --argfile desiredKB "$tf/desired_kb.json" \
    -f "$tf/filter_keyb.jq" \
    "$KEYB_PATH" > "$tf/out.json" && mv "$tf/out.json" "$KEYB_PATH"

  # Fallback: ensure present
  if ! jq -e '
      ( . // [] ) | any(
        . as $k
        | (($k.__name // "") == "Bootstrap GitHub Workspace")
          or ( (($k.command // "") == "workbench.action.tasks.runTask")
               and (($k.args // "") == "Bootstrap GitHub Workspace") )
      )
    ' "$KEYB_PATH" >/dev/null; then
    jq --argfile desiredKB "$tf/desired_kb.json" '
      ( . // [] ) + [ $desiredKB ]
    ' "$KEYB_PATH" > "$tf/ensure.json" && mv "$tf/ensure.json" "$KEYB_PATH"
    log "keybindings.json fallback: appended bootstrap keybinding"
  fi

  chown "$PUID:$PGID" "$KEYB_PATH" 2>/dev/null || true
  rm -rf "$tf"
  log "merged keybindings.json (bootstrap-preserve honored; bootstrap keybinding ensured) → $KEYB_PATH"
}

# ---------------------------
# SETTINGS MERGE (repo → user) with bootstrap-preserve
# ---------------------------
install_settings_from_repo() {
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo bootstrap-settings.json; skipping settings merge"; return 0; }

  if ! command -v jq >/dev/null 2>&1; then
    if [ ! -f "$SETTINGS_PATH" ]; then
      ensure_dir "$USER_DIR"
      cp "$REPO_SETTINGS_SRC" "$SETTINGS_PATH"
      chown "$PUID:$PGID" "$SETTINGS_PATH" 2>/dev/null || true
      log "created settings.json from repo (no jq) → $SETTINGS_PATH"
    else
      log "jq not found; settings.json exists → skipping merge."
    fi
    return 0
  fi

  if [ ! -f "$SETTINGS_PATH" ]; then
    ensure_dir "$USER_DIR"
    cp "$REPO_SETTINGS_SRC" "$SETTINGS_PATH"
    chown "$PUID:$PGID" "$SETTINGS_PATH" 2>/dev/null || true
    log "created settings.json from repo → $SETTINGS_PATH"
    return 0
  fi

  tf="$(mktemp -d)"
  cp "$REPO_SETTINGS_SRC" "$tf/repo.json"

  cat > "$tf/filter_settings.jq" <<'JQ'
def ensureObj(o): if (o|type)=="object" then o else {} end;

(ensureObj(.)) as $user
| (( $user["bootstrap-preserve"] // [] ) | map(select(type=="string"))) as $keep
| (ensureObj($repo)) as $repo
| reduce ($repo | to_entries[]) as $e (
    ($user + {});
    if ($e.key == "bootstrap-preserve") then .
    elif ($keep | index($e.key)) != null then .
    else .[$e.key] = $e.value end
  )
JQ

  jq --argfile repo "$tf/repo.json" -f "$tf/filter_settings.jq" \
    "$SETTINGS_PATH" > "$tf/out.json" && mv "$tf/out.json" "$SETTINGS_PATH"

  chown "$PUID:$PGID" "$SETTINGS_PATH" 2>/dev/null || true
  rm -rf "$tf"
  log "merged settings.json (bootstrap-preserve honored) → $SETTINGS_PATH"
}

# ---------------------------
# BOOTSTRAP
# ---------------------------
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
  chown "$PUID:$PGID" "$SSH_DIR/known_hosts" 2>/dev/null || true
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
      log "clone: ${safe_url} -> ${dest} (branch='\${branch:-default}')"
      if [ -n "$branch" ]; then
        git clone --branch "$branch" --single-branch "$url" "$dest" || { log "clone failed: $spec"; return 0; }
      else
        git clone "$url" "$dest" || { log "clone failed: $spec"; return 0; }
      fi
    fi
    chown -R "$PUID:$PGID" "$dest" 2>/dev/null || true
  }

  if [ -n "${GIT_REPOS:-}" ]; then
    IFS=,; set -- $GIT_REPOS; unset IFS
    for spec in "$@"; do clone_one "$spec"; done
  else
    log "GIT_REPOS empty; skip clone"
  fi

  log "bootstrap done"
}

# ---------------------------
# RUN
# ---------------------------
install_tasks
install_keybinding
install_settings_from_repo

if [ "${1:-}" = "force" ]; then
  log "manual run (force) → ignoring autorun lock"
  do_bootstrap
  exit 0
fi

if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ]; then
  if [ ! -f "$LOCK_FILE" ]; then
    : > "$LOCK_FILE" || true
    log "env present and no lock → running bootstrap"
    do_bootstrap || true
  else
    log "autorun lock present → skipping duplicate bootstrap this start"
  fi
else
  log "GH_USER/GH_PAT missing → skip autorun (use Ctrl+Alt+G or Tasks: Run Task)"
fi

log "Task + keybinding + (optional) settings installed under: $USER_DIR (reload window if not visible)"
