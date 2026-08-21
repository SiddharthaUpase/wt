#!/bin/bash
# Claude Code hook -> wt session status. Inert outside wt sessions.
input=$(cat 2>/dev/null || true)   # hook JSON from stdin
[ -z "$WT_SESSION" ] && exit 0
# WT_SESSION can outlive its session (inherited by processes outside the wt
# server) — only report from panes actually inside the wt tmux server
case "${TMUX:-}" in */wt,*) ;; *) exit 0 ;; esac
# ...and it goes stale after `wt mv` — resolve the live session name from our
# own pane. No fallback: if the pane is gone this is a leftover env from a
# dead session (orphaned claude), and writing under $WT_SESSION would
# resurrect status files for sessions that no longer exist.
[ -z "${TMUX_PANE:-}" ] && exit 0
name=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)
[ -z "$name" ] && exit 0
dir="$HOME/.local/state/wt/status"
mkdir -p "$dir"
f="$dir/$name"
case "$1" in
  running) echo running > "$f" ;;
  waiting)
    prev=$(cat "$f" 2>/dev/null)
    # the 60s idle-reminder notification also lands here — after a completed
    # turn it's noise (the session is idle, not blocked); only a mid-turn
    # pause (permission dialog, AskUserQuestion) is a real hand-up
    case "$input" in
      *"waiting for your input"*) [ "$prev" = running ] || exit 0 ;;
    esac
    # only notify on a fresh transition, not repeat notifications
    echo waiting > "$f"
    if [ "$prev" != "waiting" ]; then
      osascript -e "display notification \"$name needs your input\" with title \"wt\" sound name \"Glass\"" >/dev/null 2>&1 &
    fi
    ;;
  idle)
    echo idle > "$f"
    osascript -e "display notification \"$name is done\" with title \"wt\"" >/dev/null 2>&1 &
    ;;
  end) rm -f "$f" ;;
esac
exit 0
