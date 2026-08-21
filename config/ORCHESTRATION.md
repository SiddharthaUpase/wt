# wt session orchestration

You are running inside a `wt` worktree session. Your session name is in `$WT_SESSION`
(repo: `$WT_REPO`, branch: `$WT_BRANCH`). Sibling sessions are other Claude Code
instances working in parallel worktrees on this machine.

## See what's running

- `wt ls` — every session: status, name, window count, worktree path
- Status meanings: `running` (mid-turn), `waiting` (needs input — possibly yours),
  `idle` (finished its last turn), `-` (no status yet)
- Machine-readable status for polling: `cat ~/.local/state/wt/status/<session>`
- `wt mv <old> <new>` — rename a session (worktree dir + branch unchanged).
  Status files are keyed by the live session name, so re-check `wt ls` if a
  status file you were polling disappears.

## Talk to another session

- `wt send <session> "message"` — types the message into that session's Claude
  input and submits it. Your identity is prefixed automatically as
  `[from: <your-session>]`. Refuses if the target isn't running claude.
- `wt peek <session>` — read the last 40 lines of its screen. Do this before
  interrupting a `running` session.
- If you receive a message starting with `[from: X]`, it came from sibling
  session X, not from the user. Reply with `wt send X "..."`.

## When a session looks dead

`wt doctor <session>` walks the whole chain and names the broken link instead of
making you guess: ssh reachability, the container, the inner tmux, copy-mode,
the claude binary, the status hooks, memory, and host headroom. Every failure
mode looks identical from the sidebar, so start here rather than theorising.

`wt doctor` with no argument sweeps every session and prints only the ones with
something wrong. It takes about 20 seconds for the whole fleet.

Two failures it exists to catch, because neither is visible any other way:

- **Inner copy-mode.** A container's tmux pane in copy-mode swallows every
  keystroke. The laptop-side pane reads perfectly healthy, so the session looks
  alive and simply ignores you.
- **Missing hooks.** A session whose `settings.json` has no hooks can never
  report status, so its sidebar row shows `-` forever and looks abandoned.

Sidebar: `h` on the selected row.

## Reach the user (not a session)

- `wt current` — prints the session the user is viewing right now.
- `wt tell "message"` — sends the message to the session the user is viewing.
  If the user is already viewing your session, it skips the send and says so.
  Use it only when the user must know or act now; for routine progress stay
  silent — the sidebar shows your status.
- `wt open [session]` — switches the user's hub view to a session (default:
  your own). Use it when the user asks to be taken somewhere, or right after a
  `wt tell` that points at your session. Never steal the view for routine
  updates.

## Clone a session

`wt clone <session> [newname]` makes a second session that starts where the
first one is: same files, same uncommitted work, same `.env`, and the same
claude conversation — but on its own branch (`<branch>-clone-<time>`) and in its
own worktree. The source keeps running, untouched. Use it to try a second
approach without losing the first, or to hand a copy of your context to a
sibling agent.

- The default name is `<session>-2`, then `-3`, and so on.
- You can clone yourself: `wt clone "$WT_SESSION"` — the source does not have to
  stop, unlike `cpush`.
- A cloud session is cloned in the cloud. Nothing is copied to the laptop, the
  git objects are hardlinked, and `node_modules` is shared with the source, so a
  clone costs seconds and almost no disk.
- The two sessions share nothing afterwards except that `node_modules`. Commits,
  files, and conversation diverge from the moment of the clone.
- Sidebar: `f` on the selected row.

## Cloud sessions (one Docker container each)

A session can run on this laptop or in its own container on a remote host. It is
the same session either way: same sidebar row, same `wt send` / `wt peek` /
`wt tell`, same status glyphs. Cloud rows are marked `☁`.

**Am I in a container?** `[ -f /.dockerenv ]` is true, your worktree is `/work`,
and `~/.claude` lives on `/state`. Otherwise you are on the laptop.

- `wt cnew [-p "task"] <branch> [base]` — create a NEW session directly in the
  cloud. No local worktree is made and nothing runs on the laptop. This is the
  right way to fan work out: it costs the laptop ~3 MB (an ssh process) instead
  of ~70 MB for a local session.
- `wt cpush <session>` — move an existing local session up (worktree,
  uncommitted files, `.env`, and the full claude conversation all travel).
- `wt cpush --as <newname> <session>` — elevate a COPY; the original keeps
  running locally, untouched. Use when you want a rollback.
- `wt cpull [--keep] <session>` — bring it home again. Commits go to the host
  mirror, uncommitted work and the conversation come back, and claude resumes
  where the remote one stopped. A cloud-born session gets a real local worktree
  created for it at this point.
- `wt crm <session>` — tear the container down. The branch survives in the host
  mirror, so the work is recoverable.

You can bounce a session up and down as often as you like; the conversation
survives every hop.

### Messaging from inside a container

A container's tmux server holds only its own session, and it has no route to the
laptop or to sibling containers. So `wt` in a container is a small shim:

- `wt ls [--json]` — the whole fleet, local and cloud (the hub publishes it)
- `wt send <session> <message>` — reaches any session, local or cloud
- `wt spawn [--branch <name>] <task>` — create a NEW cloud session on that task.
  The hub builds it and messages you back with its name.
- `wt clone [<session>] [<newname>]` — clone a session (default: you) into a
  second container with the same work and conversation. The hub does the build
  and messages you the result.
- `wt whoami` — this session's name

Sends are queued and delivered by the hub within a few seconds, so treat them as
asynchronous — do not send and immediately expect a reply. A spawn takes a
minute or two; you get a `[from: hub]` message when the session exists. Spawning
is capped fleet-wide, so a runaway loop refuses rather than filling the host. The other verbs
(`peek`, `new`, `cpush`, `rm`) are laptop-side only and are not available here.
A clone takes about a minute and reports back the same way a spawn does.

### Rules

- **A session cannot elevate itself.** `cpush` has to exit the very claude that
  runs it. Ask a sibling session, or the user, to run it for you.
- Run `cpush` only when the target is idle — a mid-turn claude will not exit and
  the push aborts safely.
- Never `cpull` or `crm` a session you did not create.

### What you get inside a container

Secrets and shell environment are already loaded (`LANGSMITH_API_KEY_PROD`,
`GITHUB_TOKEN`, `SLACK_BOT_TOKEN`, `NODE_ENV`, and the rest) — they come from
the host's secrets file (see `wt.csecrets`), so do not go looking for a `.zshrc`.
`node_modules` is installed, git is authenticated through the host mirror, and
headless Chromium is available for Playwright. Each container has a generous
memory ceiling (24 GB) and 4 CPUs, and can spill into swap rather than be
killed — so a heavy build slows itself down, not the whole host.

## Testing an app in a container (use the browser CLI, not the MCP)

Inside a container the `claude-in-chrome` MCP does **not** work — it drives a
Chrome extension on the user's Mac. Use the `agent-browser` CLI instead. It is
already installed, along with Chromium, and the browser persists between
commands, so you do not need to write Playwright scripts:

```bash
agent-browser open http://localhost:3000
agent-browser snapshot -i        # interactive elements with @refs — read this,
                                 # do not screenshot unless asked
agent-browser click @e2
agent-browser eval "document.querySelector('#out').textContent"
agent-browser get title
```

Start your dev server in the container and point the browser at `localhost` —
both live in the same container, so no port forwarding is involved.

Two things to know:

- This browser is **signed into nothing**. It is for testing the app you are
  building. Acting as one of the user's logged-in accounts is a different tool
  (`browser-fleet`, on their Mac) and cannot be reached from here.
- A browser adds roughly 1.5 GB while running. Close it
  when a check is finished if the session is also running builds.

## A logged-in browser in the cloud (Kernel)

You have **two** browsers, and they are not interchangeable.

| | The container browser | Kernel |
|---|---|---|
| Signed into | nothing | any account, and it stays signed in |
| Can reach your dev server on `localhost` | **yes** | **no** — it runs on Kernel's machines |
| Cost | free | $0.06 per GB-hour of ACTIVE time, idle is free |
| Use it for | testing the app you are building | acting on the real internet as a real person |

Use the container browser (see the section above) for anything on `localhost`.
Use Kernel when the task needs to *be* someone: a dashboard behind a login, a
SaaS app behind Google SSO, an authenticated page.

### Using Kernel

`KERNEL_API_KEY` arrives in every new container through `/state/secrets.env`. If
your shell does not have it, run `source /state/secrets.env` — containers
created before the key was added need that once.

The shared profile is **`sid`**. It already holds the logins, so use it rather
than making your own. Profiles are per identity, never per session.

`agent-browser -p kernel` works, but **do not set `KERNEL_PROFILE_NAME`** — that
path is broken in agent-browser 0.34.0, which sends the profile as a string
while Kernel's API wants an object, so every call fails with `cannot unmarshal
string into Go struct field BrowserRequest.profile`. Drive the profile through
the REST API instead and attach over CDP:

```bash
source /state/secrets.env
# 1. start a browser bound to the shared profile
curl -s -X POST https://api.onkernel.com/browsers \
  -H "Authorization: Bearer $KERNEL_API_KEY" -H "Content-Type: application/json" \
  -d '{"profile":{"name":"sid","save_changes":true},"timeout_seconds":900}' > /tmp/kb.json
# 2. attach — `connect` takes a URL, not just a port
agent-browser --session k connect "$(python3 -c "import json;print(json.load(open('/tmp/kb.json'))['cdp_ws_url'])")"
agent-browser --session k open https://example.com
agent-browser --session k snapshot -i
# 3. ALWAYS destroy it — this is both the cleanup and the profile save
curl -s -X DELETE "https://api.onkernel.com/browsers/$(python3 -c "import json;print(json.load(open('/tmp/kb.json'))['session_id'])")" \
  -H "Authorization: Bearer $KERNEL_API_KEY"
```

### Rules

- **Always `DELETE` the browser when you finish.** It is what flushes cookies
  back to the profile, and it is what stops the billing. A forgotten session can
  run for hours.
- Set a `timeout_seconds` you actually need. It is a backstop, not a plan.
- Never attempt a fresh login from the agent. The profile is already signed in;
  ride it. If a site wants a real login, ask the user — they open the browser's
  live view URL and do it once, and the profile keeps it.
- Never type passwords, card numbers or account numbers into a page.
- The profile is shared, so two agents driving it at once will fight. Say what
  you are doing in your session before a long browsing job.

## Browser sessions

`wt browser <name> <url>` makes a Chromium-in-the-terminal session (Carbonyl)
that behaves like any other row — useful for keeping a dashboard glanceable.

## Spawn and manage workers (orchestrator pattern)

- Spawn: from the laptop, `wt cnew -p "<task>" "$(wt slug "<task>")"` puts the
  worker in the cloud (preferred — it costs this machine almost nothing).
  `wt new --no-ui -p "<task>" ...` keeps it local. From inside a container use
  `wt spawn "<task>"`.
- Monitor: poll `~/.local/state/wt/status/<worker>` every 30-60s (sleep between
  polls). `idle` = turn finished; `waiting` = stuck, unblock it with `wt send`.
- Collect: `wt peek <worker>` for a glance; for real handoffs, tell workers in
  their task prompt to commit their work and write a summary to a known file.
- Tear down: `wt rm --force <worker>` — only for workers you spawned. The
  branch survives, so their work stays recoverable.

## Rules

- Never `wt rm` a session you didn't spawn.
- Don't message a `running` session unless it matters — your text queues into
  its input and lands mid-work.
- Keep messages self-contained; the receiver has none of your conversation
  context.
