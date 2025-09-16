#!/usr/bin/env sh
set -eu
log(){ echo "[restartgate] $*"; }

# Pick a Node binary that exists in this image
NODE_BIN=""
for p in /usr/local/bin/node /usr/bin/node /app/code-server/lib/node /usr/lib/code-server/lib/node; do
  if [ -x "$p" ]; then NODE_BIN="$p"; break; fi
done
if [ -z "${NODE_BIN:-}" ]; then
  log "ERROR: Node binary not found; cannot start restart gate"
  exit 0
fi
log "using node at: $NODE_BIN"

# Tiny HTTP server
mkdir -p /usr/local/bin
cat >/usr/local/bin/restartgate.js <<'EOF'
const http = require('http');
const { exec } = require('child_process');
const PORT = 9000;
const HOST = '127.0.0.1';

const srv = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === '/health') {
    res.writeHead(200, {'Content-Type':'text/plain'}); res.end('OK'); return;
  }
  if (url === '/restart') {
    res.writeHead(200, {'Content-Type':'text/plain'}); res.end('OK');
    exec('s6-svscanctl -t /run/s6 || kill -TERM 1', () => {});
    return;
  }
  res.writeHead(200, {'Content-Type':'text/plain'}); res.end('OK');
});

srv.listen(PORT, HOST, () => {
  console.log(`[restartgate] listening on ${HOST}:${PORT} (/restart to restart, /health no-op)`);
});
EOF
chmod 755 /usr/local/bin/restartgate.js

# s6 service to run the server
mkdir -p /etc/services.d/restartgate
cat >/etc/services.d/restartgate/run <<'EOF'
#!/usr/bin/env sh
MARKER="/config/.gitstrap/.firstboot-auth-restart"

# If a first-boot restart was queued, schedule it and remove the marker
if [ -f "$MARKER" ]; then
  echo "[restartgate] first-boot marker found; scheduling immediate supervised restart"
  rm -f "$MARKER" || true
  ( sleep 1; s6-svscanctl -t /run/s6 || kill -TERM 1 ) &
fi

# Start the HTTP gate
exec /app/code-server/lib/node /usr/local/bin/restartgate.js
EOF
chmod +x /etc/services.d/restartgate/run

# Quiet finish script
cat >/etc/services.d/restartgate/finish <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x /etc/services.d/restartgate/finish

log "installed restart gate (Node) on 127.0.0.1:9000"
