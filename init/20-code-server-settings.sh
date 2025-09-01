#!/usr/bin/env sh
set -eu

USER_DIR="/config/data/User"
mkdir -p "$USER_DIR"

# Merge/seed settings that suppress GitHub sign-in UX and let plain Git handle auth
SETTINGS="$USER_DIR/settings.json"

# If a settings.json already exists, append keys safely; otherwise create it.
# For simplicity here we just create/overwrite. If you need merge behavior, say the word and I’ll swap this to a jq merge.
cat > "$SETTINGS" <<'JSON'
{
  "github.gitAuthentication": false,
  "git.terminalAuthentication": false,
  "git.confirmSync": false
}
JSON

# Ownership for LSIO user
chown -R "${PUID:-1000}:${PGID:-1000}" "$USER_DIR"
echo "[vscode-settings] seeded $SETTINGS"
