#!/bin/bash
# Event hook for worktree.created and worktree.opened. Runs the project's
# bootstrap script (see bootstrap.sh) once per checkout, in a visible pane in
# the new workspace. A marker in the plugin state dir records checkouts that
# have been bootstrapped, so reopening one is a no-op.
# Also the "Run bootstrap" action: reruns on the focused workspace, ignoring the
# marker — for retrying after a failure without closing the workspace.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-null}"
if [ -n "${HERDR_PLUGIN_ACTION_ID:-}" ]; then
  ws=$(jq -r '.workspace_id // empty' <<< "$ctx"); [ -n "$ws" ] || ws="${HERDR_WORKSPACE_ID:?no workspace}"
  info=$("$herdr" workspace list | jq -c --arg w "$ws" '.result.workspaces[] | select(.workspace_id==$w)')
  wt=$(jq -r '.worktree.checkout_path // empty' <<< "$info"); root=$(jq -r '.worktree.repo_root // empty' <<< "$info")
  [ -n "$wt" ] || { "$herdr" notification show "Run bootstrap" --body "focused workspace is not a git worktree" >/dev/null; exit 1; }
  force=1
else
  ev="$HERDR_PLUGIN_EVENT_JSON"   # {"event":…,"data":{workspace:{…},worktree:{…},already_open?:bool}}
  ws=$(jq -r '.data.workspace.workspace_id' <<< "$ev")
  wt=$(jq -r '.data.worktree.path // .data.worktree.checkout_path' <<< "$ev")
  root=$(jq -r '.data.workspace.worktree.repo_root // empty' <<< "$ev")
  [ "$(jq -r '.data.already_open // false' <<< "$ev")" = "true" ] && exit 0
  force=""
fi
[ -z "$root" ] && root=$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")

marker="$HERDR_PLUGIN_STATE_DIR/bootstrapped/$(printf '%s' "$wt" | shasum | cut -c1-16)"
[ -z "$force" ] && [ -e "$marker" ] && exit 0
project="$HERDR_PLUGIN_CONFIG_DIR/projects/$(basename "$root").sh"
[ -f "$project" ] || { [ -n "$force" ] && "$herdr" notification show "Run bootstrap" --body "no projects/$(basename "$root").sh configured" >/dev/null; exit 0; }

report() { "$herdr" workspace report-metadata "$ws" --source stu-bootstrap --token setup="$1" >/dev/null; }

# Focused pane of the new workspace, from the invocation context; poll pane list if absent.
pane=$(jq -r '.focused_pane_id // empty' <<< "$ctx")
for _ in $(seq 1 40); do
  [ -n "$pane" ] && break
  sleep 0.25
  pane=$("$herdr" pane list --workspace "$ws" 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
done
if [ -z "$pane" ]; then report "✗ no pane to run bootstrap in"; exit 1; fi

new=$("$herdr" pane split "$pane" --direction down --ratio 0.35 --cwd "$wt" --no-focus \
      | jq -r '[.. | objects | .pane_id? // empty] | last')
if [ -z "$new" ] || [ "$new" = "null" ]; then report "✗ could not open bootstrap pane"; exit 1; fi
"$herdr" pane rename "$new" "bootstrap" >/dev/null
# Remembered so on-pane-changed.sh can clear the $setup token if this pane is closed.
mkdir -p "$HERDR_PLUGIN_STATE_DIR/bootstrap-pane" && printf '%s' "$new" > "$HERDR_PLUGIN_STATE_DIR/bootstrap-pane/$ws"
"$herdr" pane run "$new" "bash '$HERDR_PLUGIN_ROOT/bootstrap.sh' '$ws' '$root' '$project' '$marker' '$herdr'"
