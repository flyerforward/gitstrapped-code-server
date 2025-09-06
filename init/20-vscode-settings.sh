#!/usr/bin/env sh
set -eu

USER_DIR="/config/data/User"
mkdir -p "$USER_DIR"
SETTINGS="$USER_DIR/settings.json"

cat > "$SETTINGS" <<'JSON'
{
  "some": "settings"
}
JSON

chown -R "${PUID:-1000}:${PGID:-1000}" "$USER_DIR"
echo "[vscode-settings] seeded $SETTINGS"
