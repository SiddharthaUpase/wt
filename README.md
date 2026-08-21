# wt

A tmux-native hub for running many Claude Code sessions in parallel, each in its
own git worktree.

One sidebar, one session per row, live status glyphs, and a set of verbs for
moving work between sessions. No Electron, no daemon, no database — tmux holds
the sessions and a few files hold the state.

```
 ● wilson-eval          j/k    move            ⏎  open
 ✋ schema-diet          n      new task        f  clone
 ✔ nuggets              r      rename          h  health
 ○ docs-cleanup         x      kill            g  group
```

## Install

```bash
git clone <this-repo> ~/wt-hub
cd ~/wt-hub && ./install.sh
```

It symlinks `~/.local/bin/wt` and `~/.config/wt` at the repo, so pulling updates
is enough and edits you make here are live. Pass `--copy` if you would rather it
be detached. Anything already installed is moved aside with a timestamp, never
overwritten.

Then:

```bash
git config --global wt.defaultrepo /path/to/your/repo
wt
```

**Requires** tmux 3.2+ (popups and key-tables), git, and python3. macOS and Linux.

## The idea

Every session is a git worktree on its own branch, so several agents can work at
once without touching each other's files. `wt` creates the worktree, copies your
gitignored `.env` files into it, starts Claude Code, and gives it a row in the
sidebar.

```bash
wt                       # open the hub
wt new <branch> [base]   # new worktree + branch + session
wt ls                    # every session and its status
wt rm <session>          # kill the session, remove the worktree, keep the branch
```

## Sidebar keys

| Key | Does |
| --- | --- |
| `j` / `k` / click | move the selection |
| `⏎` | open the selected session |
| `n` | new task (asks for a branch) |
| `f` | **clone** — fork a session: same files, same conversation, new branch |
| `h` | **health** — run `wt doctor` on the selected session |
| `r` / `x` | rename / kill |
| `g` | put the session in a group |
| `1`–`8` | bind the session to an Fn key |
| `F1`–`F8` | peek at a bound session; press again to jump into it |
| `J` / `K` / drag | reorder |
| `e` | open the worktree in your editor |
| `t` | scratchpad — a throwaway Claude in a corner popup |
| `b` | browser session (needs `carbonyl`) |
| `c` / `<` `>` / `q` | fold groups / resize / close the hub |

## Talking between sessions

Sessions can message each other, which is what makes an orchestrator pattern work.

```bash
wt send <session> "message"   # types into that session's Claude and submits
wt peek <session>             # last 40 lines of its screen
wt clone <session> [name]     # fork it, conversation and all
wt current                    # which session the user is looking at
wt tell "message"             # message whichever session that is
```

`config/ORCHESTRATION.md` is written for the agents themselves — point your
sessions at it so they know these verbs exist.

## When a session looks wrong

```bash
wt doctor <session>   # walk the chain, name the broken link
wt doctor             # sweep every session, print only the problems
```

It checks the pane, tmux copy-mode (which silently eats keystrokes and is
invisible otherwise), the status hook, the worktree, and — for cloud sessions —
ssh, the container, the inner tmux, the Claude binary, hooks and host memory.
Every failure line carries the command that fixes it.

## Status hooks

The `●` / `✋` / `✔` glyphs come from Claude Code hooks. Without them rows show
`-`. Add this to `~/.claude/settings.json`, merging with any hooks you already
have:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$HOME/.config/wt/hooks.sh running" }] }],
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.config/wt/hooks.sh running" }] }],
    "PermissionRequest":[{ "matcher": "*", "hooks": [{ "type": "command", "command": "$HOME/.config/wt/hooks.sh waiting" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "$HOME/.config/wt/hooks.sh idle" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "$HOME/.config/wt/hooks.sh end" }] }]
  }
}
```

Use the absolute path — Claude Code does not expand `$HOME` in hook commands.

## Configuration

All optional except `wt.defaultrepo`. Set globally, or per-repo to override.

| Key | Default | What |
| --- | --- | --- |
| `wt.defaultrepo` | — | repo the sidebar's "new task" uses |
| `wt.prefix` | `$USER` | branch prefix, e.g. `you/lisbon-anchor` |
| `wt.root` | `~/worktrees/<repo>` | where worktrees are created |
| `wt.cmd` | `claude --dangerously-skip-permissions` | what each session runs |

Branch names are a random city and object rather than a summary of the task —
short, distinct, and easy to say out loud.

## Cloud sessions — optional

**Everything above works with no cloud setup at all.** Skip this section unless
you want it; the cloud verbs simply refuse with a clear message if unconfigured.

A session can instead run in its own Docker container on a remote host, so it
survives your laptop sleeping and costs it about 3 MB instead of ~70 MB. It stays
the same session — same row, same `wt send`, same `wt peek` — just marked `☁`.

```bash
git config wt.chost <ssh-host>     # required; a box you can ssh to with docker
wt csetup                          # build the image there, once

wt cnew <branch>                   # create a session directly in the cloud
wt cpush <session>                 # move an existing one up
wt cpull <session>                 # bring it home, commits and conversation
wt crm  <session>                  # tear the container down
```

| Key | Default | What |
| --- | --- | --- |
| `wt.chost` | — | ssh host with Docker; **required for cloud** |
| `wt.cimage` | `wt-session:latest` | image name |
| `wt.cmem` | `24g` | container memory ceiling |
| `wt.ccpus` | `4` | CPU limit |
| `wt.csecrets` | `.wt-secrets.env` | file in the host's home, mounted read-only |
| `wt.ceffort` | `high` | reasoning effort inside containers |

Sidebar `u` elevates the selected session, `d` brings it home.

> **Note.** `wt.cmem` defaults to 24 GB with unbounded swap, which overcommits
> badly if you run several containers on a small host. `wt doctor` warns when the
> sum of container ceilings exceeds host RAM. Lower it if your host is modest.

## State on disk

| Path | Holds |
| --- | --- |
| `~/.local/state/wt/status/<session>` | one word: running / waiting / idle |
| `~/.local/state/wt/layout` | sidebar order and groups |
| `~/.local/state/wt/vm/<session>` | marks a session as remote (host, container) |
| `~/.local/state/wt/cpull-backup/` | snapshots taken before a cpull moves your HEAD |

Nothing here is precious except `cpull-backup`. Deleting the rest just resets the
sidebar.

## Caveats

- macOS-first. Desktop notifications use `osascript` and the editor key uses
  `open -a`; both fail quietly on Linux and nothing else depends on them.
- `wt rm` refuses to remove a worktree with uncommitted changes unless you pass
  `--force`.
- The scratchpad and browser session are conveniences; `carbonyl` is only needed
  for `b`.

## License

MIT — see [LICENSE](LICENSE).
