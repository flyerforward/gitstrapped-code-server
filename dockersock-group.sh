#!/usr/bin/env sh
set -eu

log(){ echo "[dockersock] $*"; }

SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
[ -S "$SOCK" ] || { log "no docker.sock at $SOCK; skipping"; exit 0; }

# Determine GID of the socket (portable: try stat, fallback to ls)
gid="$( (stat -c %g "$SOCK" 2>/dev/null) || ls -ln "$SOCK" | awk '{print $4}' )"
case "$gid" in ''|*[!0-9]*) log "cannot determine gid for $SOCK; skipping"; exit 0;; esac

# Figure out the username for PUID (linuxserver images use 'abc')
user="$(getent passwd "${PUID:-1000}" | cut -d: -f1 || true)"
[ -n "$user" ] || user="abc"

# If a group with that GID exists, use it; otherwise create one (name doesn't matter, GID does)
gname="$(getent group "$gid" | cut -d: -f1 || true)"
if [ -z "$gname" ]; then
  gname="dockersock"
  if getent group "$gname" >/dev/null 2>&1; then
    gname="dockersock_${gid}"
  fi
  addgroup -g "$gid" "$gname" 2>/dev/null || true
  log "created group $gname (gid $gid)"
else
  log "found existing group $gname (gid $gid)"
fi

# Add the runtime user to that group (busybox/alpine: addgroup USER GROUP)
if id "$user" | tr ' ' '\n' | grep -qE "(^|,)${gname}(,|$)"; then
  log "user $user already in group $gname"
else
  addgroup "$user" "$gname" 2>/dev/null || true
  log "added $user to group $gname for docker.sock access"
fi
