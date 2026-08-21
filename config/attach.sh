#!/bin/bash
# Runs in the hub's right pane: keeps an inner-server client alive.
while true; do
  if tmux -L wt has-session 2>/dev/null; then
    TMUX= tmux -L wt -f "$HOME/.config/wt/inner.conf" attach
  else
    clear
    printf '\n\n   no sessions yet — press n in the sidebar to create a worktree\n'
    sleep 2
  fi
done
