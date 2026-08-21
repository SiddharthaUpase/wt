#!/bin/bash
# wt-container — one Docker container per wt session on a remote host.
#
#   wt csetup [repo]      create host dirs + build the wt-session image
#   wt cnew [-p task] <branch> [base]
#                         create a NEW session directly in a container (no local
#                         worktree, nothing on your laptop)
#   wt cpush <session>    move a session (worktree + claude conversation) into
#                         its own capped container on the host
#   wt cpush --as <new> <session>
#                         elevate a COPY under a new name; the source session
#                         keeps running locally and untouched (rollback safety).
#                         The copy gets its own branch <branch>-vm so the two
#                         can diverge.
#   wt cpull [--keep] <session>
#                         bring a session home: commits pushed to the mirror,
#                         uncommitted files + conversation copied back, container
#                         removed (--keep stops it instead), local claude resumed
#   wt clone <session> [new]
#                         clone a cloud session: its worktree, uncommitted work
#                         and conversation are copied host-side onto a new
#                         branch, and a second container runs from the copy
#   wt crm <session>      stop + delete the container and its session dirs
#
# Per-repo config:  git -C <repo> config wt.chost  <ssh-host>      (required)
#                   git -C <repo> config wt.cimage <image>         (wt-session:latest)
#                   git -C <repo> config wt.cmem   <docker mem>    (8g)
#                   git -C <repo> config wt.ccpus  <docker cpus>   (4)
#
# Host layout:  ~/wt/mirrors/<repo>.git      bare mirror, seeded by push
#               ~/wt/sessions/<name>/work    the worktree  → container /work
#               ~/wt/sessions/<name>/state   ~/.claude etc → container /state
#               ~/.local/state/wt/status     shared status dir, bind-mounted into
#                                            every container so the hub's existing
#                                            poller reads all sessions in one go
set -uo pipefail

SOCK=wt
CONF="$HOME/.config/wt"
STATE="$HOME/.local/state/wt"
VMSTATE="$STATE/vm"

it() { tmux -L "$SOCK" -f "$CONF/inner.conf" "$@"; }
die() { echo "$*" >&2; exit 1; }
slug() { printf '%s' "$1" | sed 's|[/.]|-|g'; }   # claude project-dir naming
name_for() { printf '%s' "$1" | tr './:@ ' '-' | tr -s '-'; }   # same rule as `wt name`
repo_of_dir() { git -C "$1" worktree list 2>/dev/null | head -1 | awk '{print $1}'; }

c_cfg() {  # $1 repo — sets CHOST/CIMAGE/CMEM/CCPUS
  CHOST=$(git -C "$1" config wt.chost 2>/dev/null || true)
  [ -z "$CHOST" ] && die "wt.chost not set — run: git -C $1 config wt.chost <ssh-host>"
  CIMAGE=$(git -C "$1" config wt.cimage 2>/dev/null || true); CIMAGE="${CIMAGE:-wt-session:latest}"
  # Memory ceiling. Default is generous rather than tight: a killed container
  # loses the session's work, which is worse than a slow one. Set wt.cmem=none
  # to remove it entirely — but note an uncapped runaway is exactly what took
  # the whole box down on 2026-08-12, so "none" protects nothing from a leak.
  CMEM=$(git -C "$1" config wt.cmem 2>/dev/null || true);     CMEM="${CMEM:-24g}"
  CCPUS=$(git -C "$1" config wt.ccpus 2>/dev/null || true);   CCPUS="${CCPUS:-4}"
  # Per-machine env file on the HOST, mounted read-only into every container.
  # Optional: skipped if absent, so a teammate with no secrets file still works.
  # Override per repo:  git config wt.csecrets <filename-relative-to-host-home>
  # Cloud sessions do NOT inherit the laptop's current effort: a transient
  # /effort low on this machine would otherwise be baked into every container.
  CEFFORT=$(git -C "$1" config wt.ceffort 2>/dev/null || true)
  CEFFORT="${CEFFORT:-high}"
  CSECRETS=$(git -C "$1" config wt.csecrets 2>/dev/null || true)
  CSECRETS="${CSECRETS:-.wt-secrets.env}"
  CSECRETS_MOUNT=""
  cssh "[ -f ~/'$CSECRETS' ]" 2>/dev/null \
    && CSECRETS_MOUNT="-v \"\$HOME/$CSECRETS\":/state/secrets.env:ro"
}

cssh() { ssh -o ConnectTimeout=15 "$CHOST" "$@"; }

# --memory-swap=-1 lets a container spill into swap instead of being OOM-killed
# the instant it touches the ceiling: a slow session beats a dead one.
mem_flags() {
  case "${CMEM:-}" in
    none|0|unlimited) MEMFLAGS="" ;;
    *) MEMFLAGS="--memory='$CMEM' --memory-swap=-1" ;;
  esac
}

cmd_csetup() {
  local repo="${1:-}"
  [ -z "$repo" ] && repo=$(git rev-parse --show-toplevel 2>/dev/null)
  [ -z "$repo" ] && die "not in a git repo — run: wt csetup <repo-path>"
  repo=$(repo_of_dir "$repo")
  c_cfg "$repo"
  cssh 'command -v docker >/dev/null' || die "docker not installed on $CHOST"
  echo "→ host dirs on $CHOST"
  cssh 'mkdir -p ~/wt/mirrors ~/wt/sessions ~/wt/build ~/.local/state/wt/status'
  echo "→ copying image sources"
  rsync -aq "$CONF/container/" "$CHOST:wt/build/"
  echo "→ docker build (first run pulls ubuntu + chromium, takes a few minutes)"
  # the image's user must own the bind-mounted worktree — build with the host's ids
  cssh "cd ~/wt/build && docker build -t $CIMAGE \
        --build-arg UID=\$(id -u) --build-arg GID=\$(id -g) ." \
    || die "image build failed"
  echo "✓ $CHOST ready — image $CIMAGE"
}

# claude config for ONE session's state dir: settings.json hooks are rewritten to
# the in-container paths (/state/hooks.sh, HOME=/home/dev)
seed_state_config() {   # $1 = host path of the session's state dir
  local sdir="$1" tmp
  cssh "mkdir -p '$sdir/claude/skills' '$sdir/claude/projects'"
  scp -q "$CONF/hooks.sh" "$CHOST:$sdir/hooks.sh"
  cssh "chmod +x '$sdir/hooks.sh'"
  scp -q "$HOME/.claude/CLAUDE.md" "$CHOST:$sdir/claude/CLAUDE.md"
  # CLAUDE.md tells sessions to read this; without it a containerised session is
  # pointed at a file that does not exist
  scp -q "$CONF/ORCHESTRATION.md" "$CHOST:$sdir/ORCHESTRATION.md"
  # the container's tmux needs the same config as the hub's inner server, or it
  # starts with mouse off and a 2000-line scrollback
  scp -q "$CONF/inner.conf" "$CHOST:$sdir/inner.conf"
  # browser-fleet drives the Mac's logged-in Chrome profiles. It cannot work in a
  # container (no fleet binary, no macOS Keychain), and its advice to "ask the
  # human to run fleet up" is wrong there — containers use agent-browser directly.
  rsync -aq --delete --exclude browser-fleet "$HOME/.claude/skills/" "$CHOST:$sdir/claude/skills/"
  tmp=$(mktemp /tmp/wt-c-settings.XXXXXX)
  python3 - "$tmp" "$HOME/.claude/settings.json" "$CEFFORT" <<'PYEOF'
import copy, json, os, sys
out_path, local_path, effort = sys.argv[1], sys.argv[2], sys.argv[3]
local = json.load(open(local_path))
marker = "/.config/wt/hooks.sh"
is_wt = lambda g: any(marker in h.get("command", "") for h in g.get("hooks", []))
hooks = {}
for ev, groups in (local.get("hooks") or {}).items():
    keep = copy.deepcopy([g for g in groups if is_wt(g)])
    if not keep:
        continue
    for g in keep:
        for h in g["hooks"]:
            # the container mounts the session state at /state
            h["command"] = h["command"].replace(
                os.path.expanduser("~/.config/wt/hooks.sh"), "/state/hooks.sh")
    hooks[ev] = keep
out = {
    "hooks": hooks,
    "permissions": {"defaultMode": "bypassPermissions"},
    # without this the TUI blocks on the bypass-mode confirmation dialog; the
    # container IS the sandbox that warning asks for
    "skipDangerousModePermissionPrompt": True,
    "effortLevel": effort,
    "model": local.get("model", "opus"),
    "theme": local.get("theme", "dark"),
}
json.dump(out, open(out_path, "w"), indent=2)
PYEOF
  [ -s "$tmp" ] || { rm -f "$tmp"; die "settings.json generation failed — refusing to create a container with no hooks"; }
  scp -q "$tmp" "$CHOST:$sdir/claude/settings.json"
  rm -f "$tmp"

  # claude's login token. Copied host-side only: on macOS it lives in the
  # Keychain, not on disk, so the HOST's already-authenticated credentials are
  # the source. Without it the container's claude opens the login prompt.
  # NOT copied: claude rotates its OAuth token on refresh, so a copy goes stale
  # the moment any other claude refreshes ("Login expired · Please run /login").
  # cpush bind-mounts the host's single credentials file into every container,
  # exactly as co-resident claude processes share one file on a normal machine.
  cssh "[ -f ~/.claude/.credentials.json ]" \
    || echo "  ⚠ no ~/.claude/.credentials.json on $CHOST — run 'claude' there once to log in"
  # ~/.claude.json = onboarding + account state. Without it the TUI runs its
  # first-run flow (theme → login → OAuth) even though the credentials are valid.
  cssh "[ -f ~/.claude.json ] && cp ~/.claude.json '$sdir/claude.json'" \
    || echo "  ⚠ no ~/.claude.json on $CHOST — container claude will run onboarding"

  # Shell environment for the session. Secrets are NOT shipped from the laptop:
  # the host already keeps a curated secrets file (git config wt.csecrets), which docker mounts
  # read-only. Only the non-secret shell settings travel from .zshrc, plus any
  # aliases that make sense on Linux.
  local envtmp; envtmp=$(mktemp /tmp/wt-env.XXXXXX)
  {
    echo "# generated by wt from the laptop's .zshrc — non-secret settings only"
    grep -E '^\s*export (NODE_ENV|LOCAL_TRACE|CLAUDE_CODE_[A-Z_]+)=' "$HOME/.zshrc" 2>/dev/null \
      | sed 's/^\s*//'
  } > "$envtmp"
  scp -q "$envtmp" "$CHOST:$sdir/wt-env.sh"; rm -f "$envtmp"

  local altmp; altmp=$(mktemp /tmp/wt-alias.XXXXXX)
  {
    echo "# aliases carried over; laptop-only ones (ssh wrappers) are skipped"
    grep -E '^\s*alias ' "$HOME/.zshrc" 2>/dev/null | grep -v 'ssh ' | sed 's/^\s*//'
  } > "$altmp"
  scp -q "$altmp" "$CHOST:$sdir/aliases.sh"; rm -f "$altmp"
}

# A previous elevation leaves ~/wt/sessions/<name> behind (cpull keeps it on
# purpose so nothing is destroyed mid-round-trip). Re-elevating the same session
# must therefore reclaim it rather than refuse. A RUNNING container is the only
# case that is genuinely a conflict.
reclaim_stale_workdir() {   # $1 session name · $2 host work dir
  local name="$1" work="$2" cname="wt-$1"
  cssh "test -e '$work'" 2>/dev/null || return 0
  if cssh "docker ps --format '{{.Names}}' | grep -qx '$cname'" 2>/dev/null; then
    die "'$name' is already running in $cname on $CHOST — wt cpull or wt crm it first"
  fi
  echo "→ reclaiming host dirs from a previous elevation"
  cssh "docker rm -f '$cname' >/dev/null 2>&1; rm -rf ~/wt/sessions/'$name'" \
    || die "could not clear $CHOST:~/wt/sessions/$name"
}

pane_claude_alive() {  # $1 tmux target
  local tty
  tty=$(it list-panes -t "$1" -F '#{pane_active} #{pane_tty}' 2>/dev/null \
        | awk '$1==1{print $2; exit}')
  [ -n "$tty" ] || return 1
  ps -o comm= -t "${tty#/dev/}" 2>/dev/null | grep -q claude
}

cmd_cpush() {
  # --as <newname> = clone mode: elevate a COPY under a new name and leave the
  # source session running and local. The rollback is then just "keep using the
  # original"; nothing about it is touched, not even its claude.
  local src="" target="" clone=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) target="${2:-}"; clone=1; shift ;;
      *) [ -z "$src" ] && src="$1" ;;
    esac
    shift
  done
  local name="$src"
  [ -z "$name" ] && die "usage: wt cpush [--as <newname>] <session>"
  it has-session -t "=$name" 2>/dev/null || die "no session '$name' (see: wt ls)"
  if [ "$clone" -eq 1 ]; then
    [ -z "$target" ] && die "--as needs a name"
    target=$(name_for "$target")
    it has-session -t "=$target" 2>/dev/null && die "session '$target' already exists"
    [ -f "$VMSTATE/$target" ] && die "'$target' is already remote"
  else
    target="$name"
    [ -f "$VMSTATE/$name" ] && die "'$name' is already remote"
  fi
  local dir
  dir=$(it list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null \
        | awk -F'|' -v n="$name" '$1==n{print $2}')
  [ -f "$dir/.git" ] || die "'$name' is not a worktree session"
  local repo branch
  repo=$(repo_of_dir "$dir")
  branch=$(git -C "$dir" branch --show-current)
  [ -z "$branch" ] && die "detached HEAD in $dir — check out a branch first"
  c_cfg "$repo"

  local mirror sdir work cname
  mirror="wt/mirrors/$(basename "$repo").git"
  sdir="wt/sessions/$target"
  work="$sdir/work"
  cname="wt-$target"

  # Fail fast. The push must make the local claude exit, and a mid-turn claude
  # will not take /exit — but that is only discovered after the mirror push,
  # clone and rsync have already run. Check the status hook up front instead.
  # Cloning (--as) never touches the source claude, so it is exempt.
  if [ "$clone" -eq 0 ]; then
    # pane-based, NOT the status file — hooks leave that stuck on "running"
    # whenever a turn ends without a Stop event
    if "$HOME/.local/bin/wt" busy "$name"; then
      die "'$name' is mid-turn — let it finish, then elevate"
    fi
    [ "$(cat "$STATE/status/$name" 2>/dev/null)" = waiting ] \
      && die "'$name' is waiting on a prompt — answer it first, then elevate"
  fi

  mem_flags
  reclaim_stale_workdir "$target" "$work"
  cssh "docker image inspect $CIMAGE >/dev/null 2>&1" \
    || die "image $CIMAGE missing on $CHOST — run: wt csetup"

  echo "→ seeding bare mirror $mirror"
  cssh "[ -d '$mirror' ] || git init -q --bare '$mirror'" || die "mirror init failed"
  # clone mode gets its own ref so the copy can diverge from the original branch
  local rbranch="$branch"
  [ "$clone" -eq 1 ] && rbranch="$branch-vm"
  echo "→ pushing branch '$branch' → '$rbranch' (first push for a repo sends full history)"
  git -C "$dir" push -qf "$CHOST:$mirror" "HEAD:refs/heads/$rbranch" || die "git push failed"

  echo "→ worktree from mirror (local clone, hardlinked)"
  cssh "mkdir -p '$sdir' && git clone -q --local '$mirror' '$work' -b '$rbranch'" \
    || die "clone failed"

  echo "→ syncing uncommitted + untracked files (.env included)"
  local flist; flist=$(mktemp /tmp/wt-c-files.XXXXXX)
  { git -C "$dir" ls-files -mo --exclude-standard
    git -C "$dir" ls-files --others --ignored --exclude-standard \
      | grep -E '(^|/)\.env[^/]*$'
  } | sort -u > "$flist"
  [ -s "$flist" ] && rsync -aq --files-from="$flist" "$dir/" "$CHOST:$work/"
  git -C "$dir" ls-files -d | while IFS= read -r f; do cssh "rm -f '$work/$f'"; done
  rm -f "$flist"

  echo "→ seeding claude config into the session's state dir"
  seed_state_config "$sdir/state"

  local t="$name"
  it list-windows -t "=$name" -F '#{window_name}' 2>/dev/null | grep -qx claude && t="$name:claude"
  local pdir jf sid
  pdir="$HOME/.claude/projects/$(slug "$dir")"
  jf=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$jf" ]; then
    sid=$(basename "$jf" .jsonl)
    if [ "$clone" -eq 0 ] && pane_claude_alive "$t"; then
      echo "→ asking local claude to exit"
      it send-keys -t "$t" -l '/exit'; sleep 1; it send-keys -t "$t" Enter
      local i
      for i in $(seq 1 20); do pane_claude_alive "$t" || break; sleep 1; done
      pane_claude_alive "$t" && die "local claude did not exit — retry when its turn is finished"
    fi
    echo "→ pushing conversation $sid"
    # inside the container the worktree is /work, so claude keys it as "-work"
    cssh "mkdir -p '$sdir/state/claude/projects/-work'"
    scp -q "$jf" "$CHOST:$sdir/state/claude/projects/-work/"
    # a live source session is appending to that file, so the copy can end
    # mid-line; a half-written record makes --resume fail. Drop any trailing
    # line that is not valid JSON.
    if [ "$clone" -eq 1 ]; then
      cssh "python3 - '$sdir/state/claude/projects/-work/$sid.jsonl' <<'PY'
import json, sys
p = sys.argv[1]
good = []
for line in open(p, encoding='utf-8', errors='replace'):
    if not line.strip():
        continue
    try:
        json.loads(line)
    except Exception:
        break
    good.append(line if line.endswith('\n') else line + '\n')
open(p, 'w', encoding='utf-8').writelines(good)
print('  conversation records kept:', len(good))
PY"
    fi
  else
    echo "→ no local conversation found — container claude starts fresh"
  fi

  echo "→ docker run (mem $CMEM · cpus $CCPUS)"
  cssh "docker rm -f '$cname' >/dev/null 2>&1; docker run -d --name '$cname' \
      $MEMFLAGS --cpus='$CCPUS' \
      --restart=unless-stopped \
      -e WT_SESSION='$target' ${sid:+-e WT_RESUME_ID='$sid'} \
      -e WT_BROWSER='${WT_BROWSER:-headless}' \
      -v \"\$HOME/$work\":/work \
      -v \"\$HOME/$sdir/state\":/state \
      -v \"\$HOME/.claude/.credentials.json\":/state/claude/.credentials.json \
      $CSECRETS_MOUNT \
      -v \"\$HOME/.local/state/wt\":/home/dev/.local/state/wt \
      '$CIMAGE' sleep infinity" >/dev/null || die "docker run failed"

  mkdir -p "$VMSTATE"
  printf '%s\n%s\n' "$CHOST" "$cname" > "$VMSTATE/$target"
  if [ "$clone" -eq 1 ]; then
    echo "→ new local row '$target' attached to the container"
    it new-session -d -s "$target" -c "$dir" -e WT_SESSION="$target"
    it rename-window -t "=$target:^" claude
    it send-keys -t "=$target:claude" -l "$CONF/vm-attach.sh $target"
    it send-keys -t "=$target:claude" Enter
  else
    echo "→ swapping local pane to the container attach"
    # deliberately NOT exec: when the session is un-marked (wt crm) the attach
    # loop exits back to this shell instead of closing the window and killing the row
    it send-keys -t "$t" -l "$CONF/vm-attach.sh $target"
    it send-keys -t "$t" Enter
  fi
  nohup "$CONF/vm-status-poller.sh" >/dev/null 2>&1 &
  echo "✓ '$target' runs in $cname on $CHOST — ☁ glyph in the sidebar"
  [ "$clone" -eq 1 ] && echo "  '$name' is untouched and still local — roll back by ignoring '$target'"
  # explicit: a function returns its LAST command's status, and that test is
  # false in the normal (non-clone) path — which made a successful elevation
  # report failure to the sidebar
  return 0
}

# cloud → laptop. The reverse of cpush: work and conversation come home, the
# container stops, and the local claude resumes exactly where the remote one was.
cmd_cpull() {
  local name="${1:-}" keep=0 a
  for a in "$@"; do [ "$a" = "--keep" ] && keep=1; done
  [ -z "$name" ] || [ "$name" = "--keep" ] && { [ "$name" = "--keep" ] && name="${2:-}"; }
  [ -z "$name" ] && die "usage: wt cpull [--keep] <session>"
  [ -f "$VMSTATE/$name" ] || die "'$name' is not remote"
  CHOST=$(head -1 "$VMSTATE/$name")
  local cname; cname=$(sed -n 2p "$VMSTATE/$name")
  [ -z "$cname" ] && die "'$name' has no container (old VM-mode session)"
  cssh "docker inspect '$cname' >/dev/null 2>&1" || die "container $cname is gone on $CHOST"

  local dir
  dir=$(it list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null \
        | awk -F'|' -v n="$name" '$1==n{print $2}')
  [ -z "$dir" ] && die "no local row '$name' to pull into"
  [ -d "$dir" ] || die "local worktree $dir is gone — nothing to pull into"

  local sdir="wt/sessions/$name"

  echo "→ stopping the container's claude so nothing writes mid-copy"
  cssh "docker exec '$cname' pkill -f claude" >/dev/null 2>&1
  sleep 2

  echo "→ pushing the container's commits back into the mirror"
  local rbranch
  rbranch=$(cssh "cd '$sdir/work' && git branch --show-current" 2>/dev/null)
  if [ -n "$rbranch" ]; then
    cssh "cd '$sdir/work' && git push -qf origin 'HEAD:refs/heads/$rbranch'" 2>/dev/null \
      && echo "  commits saved on branch '$rbranch' in the host mirror"
  fi

  # A cloud-born session (wt cnew) has NO local worktree — its row points at the
  # main repo. Without this, the rsync below would empty the container's branch
  # straight into the main checkout. Materialise a proper worktree first.
  local recreate=0
  if [ ! -f "$dir/.git" ]; then
    [ -z "$rbranch" ] && die "cannot tell which branch '$name' is on — refusing to pull"
    local mrepo mroot mirror newdir
    mrepo=$(repo_of_dir "$dir")
    [ -z "$mrepo" ] && die "'$dir' is not a git repo — refusing to pull"
    mroot=$(git -C "$mrepo" config wt.root 2>/dev/null || true)
    [ -z "$mroot" ] && mroot="$HOME/worktrees/$(basename "$mrepo")"
    newdir="$mroot/$name"
    [ -e "$newdir" ] && die "$newdir already exists — move it aside and retry"
    mirror="wt/mirrors/$(basename "$mrepo").git"
    echo "→ no local worktree yet (cloud-born session) — creating $newdir"
    git -C "$mrepo" fetch -q "$CHOST:$mirror" "$rbranch" 2>/dev/null \
      || die "could not fetch '$rbranch' from the host mirror"
    mkdir -p "$mroot"
    git -C "$mrepo" worktree add -q -b "$rbranch" "$newdir" FETCH_HEAD 2>/dev/null \
      || git -C "$mrepo" worktree add -q "$newdir" "$rbranch" \
      || die "git worktree add failed for $newdir"
    dir="$newdir"; recreate=1
  fi

  # The container's commits went to the mirror above, but nothing moved the LOCAL
  # worktree onto them. Without this the rsync below drops the container's working
  # tree on top of a stale HEAD and git reports the entire delta as uncommitted —
  # schema-diet came home 40 commits behind with 387 phantom changes. Bring the
  # branch home BEFORE the files.
  if [ "$recreate" -eq 0 ] && [ -n "$rbranch" ]; then
    local lrepo lmirror lhead rhead behind
    lrepo=$(repo_of_dir "$dir")
    lmirror="wt/mirrors/$(basename "$lrepo").git"
    if git -C "$lrepo" fetch -q "$CHOST:$lmirror" "$rbranch" 2>/dev/null; then
      lhead=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
      rhead=$(git -C "$lrepo" rev-parse FETCH_HEAD 2>/dev/null)
      if [ -n "$rhead" ] && [ "$lhead" != "$rhead" ]; then
        behind=$(git -C "$lrepo" rev-list --count "$lhead..$rhead" 2>/dev/null)
        echo "→ local worktree is ${behind:-?} commit(s) behind the container — moving it forward"
        # reset --hard discards local work, so snapshot anything dirty first. This
        # has to be recoverable: the whole point of cpull is not losing things.
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ]; then
          local bk btar
          bk="$HOME/.local/state/wt/cpull-backup"; mkdir -p "$bk"
          btar="$bk/$name-$(date +%Y%m%d-%H%M%S).tar.gz"
          ( cd "$dir" && git status --porcelain | sed 's/^...//' | tr -d '"' \
            | tar czf "$btar" -T - 2>/dev/null ) \
            && echo "  local changes snapshotted to $btar"
        fi
        git -C "$dir" reset -q --hard "$rhead" \
          && echo "  worktree now at $(git -C "$dir" log --oneline -1)" \
          || echo "  ⚠ could not move the worktree — git status will look dirty"
      else
        echo "→ local worktree already matches the container"
      fi
    else
      echo "  ⚠ could not fetch '$rbranch' from the mirror — HEAD may not match the container"
    fi
  fi

  echo "→ bringing uncommitted + untracked files home"
  rsync -aq --exclude '.git' --exclude 'node_modules' \
    "$CHOST:$sdir/work/" "$dir/" || echo "  ⚠ rsync reported problems"

  echo "→ bringing the conversation home"
  local pdir jf sid
  pdir="$HOME/.claude/projects/$(slug "$dir")"
  mkdir -p "$pdir"
  jf=$(cssh "ls -t '$sdir/state/claude/projects/-work'/*.jsonl 2>/dev/null | head -1")
  if [ -n "$jf" ]; then
    sid=$(basename "$jf" .jsonl)
    scp -q "$CHOST:$jf" "$pdir/" && echo "  conversation $sid restored"
  else
    echo "  no conversation found in the container"
  fi

  if [ "$keep" -eq 0 ]; then
    echo "→ removing the container (host dirs kept until you wt crm)"
    cssh "docker rm -f '$cname'" >/dev/null 2>&1
  else
    echo "→ container left stopped (--keep)"
    cssh "docker stop '$cname'" >/dev/null 2>&1
  fi

  rm -f "$VMSTATE/$name"
  echo "→ restarting claude locally"
  if [ "$recreate" -eq 1 ]; then
    # rebuild the row so its session_path is the new worktree (tmux cannot move
    # an existing session's cwd, and the sidebar reads it for the Cursor key)
    it kill-session -t "=$name" 2>/dev/null
    it new-session -d -s "$name" -c "$dir" -e WT_SESSION="$name"
    it rename-window -t "=$name:^" claude
    it send-keys -t "=$name:claude" \
      "claude --dangerously-skip-permissions${sid:+ --resume $sid}" Enter
    echo "✓ '$name' is local again in $dir${sid:+ (resumed $sid)}"
    return 0
  fi
  local t="$name"
  it list-windows -t "=$name" -F '#{window_name}' 2>/dev/null | grep -qx claude && t="$name:claude"
  # the attach loop exits by itself once the marker is gone; give it a moment,
  # then launch claude in the shell it falls back to
  sleep 3
  it send-keys -t "$t" C-c
  it send-keys -t "$t" -l "cd $(printf '%q' "$dir") && claude --dangerously-skip-permissions${sid:+ --resume $sid}"
  it send-keys -t "$t" Enter
  echo "✓ '$name' is local again${sid:+ (resumed $sid)}"
}

# a session BORN in the cloud: no local worktree, nothing to migrate. Creates the
# branch on the host from a base ref, seeds .env files off the laptop (they are
# gitignored, so the mirror never carries them), and starts claude in a container.
cmd_cnew() {
  local branch="" base="" prompt="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) prompt="${2:-}"; shift ;;
      -r) repo="${2:-}"; shift ;;
      *) if [ -z "$branch" ]; then branch="$1"; elif [ -z "$base" ]; then base="$1"; fi ;;
    esac
    shift
  done
  [ -z "$branch" ] && die "usage: wt cnew [-r repo] [-p prompt] <branch> [base]"

  [ -z "$repo" ] && repo=$(git rev-parse --show-toplevel 2>/dev/null)
  [ -z "$repo" ] && die "not in a git repo — use: wt cnew -r <repo-path> <branch>"
  repo=$(repo_of_dir "$repo")
  c_cfg "$repo"

  local name; name=$(name_for "$branch")
  it has-session -t "=$name" 2>/dev/null && die "session '$name' already exists"
  [ -f "$VMSTATE/$name" ] && die "'$name' is already remote"

  local mirror sdir work cname
  mirror="wt/mirrors/$(basename "$repo").git"
  sdir="wt/sessions/$name"
  work="$sdir/work"
  cname="wt-$name"
  mem_flags
  reclaim_stale_workdir "$name" "$work"
  cssh "docker image inspect $CIMAGE >/dev/null 2>&1" \
    || die "image $CIMAGE missing on $CHOST — run: wt csetup"

  if [ -z "$base" ]; then
    base=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
    [ -z "$base" ] && base=main
  fi
  echo "→ fetching origin/$base"
  git -C "$repo" fetch origin "$base" --quiet 2>/dev/null || echo "  (fetch failed — using local $base)"
  local start="origin/$base"
  git -C "$repo" rev-parse --verify -q "$start" >/dev/null || start="$base"

  echo "→ seeding mirror with '$base' (first push for a repo sends full history)"
  cssh "[ -d '$mirror' ] || git init -q --bare '$mirror'" || die "mirror init failed"
  git -C "$repo" push -qf "$CHOST:$mirror" "$start:refs/heads/$base" || die "git push failed"

  echo "→ worktree + new branch '$branch' on $CHOST"
  cssh "mkdir -p '$sdir' && git clone -q --local '$mirror' '$work' -b '$base' \
        && cd '$work' && git switch -q -c '$branch'" || die "clone/branch failed"

  # .env files never reach the mirror (gitignored) — copy them from the laptop
  local n=0 f
  while IFS= read -r f; do
    cssh "mkdir -p '$work/$(dirname "$f")'" 2>/dev/null
    scp -q "$repo/$f" "$CHOST:$work/$f" && n=$((n+1))
  done < <(git -C "$repo" ls-files --others --ignored --exclude-standard 2>/dev/null \
           | grep -E '(^|/)\.env[^/]*$')
  echo "→ copied $n env file(s)"

  echo "→ seeding claude config"
  seed_state_config "$sdir/state"

  echo "→ docker run (mem $CMEM · cpus $CCPUS)"
  cssh "docker rm -f '$cname' >/dev/null 2>&1; docker run -d --name '$cname' \
      $MEMFLAGS --cpus='$CCPUS' \
      --restart=unless-stopped \
      -e WT_SESSION='$name' -e WT_BROWSER='${WT_BROWSER:-headless}' \
      -v \"\$HOME/$work\":/work \
      -v \"\$HOME/$sdir/state\":/state \
      -v \"\$HOME/.claude/.credentials.json\":/state/claude/.credentials.json \
      $CSECRETS_MOUNT \
      -v \"\$HOME/.local/state/wt\":/home/dev/.local/state/wt \
      '$CIMAGE' sleep infinity" >/dev/null || die "docker run failed"

  echo "→ installing deps in the background (bun install)"
  cssh "docker exec -d '$cname' bash -lc 'cd /work && bun install'" 2>/dev/null

  mkdir -p "$VMSTATE"
  printf '%s\n%s\n' "$CHOST" "$cname" > "$VMSTATE/$name"
  it new-session -d -s "$name" -c "$repo" -e WT_SESSION="$name"
  it rename-window -t "=$name:^" claude
  it send-keys -t "=$name:claude" -l "$CONF/vm-attach.sh $name"
  it send-keys -t "=$name:claude" Enter
  nohup "$CONF/vm-status-poller.sh" >/dev/null 2>&1 &

  if [ -n "$prompt" ]; then
    # claude needs a moment to boot inside the container before it can be typed at
    ( for _ in $(seq 1 40); do
        sleep 3
        cssh "docker exec '$cname' tmux -L wt capture-pane -t '$name' -p" 2>/dev/null \
          | grep -q 'bypass permissions on' && { "$HOME/.local/bin/wt" send "$name" "$prompt"; break; }
      done ) >/dev/null 2>&1 &
    echo "→ task will be typed in once claude is up"
  fi
  echo "✓ '$name' created on $CHOST in $cname — ☁ in the sidebar, nothing on your laptop"
}

# Clone a cloud session. Everything happens on the host, so no repo data crosses
# the laptop and a clone takes a couple of seconds: git clone --local hardlinks
# the object store (instant, no extra disk), the uncommitted files are rsynced
# host-side, and node_modules is bind-mounted from the source rather than copied
# — the same sharing the local clone gets from its symlink.
cmd_cclone() {
  local src="${1:-}" new="${2:-}"
  [ -z "$src" ] && die "usage: wt clone <session> [newname]"
  [ -f "$VMSTATE/$src" ] || die "'$src' is not a cloud session"
  local scname; scname=$(sed -n 2p "$VMSTATE/$src")
  [ -z "$scname" ] && die "'$src' has no container (VM-mode session — cannot clone)"

  local repo
  repo=$(it list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null \
         | awk -F'|' -v n="$src" '$1==n{print $2}')
  repo=$(repo_of_dir "${repo:-$PWD}")
  [ -z "$repo" ] && repo=$(git config --get wt.defaultrepo 2>/dev/null)
  [ -z "$repo" ] && die "cannot tell which repo '$src' belongs to"
  c_cfg "$repo"
  CHOST=$(head -1 "$VMSTATE/$src")   # the copy must land on the source's own host

  if [ -z "$new" ]; then
    local i
    for i in 2 3 4 5 6 7 8 9; do
      it has-session -t "=${src}-$i" 2>/dev/null || { new="${src}-$i"; break; }
    done
  fi
  [ -z "$new" ] && die "'$src' already has 8 clones — name this one: wt clone $src <name>"
  new=$(name_for "$new")
  it has-session -t "=$new" 2>/dev/null && die "session '$new' already exists"

  local sdir="wt/sessions/$src" ndir="wt/sessions/$new"
  local swork="$sdir/work" work="$ndir/work" cname="wt-$new"
  local mirror="wt/mirrors/$(basename "$repo").git"
  mem_flags
  reclaim_stale_workdir "$new" "$work"
  cssh "test -d ~/'$swork/.git'" || die "no worktree at $CHOST:~/$swork"

  local sbranch
  sbranch=$(cssh "cd ~/'$swork' && git branch --show-current" 2>/dev/null)
  [ -z "$sbranch" ] && die "'$src' is on a detached HEAD — check out a branch first"
  local nbranch="${sbranch}-clone-$(date +%H%M%S)"

  echo "→ cloning $src on $CHOST (branch $nbranch off $sbranch)"
  cssh "mkdir -p ~/'$ndir' \
        && git clone -q --local ~/'$swork' ~/'$work' \
        && cd ~/'$work' && git switch -q -c '$nbranch' \
        && git remote set-url origin ~/'$mirror'" \
    || die "clone failed"

  # uncommitted work + the gitignored .env files, straight across on the host
  echo "→ copying uncommitted work (.env included)"
  cssh "cd ~/'$swork' && { git ls-files -mo --exclude-standard; \
        git ls-files --others --ignored --exclude-standard | grep -E '(^|/)[.]env[^/]*\$'; } \
        | sort -u > /tmp/wt-clone-$$.list; \
        rsync -aq --files-from=/tmp/wt-clone-$$.list ~/'$swork/' ~/'$work/'; \
        wc -l < /tmp/wt-clone-$$.list; rm -f /tmp/wt-clone-$$.list" \
    | sed 's/^ */  /;s/$/ file(s)/'

  # publish the branch immediately: `wt crm` promises the work survives in the
  # mirror, and a clone that was never pushed would not
  cssh "cd ~/'$work' && git push -q origin 'HEAD:refs/heads/$nbranch'" 2>/dev/null \
    || echo "  ⚠ could not publish $nbranch to the mirror"

  echo "→ copying claude config + conversation"
  cssh "cp -a ~/'$sdir/state' ~/'$ndir/state'" || die "state copy failed"

  # the source is live and appending, so the copied conversation can end
  # mid-record; a half-written line makes --resume fail
  local pdir="$ndir/state/claude/projects/-work"
  cssh "python3 - ~/'$pdir' <<'PY'
import glob, json, os, sys
for p in glob.glob(os.path.join(sys.argv[1], '*.jsonl')):
    good = []
    for line in open(p, encoding='utf-8', errors='replace'):
        if not line.strip():
            continue
        try:
            json.loads(line)
        except Exception:
            break
        good.append(line if line.endswith('\n') else line + '\n')
    open(p, 'w', encoding='utf-8').writelines(good)
    print('  conversation records kept:', len(good))
PY"

  local sid
  sid=$(cssh "ls -t ~/'$pdir'/*.jsonl 2>/dev/null | head -1" 2>/dev/null)
  sid=$(basename "${sid:-x}" .jsonl); [ "$sid" = x ] && sid=""
  [ -z "$sid" ] && echo "  no conversation found — the clone starts fresh"

  # node_modules is 5 GB of the average session dir. Share the source's rather
  # than copy it: same effect as the local clone's symlink, zero disk, instant.
  local NM_MOUNT=""
  if cssh "test -d ~/'$swork/node_modules'" 2>/dev/null; then
    NM_MOUNT="-v \"\$HOME/$swork/node_modules\":/work/node_modules"
    echo "→ sharing $src's node_modules (not copied)"
  fi

  echo "→ docker run (mem $CMEM · cpus $CCPUS)"
  cssh "docker rm -f '$cname' >/dev/null 2>&1; docker run -d --name '$cname' \
      $MEMFLAGS --cpus='$CCPUS' \
      --restart=unless-stopped \
      -e WT_SESSION='$new' ${sid:+-e WT_RESUME_ID='$sid'} \
      -e WT_BROWSER='${WT_BROWSER:-headless}' \
      -v \"\$HOME/$work\":/work \
      $NM_MOUNT \
      -v \"\$HOME/$ndir/state\":/state \
      -v \"\$HOME/.claude/.credentials.json\":/state/claude/.credentials.json \
      $CSECRETS_MOUNT \
      -v \"\$HOME/.local/state/wt\":/home/dev/.local/state/wt \
      '$CIMAGE' sleep infinity" >/dev/null || die "docker run failed"

  mkdir -p "$VMSTATE"
  printf '%s\n%s\n' "$CHOST" "$cname" > "$VMSTATE/$new"
  it new-session -d -s "$new" -c "$repo" -e WT_SESSION="$new"
  it rename-window -t "=$new:^" claude
  it send-keys -t "=$new:claude" -l "$CONF/vm-attach.sh $new"
  it send-keys -t "=$new:claude" Enter
  nohup "$CONF/vm-status-poller.sh" >/dev/null 2>&1 &
  echo "✓ '$new' cloned from '$src' in $cname on $CHOST${sid:+ (same conversation)}"
  return 0
}

cmd_crm() {
  local name="${1:-}"
  [ -z "$name" ] && die "usage: wt crm <session>"
  [ -f "$VMSTATE/$name" ] || die "'$name' is not remote"
  CHOST=$(head -1 "$VMSTATE/$name")
  local cname; cname=$(sed -n 2p "$VMSTATE/$name")
  [ -z "$cname" ] && die "'$name' has no container (VM-mode session — use the VM path)"
  cssh "docker rm -f '$cname' >/dev/null 2>&1; rm -rf ~/wt/sessions/'$name'" \
    || die "teardown failed"
  rm -f "$VMSTATE/$name"
  echo "removed $cname and ~/wt/sessions/$name on $CHOST (branch kept in the mirror)"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  csetup) cmd_csetup "$@" ;;
  cnew)   cmd_cnew "$@" ;;
  cpush)  cmd_cpush "$@" ;;
  cpull)  cmd_cpull "$@" ;;
  cclone) cmd_cclone "$@" ;;
  crm)    cmd_crm "$@" ;;
  *) grep '^#   wt' "$0" | sed 's/^#   //'; exit 1 ;;
esac
