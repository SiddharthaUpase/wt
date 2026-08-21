#!/usr/bin/env bash
# wt installer. Symlinks the repo into place so edits here are live — this repo
# stays the source of truth rather than drifting from a copy.
#
#   ./install.sh              symlink (recommended; keeps working on the tool easy)
#   ./install.sh --copy       copy instead, if you want the repo detached
#
# Anything already installed is moved aside with a timestamp, never overwritten.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
CONF="$HOME/.config/wt"
MODE=symlink
[ "${1:-}" = --copy ] && MODE=copy

say()  { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

echo
echo "installing wt from $REPO"
echo

# --- requirements -----------------------------------------------------------
command -v tmux >/dev/null || die "tmux is required — brew install tmux (or apt install tmux)"
case "$(tmux -V)" in
  *[12].*) warn "tmux $(tmux -V) is old; popups and key-tables need 3.2+" ;;
esac
command -v git    >/dev/null || die "git is required"
command -v python3 >/dev/null || warn "python3 missing — clone and cpull lose their conversation-repair step"

# --- move anything existing aside -------------------------------------------
stamp=$(date +%Y%m%d-%H%M%S)
if [ -e "$BIN/wt" ] || [ -L "$BIN/wt" ]; then
  mv "$BIN/wt" "$BIN/wt.bak.$stamp" && say "existing wt saved as wt.bak.$stamp"
fi
if [ -e "$CONF" ] || [ -L "$CONF" ]; then
  mv "$CONF" "$CONF.bak.$stamp" && say "existing config saved as $(basename "$CONF").bak.$stamp"
fi

# --- install ----------------------------------------------------------------
mkdir -p "$BIN"
if [ "$MODE" = symlink ]; then
  ln -s "$REPO/bin/wt" "$BIN/wt"
  ln -s "$REPO/config" "$CONF"
  say "symlinked $BIN/wt and $CONF → this repo"
else
  install -m 755 "$REPO/bin/wt" "$BIN/wt"
  mkdir -p "$CONF"
  cp -R "$REPO/config/." "$CONF/"
  say "copied into $BIN and $CONF"
fi
mkdir -p "$HOME/.local/state/wt/status"

# --- required config --------------------------------------------------------
echo
prefix=$(git config --global --get wt.prefix 2>/dev/null || true)
if [ -z "$prefix" ]; then
  git config --global wt.prefix "${USER:-dev}"
  say "set git config --global wt.prefix = ${USER:-dev}   (your branch prefix)"
else
  say "wt.prefix already set to '$prefix'"
fi

defrepo=$(git config --global --get wt.defaultrepo 2>/dev/null || true)
if [ -z "$defrepo" ]; then
  warn "wt.defaultrepo is not set — the sidebar's 'new task' needs it:"
  printf '      git config --global wt.defaultrepo /path/to/your/repo\n'
else
  say "wt.defaultrepo = $defrepo"
fi

# --- PATH -------------------------------------------------------------------
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) warn "$BIN is not on your PATH — add this to your shell rc:"
     printf '      export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac

# --- claude hooks (optional but this is what drives the status glyphs) -------
echo
if [ -f "$HOME/.claude/settings.json" ] && grep -q 'wt/hooks.sh' "$HOME/.claude/settings.json" 2>/dev/null; then
  say "claude status hooks already wired"
else
  warn "status hooks not wired — sidebar rows will show '-' instead of ●/✋/✔"
  printf '      see README.md § Status hooks for the settings.json block\n'
fi

echo
printf '  \033[32mdone\033[0m — run: wt\n\n'
