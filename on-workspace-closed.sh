#!/bin/bash
# Event hook for workspace.closed. Closing a worktree workspace leaves its
# checkout on disk (Herdr's `workspace close` is UI-only), so offer to delete
# it: open the remove popup pointed at that checkout. Silent for plain
# workspaces and for checkouts already gone.
set -u
ev="$HERDR_PLUGIN_EVENT_JSON"   # {"event":"workspace_closed","data":{workspace:{…,worktree:{…}}}}
echo "$(jq -r '.data.workspace.label // "?"' <<< "$ev")"
[ "$(jq -r '.data.workspace.worktree.is_linked_worktree // false' <<< "$ev")" = "true" ] || exit 0
path=$(jq -r '.data.workspace.worktree.checkout_path // empty' <<< "$ev")
[ -n "$path" ] && [ -d "$path" ] || exit 0
exec bash "$HERDR_PLUGIN_ROOT/open-remote.sh" launch confirm-remove --env "STU_REMOVE_PATH=$path"
