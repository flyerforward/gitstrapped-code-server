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
PASS_STORE="$STATE_DIR/codepass.hash"

TASKS="$HOME/data/User/tasks.json"
KEYB="$HOME/data/User/keybindings.json"

# --- hash & apply to config.yaml ---
apply_hash_to_config(){
  hash="$1"
  ensure_dir "$CONFIG_DIR"

  # Backup (best-effort)
  [ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.bak.$(date +%s)" || :

  tmp="$(mktemp)"
  if [ -f "$CONFIG" ]; then
    # drop previous auth/password lines
    grep -vE '^[[:space:]]*(auth|password|hashed-password)[[:space:]]*:' "$CONFIG" > "$tmp" || true
  else
    : > "$tmp"
  fi
  {
    echo
    echo "auth: password"
    printf 'hashed-password: "%s"\n' "$hash"
  } >> "$tmp"

  mv "$tmp" "$CONFIG"
  chown "$PUID:$PGID" "$CONFIG" 2>/dev/null || true
  log "updated $CONFIG with new hashed password"
}

# --- create or upsert the VS Code Task & inputs ---
install_task(){
  # Task definition
  TASK_JSON='{
    "label": "Change code-server password",
    "type": "shell",
    "command": "sh",
    "args": ["/custom-cont-init.d/20-codepass.sh","set","${input:new_password}","${input:confirm_password}"],
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
    # tasks.json upsert by label
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

    # keybindings.json upsert (array)
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
    # no jq → create-only (don’t overwrite)
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

# --- set new password flow (called by the task) ---
cmd_set(){
  NEW="${1:-}"
  CONF="${2:-}"

  if [ -z "$NEW" ] || [ -z "$CONF" ]; then
    echo "Error: password and confirmation are required." >&2
    exit 1
  fi
  if [ "$NEW" != "$CONF" ]; then
    echo "Error: passwords do not match." >&2
    exit 1
  fi
  if [ ${#NEW} -lt 8 ]; then
    echo "Error: password must be at least 8 characters." >&2
    exit 1
  fi

  if ! command -v code-server >/dev/null 2>&1; then
    echo "Error: code-server CLI not found in container." >&2
    exit 1
  fi

  HASH="$(code-server hash-password "$NEW" 2>/dev/null | tail -n1)"
  case "$HASH" in ""|*" "*)
    echo "Error: failed to hash password." >&2
    exit 1
  esac

  ensure_dir "$STATE_DIR"
  printf '%s' "$HASH" > "$PASS_STORE"
  chmod 600 "$PASS_STORE" || true
  chown "$PUID:$PGID" "$PASS_STORE" 2>/dev/null || true

  apply_hash_to_config "$HASH"

  # restart only the code-server process; s6 will bring it back
  pkill -f "code-server.*--bind-addr" || true
  log "code-server restarting with new password…"
}

# --- optional: apply saved hash at boot (best-effort) ---
cmd_apply_on_boot(){
  if [ -s "$PASS_STORE" ]; then
    HASH="$(cat "$PASS_STORE")"
    apply_hash_to_config "$HASH"
  fi
}

# -------- main --------
case "${1:-init}" in
  set)             shift; cmd_set "$@";;
  apply-on-boot)   cmd_apply_on_boot;;
  init)            install_task; cmd_apply_on_boot;;
  *)               install_task; cmd_apply_on_boot;;
esac
