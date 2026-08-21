#!/bin/bash
# Dispatches clicks on the hub's top bar. $1 = the status range that was clicked
# (set by #[range=user|<name>] in hub.conf), $2 = the clicking client's tty.
#
# EVERY branch must stay silent. tmux shows run-shell output by dropping the
# active pane into copy mode, which hides the sidebar behind a scrollback view.
WT="$HOME/.local/bin/wt"
CONF="$HOME/.config/wt"
range="${1:-}"
client="${2:-}"

sidebar_pane() {
  tmux -L wt-hub list-panes -t hub -F '#{pane_id} #{pane_start_command}' 2>/dev/null \
    | grep sidebar | awk '{print $1}'
}

# the session in the main pane — NOT `wt current`, which would resolve to a
# scratch popup whenever one is open
main_session() {
  local rtty
  rtty=$(tmux -L wt-hub list-panes -t hub -F '#{pane_tty} #{pane_start_command}' 2>/dev/null \
         | grep attach | awk '{print $1}' | head -1)
  tmux -L wt list-clients -F '#{client_tty} #{client_session}' 2>/dev/null \
    | awk -v t="$rtty" '$1==t{print $2}'
}

case "$range" in
  cursor)  "$WT" edit "$(main_session)" ;;
  # both of these go through the peek flow, so a click behaves exactly like the key
  orch)    "$CONF/peek.sh" F2 "$client" ;;
  scratch) "$CONF/peek.sh" F1 "$client" ;;
  new)
    # the new-task dialog lives in the sidebar; press its own key for it
    p=$(sidebar_pane); [ -n "$p" ] && tmux -L wt-hub send-keys -t "$p" n ;;
esac
exit 0
