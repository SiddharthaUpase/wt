#!/bin/bash
# wt hub sidebar — session list with live status. Runs in the hub's left pane.
SOCK=wt
STATE="$HOME/.local/state/wt/status"
WT="$HOME/.local/bin/wt"

BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
RED=$(tput setaf 1); GREEN=$(tput setaf 2); GREY=$(tput setaf 8)

printf '\e[?25l'                      # hide cursor; renders are silent overwrites
printf '\e[?7l'                       # no auto-wrap: long lines clip, never scroll the pane
printf '\e[?1000h\e[?1006h'           # SGR mouse reporting: clicks + wheel
trap "printf '\e[?25h\e[?7h\e[?1000l\e[?1006l'" EXIT
mouse_off() { printf '\e[?1000l\e[?1006l\e[?7h'; }   # prompt mode: wrap back on for typing
mouse_on()  { printf '\e[?1000h\e[?1006h\e[?7l'; }

sel=0
press_row=""
prev_frame=__force__
resized=0
trap 'resized=1' WINCH                # pane rescaled: junk on screen, full repaint needed
LAYOUT="$HOME/.local/state/wt/layout"
declare -a NAMES PATHS WINS GRPS ROWMAP LIVE_N LIVE_P LIVE_W F_N F_G GORDER

# Session order + grouping persist in $LAYOUT: ungrouped names first, then
# "[group]" headers each followed by member names. Sessions missing from the
# file join the end of the ungrouped block; dead names are skipped on load but
# kept in the file, so a respawned branch lands back in its old group.
in_layout() {
  local i
  for i in "${!F_N[@]}"; do [ "${F_N[$i]}" = "$1" ] && return 0; done
  return 1
}

append_session() {  # $1 name · $2 group — skips dead names and duplicates
  local i
  for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$1" ] && return; done
  for i in "${!LIVE_N[@]}"; do
    if [ "${LIVE_N[$i]}" = "$1" ]; then
      NAMES+=("$1"); PATHS+=("${LIVE_P[$i]}"); WINS+=("${LIVE_W[$i]}"); GRPS+=("$2")
      return
    fi
  done
}

load() {
  local n p w g i j line seen
  LIVE_N=(); LIVE_P=(); LIVE_W=()
  while IFS='|' read -r n p w; do
    LIVE_N+=("$n"); LIVE_P+=("$p"); LIVE_W+=("$w")
  done < <(tmux -L $SOCK list-sessions \
             -F '#{session_name}|#{session_path}|#{session_windows}' 2>/dev/null | sort)
  F_N=(); F_G=(); g=""
  if [ -f "$LAYOUT" ]; then
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        \[*\]) g="${line#\[}"; g="${g%\]}" ;;
        *) F_N+=("$line"); F_G+=("$g") ;;
      esac
    done < "$LAYOUT"
  fi
  GORDER=("")
  for i in "${!F_G[@]}"; do
    [ -z "${F_G[$i]}" ] && continue
    seen=0
    for j in "${!GORDER[@]}"; do [ "${GORDER[$j]}" = "${F_G[$i]}" ] && seen=1; done
    [ "$seen" -eq 0 ] && GORDER+=("${F_G[$i]}")
  done
  NAMES=(); PATHS=(); WINS=(); GRPS=()
  for j in "${!GORDER[@]}"; do
    g="${GORDER[$j]}"
    for i in "${!F_N[@]}"; do
      [ "${F_G[$i]}" = "$g" ] && append_session "${F_N[$i]}" "$g"
    done
    if [ -z "$g" ]; then
      for i in "${!LIVE_N[@]}"; do
        in_layout "${LIVE_N[$i]}" || append_session "${LIVE_N[$i]}" ""
      done
    fi
  done
  local count=${#NAMES[@]}
  if [ "$count" -eq 0 ]; then sel=0
  elif [ "$sel" -ge "$count" ]; then sel=$((count - 1)); fi
}

save_layout() {
  local i g="" out=""
  for i in "${!NAMES[@]}"; do
    [ "${GRPS[$i]}" != "$g" ] && { g="${GRPS[$i]}"; out+="[$g]"$'\n'; }
    out+="${NAMES[$i]}"$'\n'
  done
  printf '%s' "$out" > "$LAYOUT.tmp" && mv "$LAYOUT.tmp" "$LAYOUT"
}

reorder() {  # $1 from-idx · $2 insert-idx (in the array after removal) · $3 group
  local i="$1" t="$2" g="$3"
  local n="${NAMES[$i]}" p="${PATHS[$i]}" w="${WINS[$i]}"
  NAMES=("${NAMES[@]:0:$i}" "${NAMES[@]:$((i+1))}")
  PATHS=("${PATHS[@]:0:$i}" "${PATHS[@]:$((i+1))}")
  WINS=("${WINS[@]:0:$i}"   "${WINS[@]:$((i+1))}")
  GRPS=("${GRPS[@]:0:$i}" "${GRPS[@]:$((i+1))}")
  NAMES=("${NAMES[@]:0:$t}" "$n" "${NAMES[@]:$t}")
  PATHS=("${PATHS[@]:0:$t}" "$p" "${PATHS[@]:$t}")
  WINS=("${WINS[@]:0:$t}"   "$w" "${WINS[@]:$t}")
  GRPS=("${GRPS[@]:0:$t}" "$g" "${GRPS[@]:$t}")
  sel="$t"
  save_layout
}

swap() {
  local a="$1" b="$2" t
  t="${NAMES[$a]}";  NAMES[$a]="${NAMES[$b]}";  NAMES[$b]="$t"
  t="${PATHS[$a]}";  PATHS[$a]="${PATHS[$b]}";  PATHS[$b]="$t"
  t="${WINS[$a]}";   WINS[$a]="${WINS[$b]}";    WINS[$b]="$t"
  t="${GRPS[$a]}"; GRPS[$a]="${GRPS[$b]}"; GRPS[$b]="$t"
}

move_sel() {  # J/K: swap within the group; crossing a boundary adopts the next group
  local i="$sel" j
  [ ${#NAMES[@]} -eq 0 ] && return
  j=$((i + $1))
  if [ "$j" -lt 0 ]; then   # pushed past the top: fall out into the ungrouped block
    [ -n "${GRPS[$i]}" ] && { GRPS[$i]=""; save_layout; }
    return
  fi
  [ "$j" -ge ${#NAMES[@]} ] && return
  if [ "${GRPS[$i]}" = "${GRPS[$j]}" ]; then
    swap "$i" "$j"; sel="$j"; save_layout
  else
    GRPS[$i]="${GRPS[$j]}"; save_layout
  fi
}

drag_drop() {  # $1 press row · $2 release row — drop a session onto another row
  local fi="${ROWMAP[$1]:-}" ti="${ROWMAP[$2]:-}" i j g
  case "$fi" in s:*) i="${fi#s:}" ;; *) return ;; esac
  case "$ti" in
    s:*)
      j="${ti#s:}"
      [ "$j" = "$i" ] && return
      reorder "$i" "$j" "${GRPS[$j]}"   # land on the dropped row, adopt its group
      ;;
    h:*)
      g="${ti#h:}"
      for j in "${!GRPS[@]}"; do
        if [ "${GRPS[$j]}" = "$g" ]; then
          [ "$i" -lt "$j" ] && j=$((j-1))
          reorder "$i" "$j" "$g"          # onto a header = top of that group
          return
        fi
      done
      ;;
  esac
}

# The status file is hook-written and goes stale: a turn that ends without a
# Stop event leaves it on "running" forever, so the row shows ● indefinitely.
# Reconcile lazily — only for rows claiming "running" whose file has not been
# touched for a while. A genuinely busy session gets its file rewritten by the
# PreToolUse hook constantly, so this checks only the suspicious ones and costs
# nothing on a quiet hub.
STALE_AFTER=45
state_of() {
  local st age
  st=$(cat "$STATE/$1" 2>/dev/null) || { echo new; return; }
  if [ "$st" = running ]; then
    age=$(( $(date +%s) - $(stat -f %m "$STATE/$1" 2>/dev/null || echo 0) ))
    if [ "$age" -gt "$STALE_AFTER" ] \
       && ! tmux -L $SOCK capture-pane -t "$1" -p 2>/dev/null | grep -qE 'esc to inter'; then
      echo idle > "$STATE/$1"        # self-heal so the glyph stops lying
      st=idle
    fi
  fi
  printf '%s\n' "${st:-new}"
}

KEYS="$HOME/.local/state/wt/keys"

# digit 1-8: bind the selected session to that Fn key (pressing the same digit
# on the same session unbinds it). One session per key; a session may hold only
# one key, so re-assigning moves it.
assign_key() {
  local d="$1" k="F$1" cur f
  [ ${#NAMES[@]} -eq 0 ] && return
  mkdir -p "$KEYS"
  cur=$(cat "$KEYS/$k" 2>/dev/null)
  if [ "$cur" = "${NAMES[$sel]}" ]; then
    rm -f "$KEYS/$k"
    return
  fi
  for f in "$KEYS"/F[1-8]; do            # drop any key this session already had
    [ -f "$f" ] && [ "$(cat "$f")" = "${NAMES[$sel]}" ] && rm -f "$f"
  done
  printf '%s\n' "${NAMES[$sel]}" > "$KEYS/$k"
}

# name → "F3", for the row badge
key_of() {
  local f
  for f in "$KEYS"/F[1-8]; do
    [ -f "$f" ] && [ "$(cat "$f")" = "$1" ] && { basename "$f"; return; }
  done
}

WIDTH_FILE="$HOME/.local/state/wt/sidebar-width"
stored_width() { cat "$WIDTH_FILE" 2>/dev/null || echo 28; }
set_width() { tmux resize-pane -t "$TMUX_PANE" -x "$1" 2>/dev/null; }   # $TMUX = hub server

resize_by() {
  local w=$(( $(tput cols) + $1 ))
  [ "$w" -lt 14 ] && w=14
  [ "$w" -gt 60 ] && w=60
  set_width "$w"; echo "$w" > "$WIDTH_FILE"
}

toggle_collapse() {
  if [ "$(tput cols)" -le 8 ]; then
    set_width "$(stored_width)"          # expand back
  else
    echo "$(tput cols)" > "$WIDTH_FILE"  # remember, then fold to glyph strip
    set_width 6
  fi
}

glyph() {
  case "$1" in
    running) printf '%s●%s' "$GREEN" "$RESET" ;;
    waiting) printf '%s✋%s' "$RED" "$RESET" ;;
    idle)    printf '%s✔%s' "$GREY" "$RESET" ;;
    *)       printf '%s○%s' "$GREY" "$RESET" ;;
  esac
}

# the inner-tmux client living in the hub's other pane
right_client() {
  local rtty
  rtty=$(tmux list-panes -F '#{pane_id} #{pane_tty}' 2>/dev/null \
         | awk -v me="$TMUX_PANE" '$1!=me{print $2}' | head -1)
  tmux -L $SOCK list-clients -F '#{client_tty} #{client_name}' 2>/dev/null \
    | awk -v t="$rtty" '$1==t{print $2}'
}

switch_to() {
  [ -z "${1:-}" ] && return
  local c; c=$(right_client)
  [ -n "$c" ] && tmux -L $SOCK switch-client -c "$c" -t "=$1" 2>/dev/null
}

# the session shown in the right pane — lets the highlight follow external `wt open`
right_session() {
  local rtty
  rtty=$(tmux list-panes -F '#{pane_id} #{pane_tty}' 2>/dev/null \
         | awk -v me="$TMUX_PANE" '$1!=me{print $2}' | head -1)
  tmux -L $SOCK list-clients -F '#{client_tty} #{client_session}' 2>/dev/null \
    | awk -v t="$rtty" '$1==t{print $2}'
}

sync_sel() {
  local cur i
  cur=$(right_session)
  [ -z "$cur" ] && return
  [ "${NAMES[$sel]:-}" = "$cur" ] && return
  for i in "${!NAMES[@]}"; do
    [ "${NAMES[$i]}" = "$cur" ] && { sel="$i"; return; }
  done
}

add_line() { frame+="$1"$'\n'; frow=$((frow + 1)); }
map_line() { ROWMAP[$((frow + 1))]="$1"; add_line "$2"; }   # clickable rows

render() {
  local i st mark nm line lastg frame="" frow=0 kb
  ROWMAP=()
  local maxn=$(($(tput cols) - 8))    # glyph+marker prefix takes ~8 cols; never wrap
  [ "$maxn" -lt 6 ] && maxn=6
  map_line top " ${BOLD}WORKTREES${RESET}"
  add_line ""
  if [ ${#NAMES[@]} -eq 0 ]; then
    add_line "  ${DIM}no sessions${RESET}"
  else
    lastg=""
    for i in "${!NAMES[@]}"; do
      if [ "${GRPS[$i]}" != "$lastg" ]; then
        lastg="${GRPS[$i]}"
        add_line ""
        map_line "h:$lastg" " ${GREY}${BOLD}◇ ${lastg:0:$maxn}${RESET}"
      fi
      st=$(state_of "${NAMES[$i]}")
      nm="${NAMES[$i]:0:$maxn}"
      [ -f "$HOME/.local/state/wt/vm/${NAMES[$i]}" ] && nm="☁ ${nm}"
      kb=$(key_of "${NAMES[$i]}")
      [ -n "$kb" ] && nm="${BOLD}${kb}${RESET} ${nm}"
      if [ "$i" -eq "$sel" ]; then mark="${BOLD}❯"; nm="${BOLD}${nm}"; else mark=" "; fi
      [ "$st" = waiting ] && nm="${RED}${nm}"
      line=" ${mark}${RESET} $(glyph "$st") ${nm}${RESET}"
      [ "${WINS[$i]}" -gt 1 ] 2>/dev/null && line+=" ${DIM}⊞${WINS[$i]}${RESET}"
      map_line "s:$i" "$line"
    done
  fi
  add_line ""
  map_line btn " ${BOLD}${GREEN}[ + new task ]${RESET}"
  add_line ""
  add_line " ${DIM}click / j/k · ⏎ open"
  add_line " n new · b browser · r rename"
  add_line " f clone · h health · x kill"
  add_line " g group · 1-8 bind Fn key"
  add_line " J/K/drag · e cursor"
  add_line " u elevate ☁ · d pull down"
  add_line " F1-F8 peek · esc cancel"
  add_line " q quit · c fold · < > width${RESET}"
  # double-buffer: skip the write when nothing changed; otherwise overwrite
  # in place (erase to end of each line, then clear below) — no clear-screen flash
  [ "$frame" = "$prev_frame" ] && return
  prev_frame="$frame"
  printf '\e[?25l\e[H'
  while IFS= read -r line; do printf '%s\e[K\n' "$line"; done <<< "$frame"
  printf '\e[J'
}

# line input that supports Esc-to-cancel (read -e eats Esc as a meta prefix).
# Sets REPLY; returns 1 on Esc. Arrow keys etc. are swallowed.
# The dialog owns the screen, so each redraw jumps to the input's ABSOLUTE row
# and clears everything below — wrapped long input can never drift or repeat.
prompt_line() {
  local p="$1" row="${2:-7}" buf="" c c2
  while true; do
    printf '\e[%d;1H\e[J%s%s' "$row" "$p" "$buf"
    IFS= read -rsn1 c || return 1
    case "$c" in
      $'\x1b')
        if ! read -rsn1 -t 1 c2; then printf '\n'; return 1; fi   # bare Esc
        if [ "$c2" = "[" ]; then
          while read -rsn1 -t 1 c2; do case "$c2" in [A-Za-z~]) break ;; esac; done
        fi ;;
      $'\x7f'|$'\b') buf="${buf%?}" ;;
      "") printf '\n'; REPLY="$buf"; return 0 ;;                  # Enter
      [[:print:]]) buf="$buf$c" ;;
    esac
  done
}

new_task() {
  local task br repo where a
  printf '\e[H\e[2J\e[?25h %snew task%s\n\n' "$BOLD" "$RESET"
  printf ' %sbranch + worktree + claude\n are created automatically\n esc cancels%s\n\n' "$DIM" "$RESET"
  prompt_line " task: " 7 || return
  task="$REPLY"
  [ -z "$task" ] && return
  printf '\n %srun where?%s  %sl%s local (this laptop)   %sc%s cloud ☁ (container)\n ' \
    "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
  read -rsn1 a
  case "$a" in c|C) where=cloud ;; l|L|"") where=local ;; *) return ;; esac
  if [ ${#NAMES[@]} -gt 0 ]; then
    repo=$(git -C "${PATHS[$sel]}" worktree list 2>/dev/null | head -1 | awk '{print $1}')
  fi
  # fall back to git config --global wt.defaultrepo when no session is selected
  [ -z "$repo" ] && repo=$(git config --get wt.defaultrepo 2>/dev/null)
  if [ -z "$repo" ]; then
    printf '\n %sno repo — set one: git config --global wt.defaultrepo <path>%s\n' "$RED" "$RESET"
    printf ' %spress any key%s' "$DIM" "$RESET"; read -rsn1; return
  fi
  br=$("$WT" slug "$task")
  printf '\n\n %sbranch: %s  ·  %s%s\n\n' "$DIM" "$br" "$where" "$RESET"
  local ok=1
  if [ "$where" = cloud ]; then
    "$WT" cnew -r "$repo" -p "$task" "$br" && ok=0
  else
    "$WT" new --no-ui -r "$repo" -p "$task" "$br" && ok=0
  fi
  if [ "$ok" -eq 0 ]; then
    load
    local target i; target=$("$WT" name "$br")
    for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$target" ] && sel=$i; done
    switch_to "$target"
  else
    printf '\n %spress any key%s' "$DIM" "$RESET"; read -rsn1
  fi
}

# u / d — elevate the selected session to the cloud, or bring it home. Both are
# slow (a minute or two), so they run detached: the sidebar keeps redrawing and
# the ☁ appears or disappears when the marker flips.
elevate_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local n="${NAMES[$sel]}" a
  if [ -f "$HOME/.local/state/wt/vm/$n" ]; then
    printf '\n %s%s is already ☁ — press d to bring it home%s ' "$DIM" "$n" "$RESET"
    read -rsn1 a; return
  fi
  # elevating has to make the local claude exit, so it only works when idle.
  # Ask the pane, not the status file — hooks leave that stuck on "running".
  if "$WT" busy "$n"; then
    printf '\n %s%s is mid-turn — let it finish, then elevate%s ' "$RED" "$n" "$RESET"
    read -rsn1 a; return
  fi
  if [ "$(state_of "$n")" = waiting ]; then
    printf '\n %s%s is waiting on a prompt — answer it first%s ' "$RED" "$n" "$RESET"
    read -rsn1 a; return
  fi
  printf '\n %selevate %s to the cloud? [y/N]%s ' "$BOLD" "$n" "$RESET"
  read -rsn1 a
  case "$a" in y|Y) ;; *) return ;; esac
  # foreground on purpose: this takes a minute or two and can fail (host
  # unreachable, image missing, dirty state) — running it detached would hide
  # the error. The sidebar list pauses; the sessions themselves keep running.
  printf '\e[H\e[2J\e[?25h %selevating %s → cloud%s\n\n' "$BOLD" "$n" "$RESET"
  if "$WT" cpush "$n" 2>&1; then
    printf '\n %s✓ %s is now ☁%s\n' "$GREEN" "$n" "$RESET"
  else
    printf '\n %s✗ elevation failed — see the error above%s\n' "$RED" "$RESET"
  fi
  printf '\n %spress any key%s' "$DIM" "$RESET"; read -rsn1
  load
}

# f — clone the selected session: same work, same conversation, new branch. Runs
# in the foreground like elevate, for the same reason: it can fail (dirty dir
# name clash, host unreachable) and a detached failure is invisible.
# h — health check the selected session. Foreground like u/d: the whole point is
# reading the output, and a detached diagnostic helps nobody.
health_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local n="${NAMES[$sel]}"
  printf '\e[H\e[2J\e[?25h %schecking %s%s\n' "$BOLD" "$n" "$RESET"
  "$WT" doctor "$n" 2>&1
  printf ' %spress any key%s' "$DIM" "$RESET"; read -rsn1
  load
}

clone_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local n="${NAMES[$sel]}" a
  printf '\n %sclone %s into a second session? [y/N]%s ' "$BOLD" "$n" "$RESET"
  read -rsn1 a
  case "$a" in y|Y) ;; *) return ;; esac
  printf '\e[H\e[2J\e[?25h %scloning %s%s\n\n' "$BOLD" "$n" "$RESET"
  if "$WT" clone "$n" 2>&1; then
    printf '\n %s✓ cloned%s\n' "$GREEN" "$RESET"
  else
    printf '\n %s✗ clone failed — see the error above%s\n' "$RED" "$RESET"
  fi
  printf '\n %spress any key%s' "$DIM" "$RESET"; read -rsn1
  load
}

pull_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local n="${NAMES[$sel]}" a
  if [ ! -f "$HOME/.local/state/wt/vm/$n" ]; then
    printf '\n %s%s is already local — press u to elevate it%s ' "$DIM" "$n" "$RESET"
    read -rsn1 a; return
  fi
  printf '\n %sbring %s back to this laptop? [y/N]%s ' "$BOLD" "$n" "$RESET"
  read -rsn1 a
  case "$a" in y|Y) ;; *) return ;; esac
  printf '\e[H\e[2J\e[?25h %spulling %s → local%s\n\n' "$BOLD" "$n" "$RESET"
  if "$WT" cpull "$n" 2>&1; then
    printf '\n %s✓ %s is local again%s\n' "$GREEN" "$n" "$RESET"
  else
    printf '\n %s✗ pull failed — see the error above%s\n' "$RED" "$RESET"
  fi
  printf '\n %spress any key%s' "$DIM" "$RESET"; read -rsn1
  load
}

new_browser() {
  local nm url
  printf '\e[H\e[2J\e[?25h %snew browser session%s\n\n' "$BOLD" "$RESET"
  printf ' %sa Chromium pane you can peek with an Fn key\n esc cancels%s\n\n' "$DIM" "$RESET"
  prompt_line " name: " 6 || return
  nm="$REPLY"; [ -z "$nm" ] && return
  prompt_line " url:  " 8 || return
  url="$REPLY"
  "$WT" browser "$nm" ${url:+"$url"} >/dev/null 2>&1
  load
  local i; for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$("$WT" name "$nm")" ] && sel=$i; done
}

rename_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local old="${NAMES[$sel]}" new
  printf '\e[H\e[2J\e[?25h %srename session%s\n\n' "$BOLD" "$RESET"
  printf ' %s%s\n worktree dir + branch stay\n esc cancels%s\n\n' "$DIM" "$old" "$RESET"
  prompt_line " name: " 7 || return
  new="$REPLY"
  [ -z "$new" ] || [ "$new" = "$old" ] && return
  new=$("$WT" name "$new")
  if "$WT" mv "$old" "$new" >/dev/null 2>&1; then
    load
    local i; for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$new" ] && sel=$i; done
  else
    printf '\n %srename failed — name taken?%s\n %spress any key%s' "$RED" "$RESET" "$DIM" "$RESET"
    read -rsn1
  fi
}

group_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local n="${NAMES[$sel]}" cur="${GRPS[$sel]}" g i t list=""
  for i in "${!GRPS[@]}"; do
    g="${GRPS[$i]}"
    [ -z "$g" ] && continue
    case " $list " in *" $g "*) ;; *) list+="${list:+ }$g" ;; esac
  done
  printf '\e[H\e[2J\e[?25h %sgroup session%s\n\n' "$BOLD" "$RESET"
  printf ' %s%s\n now: %s\n groups: %s\n empty ungroups · esc cancels%s\n\n' \
    "$DIM" "$n" "${cur:-—}" "${list:-—}" "$RESET"
  prompt_line " group: " 8 || return
  g="${REPLY//[\[\]]/}"
  [ "$g" = "$cur" ] && return
  if [ -z "$g" ]; then                 # rejoin the end of the ungrouped block
    t=0
    for i in "${!GRPS[@]}"; do [ -z "${GRPS[$i]}" ] && t=$((i + 1)); done
  else                                 # end of the target group; a new group goes last
    t=${#NAMES[@]}
    for i in "${!GRPS[@]}"; do [ "${GRPS[$i]}" = "$g" ] && t=$((i + 1)); done
  fi
  [ "$sel" -lt "$t" ] && t=$((t - 1))
  reorder "$sel" "$t" "$g"
}

kill_sel() {
  [ ${#NAMES[@]} -eq 0 ] && return
  local n="${NAMES[$sel]}" a
  printf '\n %skill %s + remove worktree? [y/N]%s ' "$RED" "$n" "$RESET"
  read -rsn1 a
  case "$a" in y|Y) ;; *) return ;; esac
  if ! "$WT" rm -y "$n" >/dev/null 2>&1; then
    printf '\n %suncommitted changes!%s\n %sdiscard them + delete? [y/N]%s ' "$RED" "$RESET" "$RED" "$RESET"
    read -rsn1 a
    case "$a" in y|Y) "$WT" rm -y --force "$n" >/dev/null 2>&1 ;; esac
  fi
}

load; sync_sel; render
while true; do
  if [ "$resized" = 1 ]; then
    resized=0
    printf '\e[2J'
    prev_frame=__force__
    load; sync_sel; render
  fi
  key=""
  IFS= read -rsn1 -t 2 key
  status=$?
  if [ $status -gt 0 ] && [ -z "$key" ]; then load; sync_sel; render; continue; fi   # tick
  if [ "$key" = $'\x1b' ]; then
    key=""
    read -rsn1 -t 1 k2
    # SS3 form: F1-F4 arrive as ESC O P/Q/R/S on many terminals
    if [ "${k2:-}" = "O" ]; then
      read -rsn1 -t 1 k3
      case "${k3:-}" in P) key=F1 ;; Q) key=F2 ;; esac
    fi
    if [ "${k2:-}" = "[" ]; then
      read -rsn1 -t 1 k3
      case "${k3:-}" in
        A) key=k ;;
        B) key=j ;;
        # CSI form: F1 is ESC [ 1 1 ~ — swallow the digits up to the tilde so
        # the leftovers never land in the key stream as stray input
        [0-9])
          seq="$k3"; c=""
          while read -rsn1 -t 1 c; do
            case "$c" in '~') break ;; *) seq+="$c" ;; esac
          done
          case "$seq" in 11) key=F1 ;; 12) key=F2 ;; esac ;;
        '<')  # SGR mouse event: <btn;col;row then M (press) / m (release)
          seq=""; c=""
          while read -rsn1 -t 1 c; do
            case "$c" in M|m) break ;; *) seq+="$c" ;; esac
          done
          IFS=';' read -r btn _col row <<< "$seq"
          if [ "$c" = M ]; then
            case "$btn" in
              0)  press_row="$row" ;;   # act on release: same row = click, other = drag
              64) key=k ;;   # wheel up
              65) key=j ;;   # wheel down
            esac
          elif [ "$c" = m ] && [ "$btn" = 0 ] && [ -n "$press_row" ]; then
            from="$press_row"; press_row=""
            item="${ROWMAP[$row]:-}"
            if [ "$from" != "$row" ]; then
              drag_drop "$from" "$row"
            elif [ "$row" = 1 ]; then
              toggle_collapse
            else
              case "$item" in
                s:*) sel="${item#s:}"; switch_to "${NAMES[$sel]}" ;;
                h:*) hg="${item#h:}"   # header click: jump to the group's first session
                     for hi in "${!GRPS[@]}"; do
                       [ "${GRPS[$hi]}" = "$hg" ] && { sel=$hi; switch_to "${NAMES[$sel]}"; break; }
                     done ;;
                btn) mouse_off; new_task; mouse_on; prev_frame=__force__ ;;
              esac
            fi
          fi ;;
      esac
    fi
  fi
  case "$key" in
    j) [ $sel -lt $((${#NAMES[@]} - 1)) ] && sel=$((sel + 1)); switch_to "${NAMES[$sel]:-}" ;;
    k) [ $sel -gt 0 ] && sel=$((sel - 1)); switch_to "${NAMES[$sel]:-}" ;;
    "") switch_to "${NAMES[$sel]:-}" ;;          # Enter
    n) mouse_off; new_task; mouse_on; prev_frame=__force__ ;;
    r) mouse_off; rename_sel; mouse_on; prev_frame=__force__ ;;
    g) mouse_off; group_sel; mouse_on; prev_frame=__force__ ;;
    [1-8]) assign_key "$key" ;;
    # the `cursor` CLI isn't installed; open -a drives the app bundle directly
    e) [ ${#NAMES[@]} -gt 0 ] && open -a Cursor "${PATHS[$sel]}" 2>/dev/null ;;
    b) mouse_off; new_browser; mouse_on; prev_frame=__force__ ;;
    u) mouse_off; elevate_sel; mouse_on; prev_frame=__force__ ;;
    d) mouse_off; pull_sel;   mouse_on; prev_frame=__force__ ;;
    f) mouse_off; clone_sel; mouse_on; prev_frame=__force__ ;;
    h) mouse_off; health_sel; mouse_on; prev_frame=__force__ ;;
    x) mouse_off; kill_sel; mouse_on; prev_frame=__force__ ;;
    J) move_sel 1 ;;
    K) move_sel -1 ;;
    # ctrl-t is the single toggle: it opens from here and closes from inside the
    # popup (inner.conf binds it in the scratch session's own key-table). Plain
    # t still opens, for muscle memory. Corner panel, not a full-screen takeover.
    t|$'\x14'|F1) tmux display-popup -T " scratch · F1 closes " -E \
         -w 45% -h 45% -x 0 -y S "$WT scratch --attach" ;;
    w) [ ${#NAMES[@]} -gt 0 ] && tmux display-popup -T " ${NAMES[$sel]} · ctrl-\\ closes " \
         -E -w 70% -h 75% "env TMUX= tmux -L $SOCK attach -t '=${NAMES[$sel]}'" ;;
    c) toggle_collapse ;;
    '<'|,) resize_by -4 ;;
    '>'|.) resize_by 4 ;;
    q) tmux kill-session 2>/dev/null; exit 0 ;;  # closes hub only; sessions live on
  esac
  load; render
done
