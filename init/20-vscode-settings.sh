#!/usr/bin/env sh
set -eu

USER_DIR="/config/data/User"
mkdir -p "$USER_DIR"
SETTINGS="$USER_DIR/settings.json"

cat > "$SETTINGS" <<'JSON'
{
  // Keep GitHub extensions from trying to own auth
  "github.gitAuthentication": false,
  "git.terminalAuthentication": false,

  // Avoid Settings Sync login prompts
  "settingsSync.enabled": false,

  // Minor QoL
  "git.confirmSync": false,
  "extensions.ignoreRecommendations": true
}
JSON

chown -R "${PUID:-1000}:${PGID:-1000}" "$USER_DIR"
echo "[vscode-settings] seeded $SETTINGS"
