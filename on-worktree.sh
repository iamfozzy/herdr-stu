#!/bin/bash
# Event hook for worktree.created and worktree.opened. Runs the project's
# bootstrap script (see bootstrap.sh) once per checkout, in a visible pane in
# the new workspace. A marker in the plugin state dir records checkouts that
# have been bootstrapped, so reopening one is a no-op.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
ev="$HERDR_PLUGIN_EVENT_JSON"   # {"event":…,"data":{workspace:{…},worktree:{…},already_open?:bool}}
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-{\}}"
ws=$(jq -r '.data.workspace.workspace_id' <<< "$ev")
wt=$(jq -r '.data.worktree.path // .data.worktree.checkout_path' <<< "$ev")
root=$(jq -r '.data.workspace.worktree.repo_root // empty' <<< "$ev")
[ -z "$root" ] && root=$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")

[ "$(jq -r '.data.already_open // false' <<< "$ev")" = "true" ] && exit 0
marker="$HERDR_PLUGIN_STATE_DIR/bootstrapped/$(printf '%s' "$wt" | shasum | cut -c1-16)"
[ -e "$marker" ] && exit 0
project="$HERDR_PLUGIN_CONFIG_DIR/projects/$(basename "$root").sh"
[ -f "$project" ] || exit 0   # nothing configured for this repo

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
"$herdr" pane run "$new" "bash '$HERDR_PLUGIN_ROOT/bootstrap.sh' '$ws' '$root' '$project' '$marker' '$herdr'"
