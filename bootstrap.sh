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

# Only this repo settings source
REPO_SETTINGS_SRC="/config/bootstrap/bootstrap-settings.json"

STATE_DIR="/config/.bootstrap"
MANAGED_KEYS_FILE="$STATE_DIR/managed-settings-keys.json"

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
ensure_dir(){ mkdir -p "$1"; chown -R "$PUID:$PGID" "$1"; }
write_file(){ printf "%s" "$2" > "$1"; chown "$PUID:$PGID" "$1"; }

# ---------------------------
# OUR DESIRED CONFIG OBJECTS
# ---------------------------
# We mark our managed objects with a private boolean flag.
BOOTSTRAP_FLAG='__bootstrap_setting'

TASK_JSON='{
  "__bootstrap_setting": true,
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

# GLOBAL shortcut (no "when") — identified solely by our private boolean flag
KEYB_JSON='{
  "__bootstrap_setting": true,
  "key": "ctrl+alt+g",
  "command": "workbench.action.tasks.runTask",
  "args": "Bootstrap GitHub Workspace"
}'

# ---------------------------
# INSTALL/MERGE USER ASSETS (tasks + keybinding)
# ---------------------------
install_user_assets() {
  ensure_dir "$USER_DIR"

  # Normalize malformed keybindings.json (array required)
  if [ -f "$KEYB_PATH" ] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    if ! jq -e . "$KEYB_PATH" >/dev/null 2>&1; then
      cp "$KEYB_PATH" "$KEYB_PATH.bak"
      printf '[]' > "$KEYB_PATH"
    else
      jq 'if type=="array" then . else [] end' "$KEYB_PATH" > "$tmp" && mv "$tmp" "$KEYB_PATH"
    fi
    chown "$PUID:$PGID" "$KEYB_PATH"
  fi

  if command -v jq >/dev/null 2>&1; then
    # --- tasks.json merge (preserve only fields listed in bootstrap_preserve within the same object) ---
    if [ -f "$TASKS_PATH" ] && jq -e . "$TASKS_PATH" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      printf "%s" "$TASK_JSON"   > "$tmp.task"
      printf "%s" "$INPUTS_JSON" > "$tmp.inputs"
      jq \
        --arg flag "$BOOTSTRAP_FLAG" \
        --slurpfile newtask "$tmp.task" \
        --slurpfile newinputs "$tmp.inputs" '
          def ensureObj(o): if (o|type)=="object" then o else {} end;
          def ensureArr(a): if (a|type)=="array"  then a else [] end;

          # Merge incoming with existing, but preserve ONLY keys listed in .bootstrap_preserve on the SAME OBJECT
          def merge_with_preserve($old; $incoming; $flag):
            ($incoming + {($flag): true})
            | ( .bootstrap_preserve = ( (($old.bootstrap_preserve // []) + (.bootstrap_preserve // [])) | unique ) )
            | ( reduce (($old.bootstrap_preserve // [])[]) as $k
                ( . ; .[$k] = ($old[$k] // .[$k]) ) );

          (ensureObj(.)) as $root
          | ($root.tasks  // []) as $tasks
          | ($root.inputs // []) as $inputs
          | $root
          | .version = ( .version // "2.0.0" )
          | .tasks  = (
              ensureArr($tasks)
              | (map(
                  if (type=="object" and ((.[$flag]? // false) == true)) then
                    merge_with_preserve(.; $newtask[0]; $flag)
                  else .
                  end
                )) as $updated
              | if any($updated[]; (type=="object" and ((.[$flag]? // false) == true))) then
                  $updated
                else
                  $updated + [ $newtask[0] ]    # add ours if not found
                end
            )
          | .inputs = (
              ensureArr($inputs)
              | reduce $newinputs[0][] as $ni
                  ( . ; map(select(type=="object" and (.id? // null) != $ni.id)) + [ $ni ] )
            )
        ' "$TASKS_PATH" > "$tmp.out" && mv "$tmp.out" "$TASKS_PATH"
      rm -f "$tmp.task" "$tmp.inputs"
      chown "$PUID:$PGID" "$TASKS_PATH"
      log "merged tasks.json (preserve at same object level) → $TASKS_PATH"
    else
      write_file "$TASKS_PATH" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)"
      log "created tasks.json → $TASKS_PATH"
    fi

    # --- keybindings.json merge (preserve only fields listed in bootstrap_preserve within the same entry) ---
    if [ -f "$KEYB_PATH" ] && jq -e . "$KEYB_PATH" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      printf "%s" "$KEYB_JSON" > "$tmp.kb"
      jq \
        --arg flag "$BOOTSTRAP_FLAG" \
        --slurpfile kb "$tmp.kb" '
        def ensureArr(a): if (a|type)=="array" then a else [] end;

        def merge_with_preserve($old; $incoming; $flag):
          ($incoming + {($flag): true})
          | ( .bootstrap_preserve = ( (($old.bootstrap_preserve // []) + (.bootstrap_preserve // [])) | unique ) )
          | ( reduce (($old.bootstrap_preserve // [])[]) as $k
              ( . ; .[$k] = ($old[$k] // .[$k]) ) );

        (ensureArr(.)) as $arr
        | (map(
            if (type=="object" and ((.[$flag]? // false) == true)) then
              merge_with_preserve(.; $kb[0]; $flag)
            else .
            end
          )) as $updated
        | if any($updated[]; (type=="object" and ((.[$flag]? // false) == true))) then
            $updated
          else
            $updated + [ $kb[0] ]
          end
      ' "$KEYB_PATH" > "$tmp.out" && mv "$tmp.out" "$KEYB_PATH"
      rm -f "$tmp.kb"
      chown "$PUID:$PGID" "$KEYB_PATH"
      log "merged keybindings.json (preserve at same entry level) → $KEYB_PATH"
    else
      write_file "$KEYB_PATH" "$(printf '[%s]\n' "$KEYB_JSON")"
      log "created keybindings.json → $KEYB_PATH"
    fi

  else
    # No jq → create-only (never overwrite)
    if [ ! -f "$TASKS_PATH" ]; then
      write_file "$TASKS_PATH" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)"
      log "created tasks.json (no jq) → $TASKS_PATH"
    fi

    if [ ! -f "$KEYB_PATH" ]; then
      write_file "$KEYB_PATH" "$(printf '[%s]\n' "$KEYB_JSON")"
      log "created keybindings.json (no jq) → $KEYB_PATH"
    fi
  fi
}

# ---------------------------
# SETTINGS MERGE (repo settings → user settings) with same-level preserve
# ---------------------------
# For VS Code user settings, keys are at the root object.
# The preserve list MUST also live at the root (same level as those keys).
install_settings_from_repo() {
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo bootstrap-settings.json; skipping settings merge"; return 0; }

  if ! command -v jq >/dev/null 2>&1; then
    if [ ! -f "$SETTINGS_PATH" ]; then
      ensure_dir "$USER_DIR"
      cp "$REPO_SETTINGS_SRC" "$SETTINGS_PATH"
      chown "$PUID:$PGID" "$SETTINGS_PATH"
      log "created settings.json from repo (no jq) → $SETTINGS_PATH"
    fi
    return 0
  fi

  if ! jq -e . "$REPO_SETTINGS_SRC" >/dev/null 2>&1; then
    log "WARNING: repo settings JSON invalid → $REPO_SETTINGS_SRC ; skipping settings merge"
    return 0
  fi

  ensure_dir "$STATE_DIR"
  ensure_dir "$USER_DIR"

  # Ensure user settings is an object
  if [ -f "$SETTINGS_PATH" ]; then
    if ! jq -e . "$SETTINGS_PATH" >/dev/null 2>&1; then
      cp "$SETTINGS_PATH" "$SETTINGS_PATH.bak"
      printf "{}" > "$SETTINGS_PATH"
    else
      tmp="$(mktemp)"; jq 'if type=="object" then . else {} end' "$SETTINGS_PATH" > "$tmp" && mv "$tmp" "$SETTINGS_PATH"
    fi
  else
    printf "{}" > "$SETTINGS_PATH"
    chown "$PUID:$PGID" "$SETTINGS_PATH"
  fi

  RS_KEYS_JSON="$(jq 'keys' "$REPO_SETTINGS_SRC")"
  if [ -f "$MANAGED_KEYS_FILE" ] && jq -e . "$MANAGED_KEYS_FILE" >/dev/null 2>&1; then
    OLD_KEYS_JSON="$(cat "$MANAGED_KEYS_FILE")"
  else
    OLD_KEYS_JSON='[]'
  fi

  tmp="$(mktemp)"
  jq \
    --argjson repo "$(cat "$REPO_SETTINGS_SRC")" \
    --argjson rskeys "$RS_KEYS_JSON" \
    --argjson oldkeys "$OLD_KEYS_JSON" '
      def contains($arr; $x): any($arr[]; . == $x);
      def minus($a; $b): [ $a[] | select(contains($b; .) | not) ];
      def delKeys($ks): reduce $ks[] as $k (. ; del(.[$k]));

      # Same-level preserve: read ONLY from the same object (root) that holds the settings
      (. // {}) as $user
      | ($user.bootstrap_preserve // []) as $pres
      # Remove previously-managed keys that are no longer present in repo settings
      | delKeys(minus($oldkeys; $rskeys))
      # Overlay repo settings
      | ( . + $repo )
      # Restore user values ONLY for keys listed in bootstrap_preserve at this SAME level
      | ( reduce $pres[] as $k ( . ; .[$k] = ($user[$k] // .[$k]) ) )
    ' "$SETTINGS_PATH" > "$tmp" && mv "$tmp" "$SETTINGS_PATH"
  chown "$PUID:$PGID" "$SETTINGS_PATH"
  printf "%s" "$RS_KEYS_JSON" > "$MANAGED_KEYS_FILE"
  chown "$PUID:$PGID" "$MANAGED_KEYS_FILE"

  log "merged settings.json (repo overrides; same-level preserved keys honored) → $SETTINGS_PATH"
}

# ---------------------------
# BOOTSTRAP
# ---------------------------
resolve_email(){
  EMAILS="$(curl -fsS -H "Authorization: token ${GH_PAT}" -H "Accept: application/vnd.github+json" https://api.github.com/user/emails || true)"
  PRIMARY="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"primary": *true/ {print e; exit}')"
  [ -n "${PRIMARY:-}" ] && { echo "$PRIMARY"; return; }
  VERIFIED="$(printf "%s" "$EMAILS" | awk -F\" '/"email":/ {e=$4} /"verified": *true/ {print e; exit}')"
  [ -n "${VERIFIED:-}" ] && { echo "$VERIFIED"; return; }
  PUB_JSON="$(curl -fsS -H "Accept: application/vnd.github+json" "https://api.github.com/users/${GH_USER}" || true)"
  PUB_EMAIL="$(printf "%s" "$PUB_JSON" | awk -F\" '/"email":/ {print $4; exit}')"
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
      log "clone: ${safe_url} -> ${dest} (branch='\${branch:-default}')"
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

# ---------------------------
# RUN
# ---------------------------
install_user_assets
install_settings_from_repo

# If invoked with "force", always run bootstrap (bypass lock)
if [ "${1:-}" = "force" ]; then
  log "manual run (force) → ignoring autorun lock"
  do_bootstrap
  exit 0
fi

# Otherwise, normal autorun behavior on container start
if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ] && [ ! -f "$LOCK_FILE" ]; then
  : > "$LOCK_FILE" || true
  log "env present and no lock → running bootstrap"
  do_bootstrap || true
else
  [ -f "$LOCK_FILE" ] && log "autorun lock present → skipping duplicate bootstrap this start"
  { [ -z "${GH_USER:-}" ] || [ -z "${GH_PAT:-}" ]; } && log "GH_USER/GH_PAT missing → skip autorun (use Ctrl+Alt+G or Tasks: Run Task)"
fi

log "Task + keybinding + (optional) settings installed under: $USER_DIR (reload window if not visible)"
