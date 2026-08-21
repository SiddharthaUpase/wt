#!/bin/bash
# Runs inside the peek popup. Attaches to the session with the `peek` key-table
# active, so Esc cancels and the Fn keys jump in; the table is restored on exit
# because the same session is also shown in the main pane, where those keys must
# behave normally again.
WT="$HOME/.local/bin/wt"
name="${1:-}"
[ -z "$name" ] && exit 0

if ! tmux -L wt has-session -t "=$name" 2>/dev/null; then
  # the scratch session is created on demand; anything else is simply gone
  [ "$name" = scratch ] && exec "$WT" scratch --attach
  exit 0
fi

restore() { tmux -L wt set-option -t "$name" key-table root 2>/dev/null; }
trap restore EXIT

tmux -L wt set-option -t "$name" key-table peek 2>/dev/null
env TMUX= tmux -L wt -f "$HOME/.config/wt/inner.conf" attach -t "=$name"
