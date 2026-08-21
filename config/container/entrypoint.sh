#!/bin/bash
# Session container entrypoint. Starts the long-lived tmux session that the wt
# hub attaches to, plus (on demand) the headful browser stack. Keeps running
# whatever CMD says so `docker run -d` stays alive between attaches.
set -uo pipefail

WT_SESSION="${WT_SESSION:-session}"
export WT_SESSION

# hooks.sh writes here; the host bind-mounts its shared status dir onto it so
# one ssh read serves every session
mkdir -p "$HOME/.local/state/wt/status" 2>/dev/null || true

# Shell environment. Sourced BEFORE tmux starts so the whole process tree —
# claude, its Bash tool, bun, every pane — inherits it. The host's curated
# secrets file is mounted read-only; wt-env.sh carries the non-secret bits
# (NODE_ENV, feature flags) that live in the laptop's .zshrc.
if [ -f /state/secrets.env ]; then
  set -a; . /state/secrets.env 2>/dev/null; set +a
fi
if [ -f /state/wt-env.sh ]; then
  set -a; . /state/wt-env.sh 2>/dev/null; set +a
fi
# the orchestration doc lives where CLAUDE.md says it does
if [ -f /state/ORCHESTRATION.md ]; then
  mkdir -p "$HOME/.config/wt" 2>/dev/null
  ln -sfn /state/ORCHESTRATION.md "$HOME/.config/wt/ORCHESTRATION.md" 2>/dev/null
fi

# interactive shells (when you attach and type) get the same thing
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  grep -q 'wt-session env' "$rc" 2>/dev/null || cat >> "$rc" <<'RC'
# wt-session env
[ -f /state/secrets.env ] && { set -a; . /state/secrets.env; set +a; }
[ -f /state/wt-env.sh ]   && { set -a; . /state/wt-env.sh;   set +a; }
[ -f /state/aliases.sh ]  && . /state/aliases.sh
RC
done

# headful chrome is opt-in: it costs ~1.5GB and most sessions never need it
if [ "${WT_BROWSER:-headless}" = "headful" ]; then
  export DISPLAY=:99
  Xvfb :99 -screen 0 1920x1080x24 >/tmp/xvfb.log 2>&1 &
  x11vnc -display :99 -forever -shared -nopw -quiet >/tmp/x11vnc.log 2>&1 &
  websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/novnc.log 2>&1 &
fi

# ~/.claude.json carries onboarding state, not just trust. A fresh one sends the
# TUI into theme-picker → login → OAuth even when .credentials.json is valid, so
# the seeded copy from /state is authoritative and lives there (symlink) to
# survive container recreation. /work is trusted by construction: the hub pushed it.
if [ -f /state/claude.json ]; then
  ln -sfn /state/claude.json "$HOME/.claude.json"
else
  printf '{}' > /state/claude.json && ln -sfn /state/claude.json "$HOME/.claude.json"
fi
python3 - <<'PY' 2>/dev/null || true
import json
p = "/state/claude.json"
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["hasCompletedOnboarding"] = True
d.setdefault("theme", "dark")
d.setdefault("projects", {}).setdefault("/work", {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"))
PY

# one tmux session named like the wt session, window named claude — this is
# exactly what wt's send_target() and peek expect to find.
# socket MUST be -L wt: hooks.sh only reports status from panes whose $TMUX
# path contains "/wt," and the hub's send/peek address the same socket.
if ! tmux -L wt has-session -t "=$WT_SESSION" 2>/dev/null; then
  # -f inner.conf on the call that STARTS the server, or the container's tmux
  # comes up with tmux defaults: mouse off (you cannot scroll) and a 2000-line
  # history. -f is only honoured at server start, hence it going here.
  TCONF=""
  [ -f /state/inner.conf ] && TCONF="-f /state/inner.conf"
  tmux -L wt $TCONF new-session -d -s "$WT_SESSION" -c /work -e WT_SESSION="$WT_SESSION"
  tmux -L wt rename-window -t "=$WT_SESSION:^" claude
  if [ "${WT_AUTOSTART_CLAUDE:-1}" = "1" ]; then
    launch="claude --dangerously-skip-permissions"
    [ -n "${WT_RESUME_ID:-}" ] && launch="$launch --resume ${WT_RESUME_ID}"
    tmux -L wt send-keys -t "=$WT_SESSION:claude" "$launch" Enter
  fi
fi

exec "$@"
