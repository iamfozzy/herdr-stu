#!/bin/bash
# Event hook for worktree.created. Copies .env from the source repo into the
# new checkout, then opens a pane in the new workspace running bootstrap.sh so
# yarn output is visible. Status goes to the Space row via the $setup token.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
ev="$HERDR_PLUGIN_EVENT_JSON"   # {"event":"worktree_created","data":{workspace:{…},worktree:{…}}}
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-{\}}"
ws=$(jq -r '.data.workspace.workspace_id' <<< "$ev")
wt=$(jq -r '.data.worktree.path' <<< "$ev")
root=$(jq -r '.data.workspace.worktree.repo_root // empty' <<< "$ev")
[ -z "$root" ] && root=$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")

report() { "$herdr" workspace report-metadata "$ws" --source stu-bootstrap --token setup="$1" >/dev/null; }

# 1. .env — copy from the source repo unless the checkout already has one
if [ -f "$root/.env" ] && [ ! -e "$wt/.env" ]; then
  cp "$root/.env" "$wt/.env" || report "✗ .env copy failed"
fi

# 2. yarn steps, only for a yarn project
[ -f "$wt/package.json" ] || exit 0

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
"$herdr" pane run "$new" "bash '$HERDR_PLUGIN_ROOT/bootstrap.sh' '$ws' '$herdr'"
