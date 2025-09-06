#!/usr/bin/env sh
set -eu

sed -i 's/\r$//' /config/bin/bootstrap.sh 2>/dev/null || true

# Always install/merge user-level Task + keybinding
sh /config/bin/bootstrap.sh install-task || true

# Auto-bootstrap if env present (idempotent)
if [ -n "${GH_USER:-}" ] && [ -n "${GH_PAT:-}" ]; then
  echo "[init] GH_USER/GH_PAT present → running bootstrap"
  sh /config/bin/bootstrap.sh || true
else
  echo "[init] GH_USER/GH_PAT missing → skip auto-bootstrap (use Ctrl+Alt+G or palette task)"
fi
