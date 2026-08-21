#!/bin/bash
# Runs in the local pane of a remote session: keeps a client attached to the
# remote copy. Reconnects after sleep/network drops. Exits when the session is
# un-marked (no longer remote).
#
# Marker file: line 1 = ssh host · line 2 = container name (container mode only).
# Without line 2 the session lives directly on the host's tmux (VM mode).
name="$1"
[ -z "$name" ] && exit 1
MARK="$HOME/.local/state/wt/vm/$name"
while true; do
  host=$(head -1 "$MARK" 2>/dev/null) || exit 0
  [ -z "$host" ] && exit 0
  cname=$(sed -n 2p "$MARK" 2>/dev/null)
  if [ -n "$cname" ]; then
    ssh -t -o ConnectTimeout=8 "$host" \
      "docker exec -it '$cname' tmux -L wt attach -t '=$name'"
  else
    ssh -t -o ConnectTimeout=8 "$host" "tmux -L wt attach -t '=$name'"
  fi
  [ -f "$MARK" ] || exit 0
  clear
  printf '\n  ☁ reconnecting to %s on %s …\n' "$name" "$host"
  sleep 2
done
