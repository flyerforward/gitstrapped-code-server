#!/usr/bin/env sh
set -eu

log(){ echo "[bootstrap] $*"; }
redact(){ echo "$1" | sed 's/[A-Za-z0-9_\-]\{12,\}/***REDACTED***/g'; }

USER_DIR="/config/.local/share/code-server/User"
TASKS_JSON="$USER_DIR/tasks.json"
KEYB_JSON="$USER_DIR/keybindings.json"

install_user_assets() {
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
  mkdir -p "$USER_DIR"

  # Our desired Task (as standalone JSON object)
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  TASK_OBJ="$TMPD/task.json"
  INPUTS_ARR="$TMPD/inputs.json"
  KB_OBJ="$TMPD/keybinding.json"

  cat >"$TASK_OBJ" <<'JSON'
{
  "label": "Bootstrap GitHub Workspace",
  "type": "shell",
  "command": "sh",
  "args": ["/config/bin/bootstrap.sh"],
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
  {
    "id": "gh_user",
    "type": "promptString",
    "description": "GitHub username (required)",
    "default": "${env:GH_USER}"
  },
  {
    "id": "gh_pat",
    "type": "promptString",
    "description": "GitHub PAT (classic; scopes: user:email, admin:public_key)",
    "password": true
  },
  {
    "id": "git_email",
    "type": "promptString",
    "description": "Git email (optional; leave empty to auto-detect)",
    "default": ""
  },
  {
    "id": "git_name",
    "type": "promptString",
    "description": "Git name (optional; default = GH_USER)",
    "default": "${env:GIT_NAME}"
  },
  {
    "id": "git_repos",
    "type": "promptString",
    "description": "Repos to clone (comma-separated owner/repo[#branch] or URLs)",
    "default": "${env:GIT_REPOS}"
  }
]
JSON

  cat >"$KB_OBJ" <<'JSON'
{
  "key": "ctrl+alt+g",
  "command": "workbench.action.tasks.runTask",
  "args": "Bootstrap GitHub Workspace",
  "when": "editorTextFocus"
}
JSON

  # If jq is present, do precise JSON merges. Otherwise: create-if-missing and never overwrite.
  if command -v jq >/dev/null 2>&1; then
    # ----- tasks.json merge -----
    if [ -f "$TASKS_JSON" ]; then
      # Ensure tasks.json has expected structure and merge/replace only our task + inputs
      tmp_out="$TMPD/tasks.out.json"
      jq \
        --slurpfile newtask "$TASK_OBJ" \
        --slurpfile newinputs "$INPUTS_ARR" '
          # If file is empty or not an object, start from a base
          ( . // {} ) as $root
          | ($root.tasks // []) as $tasks
          | ($root.inputs // []) as $inputs
          | $root
          # Keep version if present, else set
          | .version = ( .version // "2.0.0" )
          # Replace/insert our one task by .label
          | .tasks = (
              ($tasks | map(select(.label != $newtask[0].label)))
              + [ $newtask[0] ]
            )
          # For inputs: replace/insert each of our inputs by .id independently
          | .inputs = (
              reduce $newinputs[0][] as $ni (
                ($inputs // []);
                ( map(select(.id != $ni.id)) + [ $ni ] )
              )
            )
        ' "$TASKS_JSON" > "$tmp_out" && mv "$tmp_out" "$TASKS_JSON"
      chown "$PUID:$PGID" "$TASKS_JSON"
      log "Updated user tasks.json (merged Bootstrap task + inputs)"
    else
      # Create minimal tasks.json with just our task + inputs
      printf '%s\n' '{}' > "$TASKS_JSON"
      tmp_out="$TMPD/tasks.out.json"
      jq \
        --slurpfile newtask "$TASK_OBJ" \
        --slurpfile newinputs "$INPUTS_ARR" '
          {
            "version": "2.0.0",
            "tasks": [ $newtask[0] ],
            "inputs": $newinputs[0]
          }
        ' "$TASKS_JSON" > "$tmp_out" && mv "$tmp_out" "$TASKS_JSON"
      chown "$PUID:$PGID" "$TASKS_JSON"
      log "Created user tasks.json with Bootstrap task"
    fi

    # ----- keybindings.json merge -----
    if [ -f "$KEYB_JSON" ]; then
      tmp_out="$TMPD/keybindings.out.json"
      jq \
        --slurpfile kb "$KB_OBJ" '
          # keybindings.json is an array; ensure array
          ( . // [] ) as $arr
          # Replace/insert our binding by (command,args) tuple
          | ( $arr | map(select(.command != $kb[0].command or .args != $kb[0].args)) )
            + [ $kb[0] ]
        ' "$KEYB_JSON" > "$tmp_out" && mv "$tmp_out" "$KEYB_JSON"
      chown "$PUID:$PGID" "$KEYB_JSON"
      log "Updated user keybindings.json (merged Bootstrap shortcut)"
    else
      cp "$KB_OBJ" "$KEYB_JSON"
      chown "$PUID:$PGID" "$KEYB_JSON"
      log "Created user keybindings.json with Bootstrap shortcut"
    fi

  else
    # No jq → do not risk overwriting dev customizations.
    # Create files only if missing; otherwise, warn.
    if [ ! -f "$TASKS_JSON" ]; then
      mkdir -p "$USER_DIR"
      cat > "$TASKS_JSON" <<'JSON'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Bootstrap GitHub Workspace",
      "type": "shell",
      "command": "sh",
      "args": ["/config/bin/bootstrap.sh"],
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
      log "WARNING: jq not found; tasks.json exists → leaving user customizations untouched (no merge)."
    fi

    if [ ! -f "$KEYB_JSON" ]; then
      cp "$KB_OBJ" "$KEYB_JSON"
      chown "$PUID:$PGID" "$KEYB_JSON"
      log "Installed user keybindings.json (jq not found; created minimal file)"
    else
      log "WARNING: jq not found; keybindings.json exists → leaving user customizations untouched (no merge)."
    fi
  fi
}
