#!/bin/bash
# Mirrors VM status files into the local status dir for VM-elevated sessions,
# and raises the local macOS notifications the VM cannot send. Single instance
# via pidfile; exits when no session is marked as on-VM.
STATE="$HOME/.local/state/wt"
VMSTATE="$STATE/vm"
PIDF="$VMSTATE/poller.pid"

mkdir -p "$VMSTATE" "$STATE/status"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then exit 0; fi
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' EXIT

while true; do
  marks=$(ls "$VMSTATE" 2>/dev/null | grep -v '^poller')
  [ -z "$marks" ] && exit 0
  hosts=$(for m in $marks; do head -1 "$VMSTATE/$m" 2>/dev/null; done \
          | grep -E '^[A-Za-z0-9._-]+$' | sort -u)   # markers hold one hostname line
  for host in $hosts; do
    ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" \
      'cd ~/.local/state/wt/status 2>/dev/null && for f in *; do [ -f "$f" ] && printf "%s|%s\n" "$f" "$(cat "$f")"; done' \
      2>/dev/null | while IFS='|' read -r n st; do
        [ -f "$VMSTATE/$n" ] || continue                # only mirror elevated sessions
        # head -1: markers are two lines (host + container name) in container mode
        [ "$(head -1 "$VMSTATE/$n" 2>/dev/null)" = "$host" ] || continue
        prev=$(cat "$STATE/status/$n" 2>/dev/null)
        [ "$st" = "$prev" ] && continue
        printf '%s\n' "$st" > "$STATE/status/$n"
        case "$st" in
          waiting) osascript -e "display notification \"$n needs your input (vm)\" with title \"wt\" sound name \"Glass\"" >/dev/null 2>&1 & ;;
          idle)    osascript -e "display notification \"$n is done (vm)\" with title \"wt\"" >/dev/null 2>&1 & ;;
        esac
      done

    # --- the return path -------------------------------------------------
    # A container has no route to the laptop or to its siblings: its tmux server
    # holds only itself. So the shim queues outbound messages in the host's
    # outbox, and this loop — already here every few seconds — delivers them
    # with the local `wt send`, which knows how to reach local AND cloud targets.
    for f in $(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" \
                 'ls ~/.local/state/wt/outbox/*.msg ~/.local/state/wt/status/.msg-* 2>/dev/null' 2>/dev/null); do
      body=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "cat '$f'" 2>/dev/null)
      [ -z "$body" ] && continue
      to=$(printf '%s\n' "$body" | sed -n 's/^to: //p' | head -1)
      target=$(printf '%s\n' "$body" | sed -n 's/^target: //p' | head -1)
      newname=$(printf '%s\n' "$body" | sed -n 's/^newname: //p' | head -1)
      from=$(printf '%s\n' "$body" | sed -n 's/^from: //p' | head -1)
      cmd=$(printf '%s\n' "$body" | sed -n 's/^cmd: //p' | head -1)
      branch=$(printf '%s\n' "$body" | sed -n 's/^branch: //p' | head -1)
      msg=$(printf '%s\n' "$body" | sed '1,/^$/d')
      ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "rm -f '$f'" 2>/dev/null

      if [ "$cmd" = clone ]; then
        # a cloud agent cloning itself (or a sibling). Same reasoning as spawn:
        # backgrounded, because a clone takes about a minute and this loop must
        # keep polling status for every session on the host.
        [ -z "$target" ] && continue
        ( if out=$("$HOME/.local/bin/wt" clone "$target" $newname 2>&1); then
            "$HOME/.local/bin/wt" send --from hub "${from:-cloud}" \
              "cloned '$target' — $(printf '%s' "$out" | tail -1)" >/dev/null 2>&1
          else
            "$HOME/.local/bin/wt" send --from hub "${from:-cloud}" \
              "clone FAILED for '$target': $(printf '%s' "$out" | tail -1)" >/dev/null 2>&1
          fi ) >/dev/null 2>&1 &
        continue
      fi

      if [ "$cmd" = spawn ]; then
        # a cloud agent asking for another cloud session. Runs in the background
        # because cnew takes a minute or two and this loop must keep polling.
        [ -z "$msg" ] && continue
        ( n=$(ls "$VMSTATE" 2>/dev/null | grep -vc '^poller')
          if [ "${n:-0}" -ge "${WT_MAX_CLOUD:-20}" ]; then
            "$HOME/.local/bin/wt" send --from hub "${from:-cloud}" \
              "spawn refused: ${WT_MAX_CLOUD:-20} cloud sessions already exist" >/dev/null 2>&1
            exit 0
          fi
          br="${branch:-$("$HOME/.local/bin/wt" slug "$msg")}"
          repo=$(git config --get wt.defaultrepo)
          if "$HOME/.local/bin/wt" cnew -r "$repo" -p "$msg" "$br" >/dev/null 2>&1; then
            "$HOME/.local/bin/wt" send --from hub "${from:-cloud}" \
              "spawned '$("$HOME/.local/bin/wt" name "$br")' on branch $br — it is working on: $msg" >/dev/null 2>&1
          else
            "$HOME/.local/bin/wt" send --from hub "${from:-cloud}" \
              "spawn FAILED for branch $br" >/dev/null 2>&1
          fi ) >/dev/null 2>&1 &
        continue
      fi

      [ -z "$to" ] || [ -z "$msg" ] && continue
      # deliver as if it came from that session, so the receiver sees the sender
      "$HOME/.local/bin/wt" send --from "${from:-cloud}" "$to" "$msg" >/dev/null 2>&1
    done

    # publish the fleet's session list so containers can run `wt ls`
    "$HOME/.local/bin/wt" ls --json 2>/dev/null \
      | ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" \
          'mkdir -p ~/.local/state/wt/outbox && cat > ~/.local/state/wt/sessions.json.tmp \
           && mv ~/.local/state/wt/sessions.json.tmp ~/.local/state/wt/sessions.json' 2>/dev/null
  done
  sleep 3
done
