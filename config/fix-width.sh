#!/bin/bash
# Restore the sidebar pane ($1) to the user's chosen width after terminal rescales.
w=$(cat "$HOME/.local/state/wt/sidebar-width" 2>/dev/null || echo 28)
tmux -L wt-hub resize-pane -t "$1" -x "$w" 2>/dev/null
