#!/usr/bin/env sh
set -eu

log(){ echo "[gitstrap] $*"; }
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
REPO_SETTINGS_SRC="/config/gitstrap/settings.json"

STATE_DIR="/config/.gitstrap"
MANAGED_KEYS_FILE="$STATE_DIR/managed-settings-keys.json"

BASE="${GIT_BASE_DIR:-/config/workspace}"
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

LOCK_DIR="/run/gitstrap"
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
GITSTRAP_FLAG='__gitstrap_settings'

TASK_JSON='{
  "__gitstrap_settings": true,
  "label": "Bootstrap GitHub Workspace",
  "type": "shell",
  "command": "sh",
  "args": ["/custom-cont-init.d/10-gitstrap.sh", "force"],
  "options": {
    "env": {
      "GH_USER": "${input:gh_user}",
      "GH_PAT": "${input:gh_pat}",
      "GIT_EMAIL": "${input:git_email}",
      "GIT_NAME": "${input:git_name}",
      "GIT_REPOS": "${input:git_repos}"
    }
  },
  "problemMatcher": [],
  "gitstrap_preserve": []
}'

INPUTS_JSON='[
  { "__gitstrap_settings": true, "id": "gh_user",   "type": "promptString", "description": "GitHub username (required)", "default": "${env:GH_USER}", "gitstrap_preserve": [] },
  { "__gitstrap_settings": true, "id": "gh_pat",    "type": "promptString", "description": "GitHub PAT (classic; scopes: user:email, admin:public_key)", "password": true, "gitstrap_preserve": [] },
  { "__gitstrap_settings": true, "id": "git_email", "type": "promptString", "description": "Git email (optional; leave empty to auto-detect)", "default": "", "gitstrap_preserve": [] },
  { "__gitstrap_settings": true, "id": "git_name",  "type": "promptString", "description": "Git name (optional; default = GH_USER)", "default": "${env:GIT_NAME}", "gitstrap_preserve": [] },
  { "__gitstrap_settings": true, "id": "git_repos", "type": "promptString", "description": "Repos to clone (owner/repo[#branch] or URLs, comma-separated)", "default": "${env:GIT_REPOS}", "gitstrap_preserve": [] }
]'

KEYB_JSON='{
  "__gitstrap_settings": true,
  "key": "ctrl+alt+g",
  "command": "workbench.action.tasks.runTask",
  "args": "Bootstrap GitHub Workspace",
  "gitstrap_preserve": []
}'

# ---------------------------
# INSTALL/MERGE USER ASSETS (tasks + keybinding + inputs)
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
    # --- tasks.json merge (tasks + inputs with same-level preserve support) ---
    if [ -f "$TASKS_PATH" ] && jq -e . "$TASKS_PATH" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      printf "%s" "$TASK_JSON"   > "$tmp.task"
      printf "%s" "$INPUTS_JSON" > "$tmp.inputs"
      jq \
        --arg flag "$GITSTRAP_FLAG" \
        --slurpfile newtask "$tmp.task" \
        --slurpfile newinputs "$tmp.inputs" '
          def ensureObj(o): if (o|type)=="object" then o else {} end;
          def ensureArr(a): if (a|type)=="array"  then a else [] end;

          # Merge incoming with existing, preserving ONLY keys listed in .gitstrap_preserve on the SAME OBJECT
          def merge_with_preserve($old; $incoming; $flag):
            ($incoming + {($flag): true})
            | ( .gitstrap_preserve = ( (($old.gitstrap_preserve // []) + (.gitstrap_preserve // [])) | unique ) )
            | ( reduce (($old.gitstrap_preserve // [])[]) as $k
                ( . ; .[$k] = ($old[$k] // .[$k]) ) );

          (ensureObj(.)) as $root
          | ($root.tasks  // []) as $tasks
          | ($root.inputs // []) as $inputs
          | $root
          | .version = ( .version // "2.0.0" )

          # ---- TASKS: update any flagged task(s); add ours if none flagged exists
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
                  $updated + [ $newtask[0] ]
                end
            )

          # ---- INPUTS: STRICT UPSERT BY id (no duplicates)
          | .inputs = (
              ensureArr($inputs) as $cur
              | ($newinputs[0]) as $desired
              | ($desired | map(select(.id? != null) | .id) | unique) as $dids
              | ( $cur | map(select( ((.id? // "") as $x | ($dids | index($x))) | not )) ) as $others
              | (
                  $dids
                  | map(
                      . as $id
                      | ($desired | map(select(.id == $id)) | first) as $inc
                      | ($cur | map(select((.id? // "") == $id))) as $matches
                      | ($matches | map(select((.[$flag]? // false) == true)) | first) as $old_flagged
                      | (if $old_flagged then $old_flagged else ($matches | first) end) as $old
                      | if $old then merge_with_preserve($old; $inc; $flag) else $inc end
                    )
                ) as $merged
              | $others + $merged
            )
        ' "$TASKS_PATH" > "$tmp.out" && mv "$tmp.out" "$TASKS_PATH"
      rm -f "$tmp.task" "$tmp.inputs"
      chown "$PUID:$PGID" "$TASKS_PATH"
      log "merged tasks.json (tasks & inputs; deduped by id; same-level preserves honored) → $TASKS_PATH"
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

    # --- keybindings.json merge (same-level preserves) ---
    if [ -f "$KEYB_PATH" ] && jq -e . "$KEYB_PATH" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      printf "%s" "$KEYB_JSON" > "$tmp.kb"
      jq \
        --arg flag "$GITSTRAP_FLAG" \
        --slurpfile kb "$tmp.kb" '
        def ensureArr(a): if (a|type)=="array" then a else [] end;

        def merge_with_preserve($old; $incoming; $flag):
          ($incoming + {($flag): true})
          | ( .gitstrap_preserve = ( (($old.gitstrap_preserve // []) + (.gitstrap_preserve // [])) | unique ) )
          | ( reduce (($old.gitstrap_preserve // [])[]) as $k
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
      log "merged keybindings.json (same-level preserves) → $KEYB_PATH"
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
# Enforces ordering each run:
#   1) all non-repo user keys
#   2) "__gitstrap_settings": true (marker)
#   3) ALL repo-managed keys (even if user moved them above)
# Preserves values for keys listed in root "gitstrap_preserve".
# ---------------------------
install_settings_from_repo() {
  [ -f "$REPO_SETTINGS_SRC" ] || { log "no repo settings.json; skipping settings merge"; return 0; }

  if ! command -v jq >/dev/null 2>&1; then
    if [ ! -f "$SETTINGS_PATH" ]; then
      ensure_dir "$USER_DIR"
      write_file "$SETTINGS_PATH" '{
        "__gitstrap_settings": true,
        "gitstrap_preserve": []
      }'
    fi
    return 0
  fi

  if ! jq -e . "$REPO_SETTINGS_SRC" >/dev/null 2>&1; then
    log "WARNING: repo settings JSON invalid → $REPO_SETTINGS_SRC ; skipping settings merge"
    return 0
  fi

  ensure_dir "$STATE_DIR"
  ensure_dir "$USER_DIR"

  # Ensure user settings is an object (coerce non-objects to {})
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
    --arg flag "$GITSTRAP_FLAG" \
    --argjson repo "$(cat "$REPO_SETTINGS_SRC")" \
    --argjson rskeys "$RS_KEYS_JSON" \
    --argjson oldkeys "$OLD_KEYS_JSON" '
      # Helpers
      def minus($a; $b): [ $a[] | select( ($b | index(.)) | not ) ];
      def delKeys($obj; $ks): reduce $ks[] as $k ($obj; del(.[$k]));

      # Normalize user
      (. // {}) as $user
      | ($user.gitstrap_preserve // []) as $pres

      # Remove previously-managed keys that are no longer present in repo
      | (delKeys($user; minus($oldkeys; $rskeys))) as $tmp_user

      # *** HARD REMOVE of ALL repo keys from user (so they can be re-added after marker) ***
      | (delKeys($tmp_user; $rskeys)) as $user_without_repo

      # Build final object: non-repo user → marker → repo-managed (with preserves)
      | ($user_without_repo | to_entries) as $user_non_repo_entries
      | reduce $user_non_repo_entries[] as $e ({}; .[$e.key] = $e.value)
      | .["__gitstrap_settings"] = true
      | .["gitstrap_preserve"]  = $pres      # <-- add this line
      | ( reduce $rskeys[] as $k
            ( . ;
              .[$k] =
                ( if ($pres | index($k)) and ($user | has($k)) then
                    $user[$k]     # preserved value, but placed after the marker
                  else
                    $repo[$k]
                  end )
            )
        )
    ' "$SETTINGS_PATH" > "$tmp" && mv "$tmp" "$SETTINGS_PATH"
  chown "$PUID:$PGID" "$SETTINGS_PATH"
  printf "%s" "$RS_KEYS_JSON" > "$MANAGED_KEYS_FILE"
  chown "$PUID:$PGID" "$MANAGED_KEYS_FILE"

  log "merged settings.json (repo keys always below marker; preserves honored) → $SETTINGS_PATH"
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

do_gitstrap(){
  : "${GH_USER:?GH_USER is required}"
  : "${GH_PAT:?GH_PAT is required}"

  GIT_NAME="${GIT_NAME:-$GH_USER}"
  GIT_REPOS="${GIT_REPOS:-}"

  log "gitstrap: user=$GH_USER, name=$GIT_NAME, base=$BASE"
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

  log "gitstrap done"
}

# ---------------------------
# RUN
# ---------------------------
install_user_assets
install_settings_from_repo

# If invoked with "force", always run gitstrap (bypass lock)
if [ "${1:-}" = "force" ]; then
  log "manual run (force) → ignoring autorun lock"
  do_gitstrap
  exit 0
fi

# Otherwise, normal autorun behavior on container start
if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ] && [ ! -f "$LOCK_FILE" ]; then
  : > "$LOCK_FILE" || true
  log "env present and no lock → running gitstrap"
  do_gitstrap || true
else
  [ -f "$LOCK_FILE" ] && log "autorun lock present → skipping duplicate gitstrap this start"
  { [ -z "${GH_USER:-}" ] || [ -z "${GH_PAT:-}" ]; } && log "GH_USER/GH_PAT missing → skip autorun (use Ctrl+Alt+G or Tasks: Run Task)"
fi

log "Task + keybinding + (optional) settings installed under: $USER_DIR (reload window if not visible)"
