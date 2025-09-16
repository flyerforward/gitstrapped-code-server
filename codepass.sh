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

  ensure_dir "$(dirname "$TASKS")"; ensure_dir "$(dirname "$KEYB")"
  if command -v jq >/dev/null 2>&1; then
    # tasks.json upsert
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
    # keybindings.json upsert
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

trigger_restart_hook(){
  # Notify the sidecar over HTTP to restart this container
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 http://code-server-restartd:9000/ >/dev/null 2>&1 || true
    log "sent restart trigger to sidecar (http://code-server-restartd:9000/)"
  else
    log "curl not found; restart sidecar cannot be triggered (please restart container manually)"
  fi
}

write_password_and_exit_ok(){
  NEW="${1:-}"
  CONF="${2:-}"

  [ -n "$NEW" ]  || { echo "Error: password is required." >&2; exit 1; }
  [ -n "$CONF" ] || { echo "Error: confirmation is required." >&2; exit 1; }
  [ "$NEW" = "$CONF" ] || { echo "Error: passwords do not match." >&2; exit 1; }
  [ ${#NEW} -ge 8 ] || { echo "Error: password must be at least 8 characters." >&2; exit 1; }

  ensure_dir "$STATE_DIR"
  printf '%s' "$NEW" > "$PASS_FILE"
  chmod 644 "$PASS_FILE" || true
  chown "$PUID:$PGID" "$PASS_FILE" 2>/dev/null || true
  sync || true

  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  size="$(wc -c < "$PASS_FILE" 2>/dev/null || echo 0)"
  sum="$(cksum "$PASS_FILE" 2>/dev/null | awk "{print \$1 \"-\" \$2}" || echo "n/a")"
  log "password saved to $PASS_FILE (utc=$ts bytes=$size cksum=$sum)"
  log "container will restart via sidecar and new password will apply at next start"

  trigger_restart_hook
  exit 0
}

case "${1:-init}" in
  init) install_task ;;
  set)  shift; write_password_and_exit_ok "${1:-}" "${2:-}" ;;
  *)    install_task ;;
esac
