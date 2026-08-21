#!/bin/bash
# Hub-side half of the Fn peek. $1 = key name (F1..F8), $2 = clicking client tty.
#
# First press opens the key's session in a corner popup for a quick look.
# Second press (handled inside the popup by peek-jump.sh) promotes it to the
# main pane. Esc cancels. Silent by design: tmux renders run-shell output by
# dropping the active pane into copy mode, which would hide the sidebar.
CONF="$HOME/.config/wt"
KEYS="$HOME/.local/state/wt/keys"
key="${1:-}"
client="${2:-}"
[ -z "$key" ] && exit 0

name=$(cat "$KEYS/$key" 2>/dev/null)
[ -z "$name" ] && exit 0

# already peeking this session? then this press is the "jump in" — the popup's
# own binding normally handles it, but honour it here too for the hub client
main_tty=$(tmux -L wt-hub list-panes -t hub -F '#{pane_tty} #{pane_start_command}' 2>/dev/null \
           | grep attach | awk '{print $1}' | head -1)
peek_tty=$(tmux -L wt list-clients -F '#{client_tty} #{client_session}' 2>/dev/null \
           | awk -v n="$name" -v m="$main_tty" '$2==n && $1!=m {print $1; exit}')
if [ -n "$peek_tty" ]; then
  "$CONF/peek-jump.sh" "$name" "$peek_tty"
  exit 0
fi

[ -z "$client" ] && client=$(tmux -L wt-hub list-clients -F '#{client_tty}' 2>/dev/null | head -1)
[ -z "$client" ] && exit 0

tmux -L wt-hub display-popup -c "$client" \
  -T " $name · Esc cancels · $key jumps in " \
  -E -w 55% -h 55% -x 0 -y S \
  "$CONF/peek-attach.sh '$name'"
exit 0
