#!/usr/bin/env sh
set -eu
log(){ echo "[restartgate] $*"; }

# Create a tiny HTTP CGI endpoint at 127.0.0.1:9000 using busybox httpd
mkdir -p /www/cgi-bin

cat >/www/cgi-bin/restart <<'EOF'
#!/usr/bin/env sh
# Minimal CGI: always reply OK, then ask s6 to exit so Docker restarts container.
echo "Status: 200 OK"
echo "Content-Type: text/plain"
echo
echo OK
# Try graceful supervised shutdown; Docker will restart the container (restart: always)
if command -v s6-svscanctl >/dev/null 2>&1; then
  s6-svscanctl -t /run/s6 || true
else
  # Fallback (rare): send TERM to PID 1
  kill -TERM 1 || true
fi
EOF
chmod +x /www/cgi-bin/restart

# s6 service to keep the HTTP gate running
mkdir -p /etc/services.d/restartgate

cat >/etc/services.d/restartgate/run <<'EOF'
#!/usr/bin/env sh
# -f: foreground, -p: port, -h: docroot
exec busybox httpd -f -p 127.0.0.1:9000 -h /www
EOF
chmod +x /etc/services.d/restartgate/run

# No-op finish (quiet restarts)
cat >/etc/services.d/restartgate/finish <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x /etc/services.d/restartgate/finish

log "installed restart gate on 127.0.0.1:9000 (GET /cgi-bin/restart)"
