#!/usr/bin/env sh
set -eu
log(){ echo "[restartgate] $*"; }

# Find a Node binary shipped with code-server
NODE_BIN=""
for p in /usr/local/bin/node /usr/bin/node /app/code-server/lib/node /usr/lib/code-server/lib/node; do
  if [ -x "$p" ]; then NODE_BIN="$p"; break; fi
done
if [ -z "${NODE_BIN:-}" ]; then
  log "ERROR: Node binary not found; cannot start restart gate"
  exit 0
fi
log "using node at: $NODE_BIN"

# Tiny HTTP server (hits s6 after it's ready; errors silenced)
mkdir -p /usr/local/bin
cat >/usr/local/bin/restartgate.js <<'EOF'
const http = require('http');
const { exec } = require('child_process');
const PORT = 9000;
const HOST = '127.0.0.1';

function supervisedRestart() {
  const cmd = 'sh -c \'for i in 1 2 3 4 5; do [ -p /run/s6/scan-control ] && break; sleep 0.4; done; ' +
              's6-svscanctl -t /run/s6 >/dev/null 2>&1 || kill -TERM 1 >/dev/null 2>&1\'';
  exec(cmd, () => {});
}

const srv = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === '/health') { res.writeHead(200,{'Content-Type':'text/plain'}).end('OK'); return; }
  if (url === '/restart') {
    res.writeHead(200,{'Content-Type':'text/plain'}).end('OK');
    supervisedRestart();
    return;
  }
  res.writeHead(200,{'Content-Type':'text/plain'}).end('OK');
});

srv.listen(PORT, HOST, () => {
  console.log(`[restartgate] listening on ${HOST}:${PORT} (/restart to restart, /health no-op)`);
});
EOF
chmod 755 /usr/local/bin/restartgate.js

# s6 service: also handles first-boot marker quietly
mkdir -p /etc/services.d/restartgate
cat >/etc/services.d/restartgate/run <<EOF
#!/usr/bin/env sh
MARKER="/config/.gitstrap/.firstboot-auth-restart"

# If first-boot restart was queued, do a quiet supervised restart once s6 is ready
if [ -f "\$MARKER" ]; then
  echo "[restartgate] first-boot marker found; scheduling supervised restart"
  rm -f "\$MARKER" || true
  (
    for i in 1 2 3 4 5; do
      [ -p /run/s6/scan-control ] && break
      sleep 0.4
    done
    s6-svscanctl -t /run/s6 >/dev/null 2>&1 || kill -TERM 1 >/dev/null 2>&1
  ) &
fi

# Start the HTTP gate
exec "$NODE_BIN" /usr/local/bin/restartgate.js
EOF
chmod +x /etc/services.d/restartgate/run

cat >/etc/services.d/restartgate/finish <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x /etc/services.d/restartgate/finish

log "installed restart gate (Node) on 127.0.0.1:9000"
