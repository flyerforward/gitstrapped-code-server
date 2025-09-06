#!/usr/bin/env sh
set -eu

log(){ echo "[bootstrap] $*"; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

export HOME=/config
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Candidate user-data locations (covering code-server variants)
USER_CANDIDATES="
/config/.local/share/code-server/User
/config/data/User
"

BASE="${GIT_BASE_DIR:-/config/workspace}"
SSH_DIR="/config/.ssh"
KEY_NAME="id_ed25519"
PRIVATE_KEY_PATH="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY_PATH="$SSH_DIR/${KEY_NAME}.pub"

LOCK_DIR="/run/bootstrap"; mkdir -p "$LOCK_DIR" 2>/dev/null || true
LOCK_FILE="$LOCK_DIR/autorun.lock"

# ---- payloads (task, inputs, keybinding) ----
TASK_LABEL="Bootstrap GitHub Workspace"
TASK_JSON='{
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
}'
INPUTS_JSON='[
  { "id": "gh_user",   "type": "promptString", "description": "GitHub username (required)", "default": "${env:GH_USER}" },
  { "id": "gh_pat",    "type": "promptString", "description": "GitHub PAT (classic; scopes: user:email, admin:public_key)", "password": true },
  { "id": "git_email", "type": "promptString", "description": "Git email (optional; leave empty to auto-detect)", "default": "" },
  { "id": "git_name",  "type": "promptString", "description": "Git name (optional; default = GH_USER)", "default": "${env:GIT_NAME}" },
  { "id": "git_repos", "type": "promptString", "description": "Repos to clone (owner/repo[#branch] or URLs, comma-separated)", "default": "${env:GIT_REPOS}" }
]'
KEYB_JSON='{
  "key": "ctrl+alt+g",
  "command": "workbench.action.tasks.runTask",
  "args": "Bootstrap GitHub Workspace",
  "when": "editorTextFocus"
}'

# ---------- helpers ----------
ensure_dir() { mkdir -p "$1"; chown -R "$PUID:$PGID" "$1"; }
write_file() { printf "%s" "$2" > "$1"; chown "$PUID:$PGID" "$1"; }
append_json_array_item() {
  # $1=file, $2=item-json
  # naive but safe: if the file is a JSON array, append; else create array with item
  if [ ! -s "$1" ]; then
    printf "[%s]\n" "$2" > "$1"
    return 0
  fi
  if grep -q '^\s*\[' "$1"; then
    # remove trailing ] then append with comma if necessary, then ]
    # handle existing trailing spaces/newlines
    tmp="$(mktemp)"
    # if array already empty → just insert item; else insert comma then item
    if grep -q '\[[[:space:]]*\]' "$1"; then
      sed 's/\[[[:space:]]*\]/[ '"$2"' ]/' "$1" > "$tmp"
    else
      # add comma before closing ]
      sed '$!b; s/][[:space:]]*$/\n]/' "$1" > "$tmp" # normalize final bracket newline
      # check if last non-space char before closing ] is '[' or something else
      if tail -n 1 "$1" | grep -q ']' ; then :; fi
      # add comma+item before last ]
      awk -v RS= -v ORS= -v item="$2" '
        { sub(/\][[:space:]]*$/, ", " item "\n]"); print }
      ' "$tmp" > "$1"
      rm -f "$tmp"
      return 0
    fi
    mv "$tmp" "$1"
  else
    # not an array → wrap into array with original preserved as second element (best-effort)
    tmp="$(mktemp)"
    printf "[%s]\n" "$2" > "$tmp"
    mv "$tmp" "$1"
  fi
}

merge_tasks_nojq() {
  # $1=tasks.json path
  f="$1"
  if [ ! -s "$f" ]; then
    write_file "$f" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)"
    log "created tasks.json → $f"
    return
  fi

  # If our task label already present, we won't duplicate; ensure inputs exist
  if grep -q "\"label\"[[:space:]]*:[[:space:]]*\"$TASK_LABEL\"" "$f"; then
    # ensure inputs array contains our 5 inputs by id; if not present, append simplest way:
    if ! grep -q '"id"[[:space:]]*:[[:space:]]*"gh_user"' "$f"; then
      # naive append: if "inputs" exists and is an array, append our INPUTS_JSON items; else create
      if grep -q '"inputs"[[:space:]]*:' "$f"; then
        # Try to replace "inputs": [...] with our union (very rough). Safer path: backup + recreate minimal.
        cp "$f" "$f.bak"
        # Extract existing inputs block end and append; fallback to overwrite minimal acceptable structure
        # Minimal safe fallback (don’t break existing tasks): keep tasks array, reset inputs to our INPUTS_JSON
        tasks_block="$(awk 'BEGIN{p=0} /"tasks"[[:space:]]*:/ {p=1} p{print} /\][[:space:]]*,?[[:space:]]*"inputs"/{exit}' "$f" 2>/dev/null || true)"
        if [ -n "$tasks_block" ]; then
          write_file "$f" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": $(echo "$tasks_block" | sed -n 's/^[^{]*"tasks"[[:space:]]*:[[:space:]]*\(.*\)$/\1/p' | sed 's/,"inputs".*$//'),
  "inputs": $INPUTS_JSON
}
JSON
)"
        fi
      else
        # add an inputs array
        cp "$f" "$f.bak"
        sed -i 's/}[[:space:]]*$/,\n  "inputs": '"$INPUTS_JSON"'\n}/' "$f" || true
      fi
    fi
    log "updated tasks.json (no jq): ensured inputs for Bootstrap task → $f"
    return
  fi

  # Our task missing → append into tasks array or create minimal file
  if grep -q '"tasks"[[:space:]]*:' "$f"; then
    # Try to append into existing tasks array (best-effort)
    cp "$f" "$f.bak"
    # If tasks array is empty, replace [] with [ $TASK_JSON ]; else inject before closing ]
    if grep -q '"tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$f"; then
      sed -i 's/"tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]/"tasks": [ '"$TASK_JSON"' ]/' "$f"
    else
      # insert before the last ] of the tasks array – very rough heuristic:
      awk -v RS= -v ORS= -v task="$TASK_JSON" '
        {
          # naive: find "tasks": [ ... ]; insert , task before its matching ]
          sub(/"tasks"[[:space:]]*:[[:space:]]*\[/, "&"); 
          gsub(/\n/, "\n");
          # not robust JSON parsing; best-effort append near end of file:
        }1
      ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      # If append failed, fall back to minimal rewrite preserving tasks array content via grep/sed isn’t reliable.
      # So as a safety net, rebuild a minimal valid file:
      if ! grep -q "$TASK_LABEL" "$f"; then
        tasks_block="$(sed -n '/"tasks"[[:space:]]*:/,$p' "$f" | sed -n '1,/]/p' | sed '1!s/^[^{]*"tasks"[[:space:]]*:[[:space:]]*//')"
        [ -n "$tasks_block" ] || tasks_block='[]'
        # Insert our task into the array text
        if echo "$tasks_block" | grep -q '^\s*\[\s*\]\s*$'; then
          tasks_new="[ $TASK_JSON ]"
        else
          tasks_new="$(echo "$tasks_block" | sed -E 's/\][[:space:]]*$/ , '"$TASK_JSON"' ]/')"
        fi
        write_file "$f" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": $tasks_new,
  "inputs": $INPUTS_JSON
}
JSON
)"
      fi
    fi
  else
    # No tasks section → minimal structure
    write_file "$f" "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)"
  fi
  log "appended Bootstrap task to tasks.json (no jq) → $f"
}

merge_keybindings_nojq() {
  # $1=keybindings.json path
  f="$1"
  if [ ! -s "$f" ]; then
    write_file "$f" "$(printf '[%s]\n' "$KEYB_JSON")"
    log "created keybindings.json → $f"
    return
  fi
  # Already present?
  if grep -q '"command"[[:space:]]*:[[:space:]]*"workbench.action.tasks.runTask"[[:space:]]*,' "$f" \
     && grep -q '"args"[[:space:]]*:[[:space:]]*"'"$TASK_LABEL"'"' "$f"; then
    log "keybinding already present → $f"
    return
  fi
  # Append into array (best-effort)
  if head -n1 "$f" | grep -q '^\s*\['; then
    tmp="$(mktemp)"
    cp "$f" "$tmp"
    # empty array?
    if grep -q '^\s*\[\s*\]\s*$' "$f"; then
      printf '[ %s ]\n' "$KEYB_JSON" > "$f"
    else
      # add comma+item before trailing ]
      awk -v RS= -v ORS= -v item="$KEYB_JSON" '
        { sub(/\][[:space:]]*$/, ", " item "\n]"); print }
      ' "$tmp" > "$f"
    fi
    rm -f "$tmp"
    chown "$PUID:$PGID" "$f"
    log "appended Bootstrap keybinding (no jq) → $f"
  else
    # Not an array → replace with our array (safer than corrupting)
    write_file "$f" "$(printf '[%s]\n' "$KEYB_JSON")"
    log "replaced malformed keybindings with valid array containing Bootstrap → $f"
  fi
}

install_user_assets() {
  for USER_DIR in $USER_CANDIDATES; do
    TASKS_PATH="$USER_DIR/tasks.json"
    KEYB_PATH="$USER_DIR/keybindings.json"
    ensure_dir "$USER_DIR"

    if command -v jq >/dev/null 2>&1; then
      # --- tasks (jq) ---
      if [ -f "$TASKS_PATH" ]; then
        tmp="$(mktemp)"
        printf "%s" "$TASK_JSON" > "$tmp.task"
        printf "%s" "$INPUTS_JSON" > "$tmp.inputs"
        jq \
          --slurpfile newtask "$tmp.task" \
          --slurpfile newinputs "$tmp.inputs" '
            ( . // {} ) as $root
            | ($root.tasks // []) as $tasks
            | ($root.inputs // []) as $inputs
            | $root
            | .version = ( .version // "2.0.0" )
            | .tasks = ( ($tasks | map(select(.label != $newtask[0].label))) + [ $newtask[0] ] )
            | .inputs = (
                reduce $newinputs[0][] as $ni (
                  ($inputs // []);
                  ( map(select(.id != $ni.id)) + [ $ni ] )
                )
              )
          ' "$TASKS_PATH" > "$tmp.out" && mv "$tmp.out" "$TASKS_PATH"
        rm -f "$tmp.task" "$tmp.inputs"
        chown "$PUID:$PGID" "$TASKS_PATH"
        log "merged (jq) task → $TASKS_PATH"
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

      # --- keybindings (jq) ---
      if [ -f "$KEYB_PATH" ]; then
        tmp="$(mktemp)"
        printf "%s" "$KEYB_JSON" > "$tmp.kb"
        jq --slurpfile kb "$tmp.kb" '
          ( . // [] ) as $arr
          | ( $arr | map(select(.command != $kb[0].command or .args != $kb[0].args)) )
            + [ $kb[0] ]
        ' "$KEYB_PATH" > "$tmp.out" && mv "$tmp.out" "$KEYB_PATH"
        rm -f "$tmp.kb"
        chown "$PUID:$PGID" "$KEYB_PATH"
        log "merged (jq) keybinding → $KEYB_PATH"
      else
        write_file "$KEYB_PATH" "$(printf '[%s]\n' "$KEYB_JSON")"
        log "created keybindings.json → $KEYB_PATH"
      fi

    else
      # No jq: conservative append/create
      merge_tasks_nojq "$TASKS_PATH"
      chown "$PUID:$PGID" "$TASKS_PATH"
      merge_keybindings_nojq "$KEYB_PATH"
      chown "$PUID:$PGID" "$KEYB_PATH"
    fi
  done

  log "Installed/merged Task + keybinding in user dirs above."
  log "If you don't see them yet, run: Command Palette → Developer: Reload Window."
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

# ---------- run ----------
# Always install/merge the Task + keybinding into both candidate paths
for u in $USER_CANDIDATES; do
  ensure_dir "$u"
done
install_user_assets

# Auto-run bootstrap once per start if env present
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

# Friendly hint for visibility
log "User task + keybinding installed under:"
for u in $USER_CANDIDATES; do
  echo " - $u"
done
log "Reload code-server window to pick up changes (Cmd/Ctrl+Shift+P → Developer: Reload Window)."
