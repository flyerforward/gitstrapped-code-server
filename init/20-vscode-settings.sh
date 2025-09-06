#!/usr/bin/env sh
set -eu
CFG_DIR="/config/data/User"
CFG_FILE="$CFG_DIR/settings.json"

mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_FILE" ]; then
  cat > "$CFG_FILE" <<'JSON'
{
  "git.autoRepositoryDetection": true,
  "git.repositoryScanMaxDepth": 4,
  "git.openRepositoryInParentFolders": "always",
  "security.workspace.trust.enabled": false,
  "workbench.startupEditor": "none"
}
JSON
  echo "[vscode-settings] seeded $CFG_FILE"
else
  # merge/patch minimal keys if file exists
  tmp="$CFG_FILE.tmp.$$"
  awk '
    BEGIN{ set["git.autoRepositoryDetection"]=1; set["git.repositoryScanMaxDepth"]=1; set["git.openRepositoryInParentFolders"]=1; set["security.workspace.trust.enabled"]=1 }
    { print } END{
      print ""
    }' "$CFG_FILE" > "$tmp" && mv "$tmp" "$CFG_FILE"
  echo "[vscode-settings] left existing $CFG_FILE unchanged"
fi
chown -R "${PUID:-1000}:${PGID:-1000}" "/config/data"
