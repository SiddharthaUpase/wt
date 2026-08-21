#!/bin/bash
# Second press of the Fn key: promote the peeked session into the main pane and
# close the popup. $1 = session, $2 = the popup client's tty.
WT="$HOME/.local/bin/wt"
name="${1:-}"
peek_tty="${2:-}"
[ -z "$name" ] && exit 0

"$WT" open "$name" >/dev/null 2>&1
tmux -L wt set-option -t "$name" key-table root 2>/dev/null
[ -n "$peek_tty" ] && tmux -L wt detach-client -t "$peek_tty" 2>/dev/null
exit 0
