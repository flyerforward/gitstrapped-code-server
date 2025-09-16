#!/usr/bin/env sh
set -eu

log(){ echo "[codepass] $*"; }
ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; }

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
export HOME="${HOME:-/config}"

STATE_DIR="$HOME/.gitstrap"
PASS_FILE="$STATE_DIR/codepass.txt"

TASKS="$HOME/data/User/tasks.json"
KEYB="$HOME/data/User/keybindings.json"

install_task(){
  # Run via /bin/sh so the script doesn't need +x; special chars like ! are safe.
  TASK_JSON='{
    "label": "Change code-server password",
    "type": "process",
    "command": "/bin/sh",
    "args": ["/custom-cont-init.d/20-codepass.sh","set","${input:new_password}","${input:confirm_password}"],
    "problemMatcher": []
  }'
  INPUTS_JSON='[
    { "id": "new_password",     "type": "promptString", "description": "Enter a NEW code-server password", "password": true },
    { "id": "confirm_password", "type": "promptString", "description": "Confirm the NEW password", "password": true }
  ]'
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
      jq --argjson newtask "$TASK_JSON" --argjson newinputs "$INPUTS_JSON" '
        (. // {}) as $r
        | .version = (.version // "2.0.0")
        | .tasks = (
            ($r.tasks // []) as $t
            | if any($t[]?; .label == $newtask.label)
              then $t | map(if .label == $newtask.label then $newtask else . end)
              else $t + [ $newtask ] end)
        | .inputs = (
            ($r.inputs // []) as $i
            | reduce ($newinputs[]) as $n ($i;
                if any(.[]?; (.id? // "") == $n.id)
                then map(if (.id? // "") == $n.id then $n else . end)
                else . + [ $n ] end) )
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
      jq --argjson kb "$KB_JSON" '
        if type=="array"
        then if any(.[]?; (.command? // "")=="workbench.action.tasks.runTask" and (.args? // "")=="Change code-server password")
             then map(if (.command? // "")=="workbench.action.tasks.runTask" and (.args? // "")=="Change code-server password" then $kb else . end)
             else . + [ $kb ] end
        else [ $kb ] end
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

restart_container(){
  log "requesting supervised shutdown so Docker restarts the container..."
  # s6-overlay v3 (LinuxServer.io images)
  if command -v s6-svscanctl >/dev/null 2>&1; then
    for dir in /run/service /run/s6/services /run/s6; do
      if [ -d "$dir" ]; then
        if s6-svscanctl -t "$dir" 2>/dev/null; then
          log "signalled s6 supervisor at $dir"
          exit 0
        fi
      fi
    done
  fi
  # Last resort: try to terminate PID 1 (usually root-owned; may fail for non-root users)
  if kill -TERM 1 2>/dev/null; then
    log "sent TERM to PID 1"
    exit 0
  fi

  echo "Error: couldn't restart container automatically (likely due to permissions). Please 'docker restart <container>' once; the new password is already saved at $PASS_FILE." >&2
  exit 1
}

write_password_and_restart(){
  NEW="$1"; CONF="$2"
  [ -n "$NEW" ]  || { echo "Error: password is required." >&2; exit 1; }
  [ -n "$CONF" ] || { echo "Error: confirmation is required." >&2; exit 1; }
  [ "$NEW" = "$CONF" ] || { echo "Error: passwords do not match." >&2; exit 1; }
  [ ${#NEW} -ge 8 ] || { echo "Error: password must be at least 8 characters." >&2; exit 1; }

  ensure_dir "$STATE_DIR"
  printf '%s' "$NEW" > "$PASS_FILE"
  chmod 600 "$PASS_FILE" || true
  chown "$PUID:$PGID" "$PASS_FILE" 2>/dev/null || true
  log "wrote new password to $PASS_FILE (used via FILE__PASSWORD at boot)"

  restart_container
}

case "${1:-init}" in
  init) install_task ;;
  set)  shift; write_password_and_restart "${1:-}" "${2:-}" ;;
  *)    install_task ;;
esac
