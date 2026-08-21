#!/bin/bash
# wt-vm — VM elevation for wt sessions (PoC).
#
#   wt vmsync [repo]   sync claude config (CLAUDE.md, hooks, skills, memory) to the VM
#   wt push <session>  move a session's worktree + claude conversation to the VM,
#                      swap the local pane to an auto-reconnecting ssh attach
#
# One-time setup per repo:  git -C <repo> config wt.vmrepo <repo-path-on-vm>
# VM host:                   git -C <repo> config wt.vmhost <ssh-host>   (required)
#
# The VM runs its own tmux server (-L wt) so the synced hooks.sh fires there
# unchanged; the local poller (vm-status-poller.sh) mirrors status back.
set -uo pipefail

SOCK=wt
CONF="$HOME/.config/wt"
STATE="$HOME/.local/state/wt"
VMSTATE="$STATE/vm"

it() { tmux -L "$SOCK" -f "$CONF/inner.conf" "$@"; }
die() { echo "$*" >&2; exit 1; }
slug() { printf '%s' "$1" | sed 's|[/.]|-|g'; }   # claude project-dir naming

repo_of_dir() { git -C "$1" worktree list 2>/dev/null | head -1 | awk '{print $1}'; }

vm_cfg() {  # $1 repo — sets VMHOST/VMREPO globals
  VMHOST=$(git -C "$1" config wt.vmhost 2>/dev/null || true)
  [ -z "$VMHOST" ] && die "wt.vmhost not set — run: git -C $1 config wt.vmhost <ssh-host>"
  VMREPO=$(git -C "$1" config wt.vmrepo 2>/dev/null || true)
  [ -z "$VMREPO" ] && die "wt.vmrepo not set — run: git -C $1 config wt.vmrepo <repo-path-on-vm>"
}

vssh() { ssh -o ConnectTimeout=10 "$VMHOST" "$@"; }

cmd_vmsync() {
  local repo="${1:-}"
  [ -z "$repo" ] && repo=$(git rev-parse --show-toplevel 2>/dev/null)
  [ -z "$repo" ] && die "not in a git repo — run: wt vmsync <repo-path>"
  repo=$(repo_of_dir "$repo")
  vm_cfg "$repo"
  local vmhome; vmhome=$(vssh 'printf %s "$HOME"') || die "cannot reach $VMHOST"

  echo "→ CLAUDE.md, hooks.sh, skills → $VMHOST"
  vssh 'mkdir -p ~/.claude/skills ~/.config/wt ~/.local/state/wt/status'
  scp -q "$HOME/.claude/CLAUDE.md" "$VMHOST:.claude/CLAUDE.md"
  scp -q "$CONF/hooks.sh" "$VMHOST:.config/wt/hooks.sh"
  vssh 'chmod +x ~/.config/wt/hooks.sh'
  rsync -aq --delete "$HOME/.claude/skills/" "$VMHOST:.claude/skills/"

  echo "→ merging wt hooks into VM settings.json"
  # NOT under $VMSTATE — every file there is a session marker to the poller
  local tmp; tmp=$(mktemp /tmp/wt-vm-settings.XXXXXX)
  vssh 'cat ~/.claude/settings.json 2>/dev/null' > "$tmp" || true
  python3 - "$tmp" "$vmhome" "$HOME/.claude/settings.json" <<'PYEOF'
import copy, json, os, sys
vm_path, vm_home, local_path = sys.argv[1], sys.argv[2], sys.argv[3]
local = json.load(open(local_path))
try:
    vm = json.load(open(vm_path))
except Exception:
    vm = {}
marker = "/.config/wt/hooks.sh"
is_wt = lambda g: any(marker in h.get("command", "") for h in g.get("hooks", []))
vmh = vm.setdefault("hooks", {})
for ev, groups in (local.get("hooks") or {}).items():
    keep = copy.deepcopy([g for g in groups if is_wt(g)])
    if not keep:
        continue
    for g in keep:
        for h in g["hooks"]:
            h["command"] = h["command"].replace(os.path.expanduser("~"), vm_home)
    cur = vmh.setdefault(ev, [])
    cur[:] = [g for g in cur if not is_wt(g)]
    cur.extend(keep)
json.dump(vm, open(vm_path, "w"), indent=2)
print("  merged events:", ", ".join(ev for ev in (local.get("hooks") or {})
      if any(is_wt(g) for g in local["hooks"][ev])))
PYEOF
  scp -q "$tmp" "$VMHOST:.claude/settings.json"
  rm -f "$tmp"

  local memsrc="$HOME/.claude/projects/$(slug "$repo")/memory"
  if [ -d "$memsrc" ]; then
    echo "→ memory → ~/.claude/projects/$(slug "$VMREPO")/memory"
    vssh "mkdir -p ~/.claude/projects/$(slug "$VMREPO")/memory"
    rsync -aq "$memsrc/" "$VMHOST:.claude/projects/$(slug "$VMREPO")/memory/"
  fi
  echo "✓ vmsync done"
}

pane_claude_alive() {  # $1 tmux target
  local tty
  tty=$(it list-panes -t "$1" -F '#{pane_active} #{pane_tty}' 2>/dev/null \
        | awk '$1==1{print $2; exit}')
  [ -n "$tty" ] || return 1
  ps -o comm= -t "${tty#/dev/}" 2>/dev/null | grep -q claude
}

cmd_push() {
  local name="${1:-}"
  [ -z "$name" ] && die "usage: wt push <session>"
  it has-session -t "=$name" 2>/dev/null || die "no session '$name' (see: wt ls)"
  [ -f "$VMSTATE/$name" ] && die "'$name' is already on the VM"
  local dir
  dir=$(it list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null \
        | awk -F'|' -v n="$name" '$1==n{print $2}')
  [ -f "$dir/.git" ] || die "'$name' is not a worktree session — only worktree sessions can elevate"
  local repo branch
  repo=$(repo_of_dir "$dir")
  branch=$(git -C "$dir" branch --show-current)
  [ -z "$branch" ] && die "detached HEAD in $dir — check out a branch first"
  vm_cfg "$repo"
  local vmhome; vmhome=$(vssh 'printf %s "$HOME"') || die "cannot reach $VMHOST"
  local vmdir="$vmhome/wt-vm/$name"
  vssh "[ -e $vmdir ]" && die "$VMHOST:$vmdir already exists — remove it first"

  local t="$name"
  it list-windows -t "=$name" -F '#{window_name}' 2>/dev/null | grep -qx claude && t="$name:claude"

  echo "→ pushing branch '$branch' to $VMHOST:$VMREPO"
  git -C "$dir" push -qf "$VMHOST:$VMREPO" "HEAD:refs/heads/wt-vm/$branch" || die "git push to VM failed"
  vssh "mkdir -p $vmhome/wt-vm && cd $VMREPO && git worktree add -B '$branch' '$vmdir' 'wt-vm/$branch'" \
    || die "worktree add on VM failed"

  echo "→ syncing uncommitted + untracked files (.env included)"
  local flist="$VMSTATE/push-files.$$"
  mkdir -p "$VMSTATE"
  { git -C "$dir" ls-files -mo --exclude-standard
    git -C "$dir" ls-files --others --ignored --exclude-standard \
      | grep -E '(^|/)\.env[^/]*$'
  } | sort -u > "$flist"
  [ -s "$flist" ] && rsync -aq --files-from="$flist" "$dir/" "$VMHOST:$vmdir/"
  git -C "$dir" ls-files -d | while IFS= read -r f; do
    vssh "rm -f '$vmdir/$f'"
  done
  rm -f "$flist"

  # same trick as the VM's own new-claude-worktree.sh: share the main repo's
  # node_modules instead of a slow fresh install
  echo "→ linking node_modules from $VMREPO"
  vssh "[ -e '$vmdir/node_modules' ] || ln -s '$VMREPO/node_modules' '$vmdir/node_modules'" \
    || echo "  (node_modules link failed — continue)"

  local pdir jf sid
  pdir="$HOME/.claude/projects/$(slug "$dir")"
  jf=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$jf" ]; then
    sid=$(basename "$jf" .jsonl)
    if pane_claude_alive "$t"; then
      echo "→ asking local claude to exit"
      it send-keys -t "$t" -l '/exit'
      sleep 1
      it send-keys -t "$t" Enter
      local i
      for i in $(seq 1 20); do pane_claude_alive "$t" || break; sleep 1; done
      pane_claude_alive "$t" && die "local claude did not exit — try again when its turn is finished"
    fi
    echo "→ pushing conversation $sid"
    vssh "mkdir -p ~/.claude/projects/$(slug "$vmdir")"
    scp -q "$jf" "$VMHOST:.claude/projects/$(slug "$vmdir")/"
  else
    echo "→ no local conversation found — VM claude starts fresh"
  fi

  echo "→ starting claude on VM"
  vssh "tmux -L wt new-session -d -s '$name' -c '$vmdir' -e WT_SESSION='$name' && tmux -L wt rename-window -t '$name' claude" \
    || die "tmux on VM failed"
  local launch="export PATH=\$HOME/.local/bin:\$PATH; claude --dangerously-skip-permissions --chrome"
  [ -n "${sid:-}" ] && launch="$launch --resume $sid"
  vssh "tmux -L wt send-keys -t '$name' \"$launch\" Enter"
  # fresh dir on the VM: auto-accept claude's trust-folder dialog
  ( for _ in $(seq 1 20); do
      sleep 1
      if vssh "tmux -L wt capture-pane -t '$name' -p" 2>/dev/null | grep -q 'trust this folder'; then
        vssh "tmux -L wt send-keys -t '$name' Enter"; break
      fi
    done ) >/dev/null 2>&1 &

  printf '%s\n' "$VMHOST" > "$VMSTATE/$name"
  echo "→ swapping local pane to ssh attach"
  it send-keys -t "$t" -l "exec $CONF/vm-attach.sh $name"
  it send-keys -t "$t" Enter

  nohup "$CONF/vm-status-poller.sh" >/dev/null 2>&1 &
  echo "✓ '$name' now runs on $VMHOST ($vmdir) — same sidebar row, ☁ glyph"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  vmsync) cmd_vmsync "$@" ;;
  push)   cmd_push "$@" ;;
  *) grep '^#   wt' "$0" | sed 's/^#   //'; exit 1 ;;
esac
