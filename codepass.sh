#!/usr/bin/env sh
set -eu

log(){ echo "[codepass] $*"; }
ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; }

# Container defaults
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
export HOME="${HOME:-/config}"

CONFIG_DIR="$HOME/.config/code-server"
CONFIG="$CONFIG_DIR/config.yaml"
STATE_DIR="$HOME/.gitstrap"

TASKS="$HOME/data/User/tasks.json"
KEYB="$HOME/data/User/keybindings.json"

yaml_quote() {
  # minimal YAML-safe double-quoted string
  # escape backslashes and double quotes
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

install_task(){
  # Run as a *process* (no shell), so special chars like ! are safe.
  TASK_JSON='{
    "label": "Change code-server password",
    "type": "process",
    "command": "/custom-cont-init.d/20-codepass.sh",
    "args": ["set", "${input:new_password}", "${input:confirm_password}"],
    "problemMatcher": []
  }'

  INPUTS_JSON='[
    { "id": "new_password",     "type": "promptString", "description": "Enter a NEW code-server password", "password": true },
    { "id": "confirm_password", "type": "promptString", "description": "Confirm the NEW password", "password": true }
  ]'

  # Keybinding (Ctrl+Alt+P)
  KB_JSON='{
    "key": "ctrl+alt+p",
    "command": "workbench.action.tasks.runTask",
    "args": "Change code-server password"
  }'

  ensure_dir "$(dirname "$TASKS")"
  ensure_dir "$(dirname "$KEYB")"

  if command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    if [ -f "$TASKS" ] && jq -e . "$TASKS" >/dev/null 2>&1; then
      jq \
        --argjson newtask "$TASK_JSON" \
        --argjson newinputs "$INPUTS_JSON" '
          (. // {}) as $r
          | .version = (.version // "2.0.0")
          | .tasks  = (
              ($r.tasks // []) as $t
              | if any($t[]?; .label == $newtask.label) then
                  $t | map(if .label == $newtask.label then $newtask else . end)
                else
                  $t + [ $newtask ]
                end
            )
          | .inputs = (
              ($r.inputs // []) as $i
              | reduce ($newinputs[]) as $n ($i;
                  if any(.[]?; (.id? // "") == $n.id) then
                    map(if (.id? // "") == $n.id then $n else . end)
                  else
                    . + [ $n ]
                  end)
            )
        ' "$TASKS" > "$tmp" && mv "$tmp" "$TASKS"
    else
      printf '%s\n' "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)" > "$TASKS"
    fi

    tmp="$(mktemp)"
    if [ -f "$KEYB" ] && jq -e . "$KEYB" >/dev/null 2>&1; then
      jq \
        --argjson kb "$KB_JSON" '
          if type=="array" then
            if any(.[]?; (.command? // "") == "workbench.action.tasks.runTask" and (.args? // "") == "Change code-server password") then
              map(if (.command? // "") == "workbench.action.tasks.runTask" and (.args? // "") == "Change code-server password" then $kb else . end)
            else
              . + [ $kb ]
            end
          else
            [ $kb ]
          end
        ' "$KEYB" > "$tmp" && mv "$tmp" "$KEYB"
    else
      printf '[%s]\n' "$KB_JSON" > "$KEYB"
    fi
  else
    [ -f "$TASKS" ] || printf '%s\n' "$(cat <<JSON
{
  "version": "2.0.0",
  "tasks": [ $TASK_JSON ],
  "inputs": $INPUTS_JSON
}
JSON
)" > "$TASKS"
    [ -f "$KEYB" ]  || printf '[%s]\n' "$KB_JSON" > "$KEYB"
  fi

  chown "$PUID:$PGID" "$TASKS" "$KEYB" 2>/dev/null || true
  log "installed VS Code task & keybinding"
}

apply_plain_password(){
  NEW="$1"
  ensure_dir "$CONFIG_DIR"
  # Backup if present
  [ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.bak.$(date +%s)" || :

  tmp="$(mktemp)"
  if [ -f "$CONFIG" ]; then
    # remove any previous auth/password/hashed-password lines
    grep -vE '^[[:space:]]*(auth|password|hashed-password)[[:space:]]*:' "$CONFIG" > "$tmp" || true
  else
    : > "$tmp"
  fi
  esc="$(yaml_quote "$NEW")"
  {
    echo
    echo "auth: password"
    printf 'password: "%s"\n' "$esc"
  } >> "$tmp"

  mv "$tmp" "$CONFIG"
  chown "$PUID:$PGID" "$CONFIG" 2>/dev/null || true
  log "updated $CONFIG with new *plain* password"
}

restart_codeserver(){
  # Kill the server; s6 will bring it back.
  pkill -f "/app/code-server" 2>/dev/null || \
  pkill -f "node.*code-server" 2>/dev/null || true
  log "code-server restarting with new password…"
}

cmd_set(){
  NEW="${1:-}"
  CONF="${2:-}"

  [ -n "$NEW" ] || { echo "Error: password is required." >&2; exit 1; }
  [ -n "$CONF" ] || { echo "Error: confirmation is required." >&2; exit 1; }
  [ "$NEW" = "$CONF" ] || { echo "Error: passwords do not match." >&2; exit 1; }
  [ ${#NEW} -ge 8 ] || { echo "Error: password must be at least 8 characters." >&2; exit 1; }

  ensure_dir "$STATE_DIR"
  printf '%s' "$NEW" > "$STATE_DIR/codepass.plain"
  chmod 600 "$STATE_DIR/codepass.plain" || true
  chown "$PUID:$PGID" "$STATE_DIR/codepass.plain" 2>/dev/null || true

  apply_plain_password "$NEW"
  restart_codeserver
}

case "${1:-init}" in
  set) shift; cmd_set "$@";;
  init|*) install_task;;
esac
