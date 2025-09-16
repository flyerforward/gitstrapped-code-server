#!/usr/bin/env sh
set -eu

log(){ echo "[codepass] $*"; }
ensure_dir(){ mkdir -p "$1" 2>/dev/null || true; }

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
export HOME="${HOME:-/config}"

STATE_DIR="$HOME/.gitstrap"
HASH_FILE="$STATE_DIR/codepass.hash"          # <-- hashed password goes here

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

  ensure_dir "$(dirname "$TASKS")"
  ensure_dir "$(dirname "$KEYB")"

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

    # keybindings.json upsert (array)
    tmp="$(mktemp)"
    if [ -f "$KEYB" ] && jq -e . "$KEYB" >/dev/null 2>&1; then
      jq --argjson kb "$KB_JSON" '
        if type=="array"
        then if any(.[]?; (.command? // "")=="workbench.action.tasks.runTask" && (.args? // "")=="Change code-server password")
             then map(if (.command? // "")=="workbench.action.tasks.runTask" && (.args? // "")=="Change code-server password" then $kb else . end)
             else . + [ $kb ] end
        else [ $kb ] end
      ' "$KEYB" > "$tmp" && mv "$tmp" "$KEYB"
    else
      printf '[%s]\n' "$KB_JSON" > "$KEYB"
    fi
  else
    # no jq → create-only
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

# ---- hashing helpers (Argon2) ----
try_hash_with(){
  # $1 = program (npx|corepack) ; $2... = args
  prog="$1"; shift
  if command -v "$prog" >/dev/null 2>&1; then
    out="$(printf '%s' "$NEW" | "$prog" "$@" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -q '^\$argon2'; then
      printf '%s' "$out"; return 0
    fi
  fi
  return 1
}

make_argon2_hash(){
  # Prefer npx argon2-cli; fall back to pnpm/yarn dlx if available
  # Official docs recommend argon2-cli for code-server hashed-password. :contentReference[oaicite:2]{index=2}
  if h="$(try_hash_with npx --yes argon2-cli -e)"; then printf '%s' "$h"; return 0; fi
  if h="$(try_hash_with corepack pnpm dlx argon2-cli -e)"; then printf '%s' "$h"; return 0; fi
  if h="$(try_hash_with corepack yarn dlx argon2-cli -s -q -y argon2-cli -e)"; then printf '%s' "$h"; return 0; fi

  echo "Error: could not generate Argon2 hash (need npx or pnpm/yarn via corepack)." >&2
  echo "Hint: Internet access is required the first time to fetch argon2-cli." >&2
  return 1
}

trigger_restart_gate(){
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 3 "http://127.0.0.1:9000/restart" >/dev/null 2>&1; then
      log "restart gate responded at 127.0.0.1:9000/restart"
    else
      log "WARN: restart trigger failed (cannot reach 127.0.0.1:9000)"
    fi
  else
    log "curl not found; please restart the container manually"
  fi
}

write_hashed_and_restart(){
  NEW="${1:-}"; CONF="${2:-}"
  [ -n "$NEW" ]  || { echo "Error: password is required." >&2; exit 1; }
  [ -n "$CONF" ] || { echo "Error: confirmation is required." >&2; exit 1; }
  [ "$NEW" = "$CONF" ] || { echo "Error: passwords do not match." >&2; exit 1; }
  [ ${#NEW} -ge 8 ] || { echo "Error: password must be at least 8 characters." >&2; exit 1; }

  ensure_dir "$STATE_DIR"

  hash="$(NEW="$NEW" make_argon2_hash)" || exit 1

  # Write hash without trailing newline
  printf '%s' "$hash" > "$HASH_FILE"
  chmod 644 "$HASH_FILE" || true
  chown "$PUID:$PGID" "$HASH_FILE" 2>/dev/null || true
  sync || true

  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  size="$(wc -c < "$HASH_FILE" 2>/dev/null || echo 0)"
  headsig="$(cut -c1-16 < "$HASH_FILE" 2>/dev/null || true)"
  log "hashed password saved to $HASH_FILE (utc=$ts bytes=$size head=${headsig}...)"
  log "container will restart; code-server will read HASHED_PASSWORD from file (takes precedence over PASSWORD)."

  trigger_restart_gate
  exit 0
}

case "${1:-init}" in
  init) install_task ;;
  set)  shift; write_hashed_and_restart "${1:-}" "${2:-}" ;;
  *)    install_task ;;
esac
