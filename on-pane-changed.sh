#!/bin/bash
# Per-workspace Space-row tokens, rescanned on pane events and every 3s:
#   $run          running app: listening ports ("▶ :5173") or a dev-server-looking
#                 foreground command ("▶ yarn dev"). Clears when nothing runs.
#   $git_dirty    working-tree state: "+staged ~modified ?untracked".
#   $git_conflict unmerged paths: "!N" (own token so config can colour it red).
#   $pr_pass / $pr_fail / $pr_pending
#                 open GitHub PR for the branch + CI rollup: "#1705 ✓|✗|●".
#                 Exactly one is set so config can colour each state; refreshed
#                 via `gh` at most once per PR_TTL seconds per workspace, or
#                 immediately when the branch changes. Runs in the background.
# Git tokens clear when the tree is clean; PR tokens clear when there is no
# open PR. Herdr's built-in `branch` and `git_status` (ahead/behind) cover the rest.
#   event hook (pane.created/focused/exited/closed)  → rescan that workspace
#   startup hook                                      → rescan all, then start
#   `poll` (spawned by startup, one per server)       → rescan all every 3s,
# because herdr has no event for "foreground process changed".
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-/tmp}"
dev_re='(yarn(\.js)?|npm|pnpm|bun|npx|turbo)( run)? (dev|start|serve|preview)[a-z:-]*|tauri dev|cargo run|(^| )(vite|next|nuxt|astro|webpack|uvicorn|flask run|rails s)'

# Every process under the pane's shell. Tools like turbo/yarn put children in
# their own process groups, so the foreground group alone misses the server.
descendants() {
  local kids; kids=$(pgrep -P "$1"); for k in $kids; do echo "$k"; descendants "$k"; done
}

PR_TTL=60

# Background: one gh call per workspace per PR_TTL (or on branch change).
pr_scan() {
  local ws="$1" path="$2" branch="$3" stamp="$state/pr-$ws" lock="$state/pr-$ws.lock"
  command -v gh >/dev/null || return 0
  if [ -f "$stamp" ]; then
    read -r last lastbranch < "$stamp"
    [ "$lastbranch" = "$branch" ] && (( $(date +%s) - last < PR_TTL )) && return 0
  fi
  mkdir "$lock" 2>/dev/null || return 0
  (
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    echo "$(date +%s) $branch" > "$stamp"
    local json label="" tok
    json=$(cd "$path" && gh pr view "$branch" --json number,state,statusCheckRollup 2>/dev/null)
    if [ -n "$json" ] && [ "$(jq -r .state <<< "$json")" = "OPEN" ]; then
      tok=$(jq -r '
        [.statusCheckRollup[]? | if .__typename=="StatusContext" then .state else
           (if .status!="COMPLETED" then "PENDING" else .conclusion end) end] as $c
        | if ($c|any(.=="FAILURE" or .=="ERROR" or .=="TIMED_OUT" or .=="CANCELLED" or .=="ACTION_REQUIRED" or .=="STARTUP_FAILURE")) then "pr_fail"
          elif ($c|any(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED" or .=="EXPECTED")) then "pr_pending"
          else "pr_pass" end' <<< "$json")
      case "$tok" in pr_pass) label="#$(jq -r .number <<< "$json") ✓";; pr_fail) label="#$(jq -r .number <<< "$json") ✗";; *) label="#$(jq -r .number <<< "$json") ●";; esac
    fi
    local args=()
    for t in pr_pass pr_fail pr_pending; do
      if [ "$t" = "${tok:-}" ] && [ -n "$label" ]; then args+=(--token "$t=$label"); else args+=(--clear-token "$t"); fi
    done
    "$herdr" workspace report-metadata "$ws" --source worktree-pr "${args[@]}" >/dev/null
  ) &
}

git_scan() {
  local ws="$1" path="$2" st staged=0 mod=0 unt=0 conf=0 dirty=""
  [ -n "$path" ] && [ -d "$path" ] || return 0
  st=$(git -C "$path" status --porcelain 2>/dev/null) || return 0
  pr_scan "$ws" "$path" "$(git -C "$path" branch --show-current 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local x="${line:0:1}" y="${line:1:1}"
    case "$x$y" in
      '??') unt=$((unt+1)); continue ;;
      DD|AU|UD|UA|DU|AA|UU) conf=$((conf+1)); continue ;;
    esac
    [ "$x" != ' ' ] && staged=$((staged+1))
    [ "$y" != ' ' ] && mod=$((mod+1))
  done <<< "$st"
  (( staged )) && dirty+="+$staged "
  (( mod ))    && dirty+="~$mod "
  (( unt ))    && dirty+="?$unt "
  local args=()
  [ -n "$dirty" ] && args+=(--token "git_dirty=${dirty% }")    || args+=(--clear-token git_dirty)
  (( conf ))     && args+=(--token "git_conflict=!$conf")      || args+=(--clear-token git_conflict)
  "$herdr" workspace report-metadata "$ws" --source worktree-git "${args[@]}" >/dev/null
}

scan() { # $1 workspace id, $2 checkout path ("" when not a git workspace)
  local ws="$1" ports="" cmd="" label
  git_scan "$ws" "$2"
  while read -r pane; do
    [ -n "$pane" ] || continue
    info=$("$herdr" pane process-info --pane "$pane" 2>/dev/null | jq -c '.result.process_info // empty')
    [ -n "$info" ] || continue
    shell=$(jq -r '.shell_pid // empty' <<< "$info")
    [ -n "$shell" ] || continue
    pids=$(descendants "$shell" | paste -sd, -)
    [ -n "$pids" ] || continue
    p=$(lsof -a -nP -iTCP -sTCP:LISTEN -p "$pids" -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9]*\)$/:\1/p' | sort -un | tr '\n' ' ')
    ports="$ports$p"
    [ -n "$cmd" ] && continue
    cmd=$(jq -r '.foreground_processes[].cmdline // empty' <<< "$info" | grep -oE "$dev_re" | head -1)
  done < <("$herdr" pane list --workspace "$ws" 2>/dev/null | jq -r '.result.panes[].pane_id')
  if   [ -n "$ports" ]; then label="▶ $(tr ' ' '\n' <<< "$ports" | grep . | sort -u | paste -sd' ' -)"
  elif [ -n "$cmd" ];   then label="▶ $cmd"
  fi
  if [ -n "${label:-}" ]; then
    "$herdr" workspace report-metadata "$ws" --source worktree-run --token run="$label" >/dev/null
  else
    "$herdr" workspace report-metadata "$ws" --source worktree-run --clear-token run >/dev/null
  fi
}

ws_path() { "$herdr" workspace list 2>/dev/null | jq -r --arg w "$1" '.result.workspaces[] | select(.workspace_id==$w) | .worktree.checkout_path // empty'; }
scan_all() { # one workspace.list call per tick; ids and paths come from the same JSON
  while IFS=$'\t' read -r ws path; do scan "$ws" "$path"; done \
    < <("$herdr" workspace list 2>/dev/null | jq -r '.result.workspaces[] | [.workspace_id, (.worktree.checkout_path // "")] | @tsv')
}

if [ "${1:-}" = "poll" ]; then
  [ "$(pgrep -f "on-pane-changed.sh poll" | grep -vc "^$$\$")" -gt 0 ] && exit 0
  # Die with the server: the socket disappears when it stops.
  while [ -S "${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" ]; do scan_all; sleep 3; done
  exit 0
fi

if [ "${HERDR_PLUGIN_EVENT:-}" = "startup" ]; then
  scan_all
  nohup bash "$0" poll >/dev/null 2>&1 &
  exit 0
fi

ev="${HERDR_PLUGIN_EVENT_JSON:-null}"
ws=$(jq -r '.data.pane.workspace_id // .data.workspace_id // empty' <<< "$ev")
[ -n "$ws" ] || ws="${HERDR_WORKSPACE_ID:-}"
[ -n "$ws" ] || exit 0

# Coalesce: first hook in a burst waits briefly then scans; the rest exit.
lock="$state/run-scan-$ws.lock"
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null' EXIT
sleep 0.4
scan "$ws" "$(ws_path "$ws")"
