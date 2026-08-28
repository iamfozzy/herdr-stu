#!/bin/bash
# Popup: remove the focused workspace's worktree checkout, forcing past git's
# refusal to remove trees with populated submodules. Shows the dirty state
# first because --force also skips git's dirty-tree check. Never deletes the
# branch. Launched via `open-remote.sh launch confirm-remove`.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
die() { printf '\n\033[31m%s\033[0m\n' "$1"; read -rsn1 -p 'press any key'; exit 1; }

ws=$(jq -r '.workspace_id // empty' <<< "${HERDR_PLUGIN_CONTEXT_JSON:-{\}}")
[ -n "$ws" ] || ws="${HERDR_WORKSPACE_ID:-}"
[ -n "$ws" ] || die "no focused workspace"
info=$("$herdr" workspace list | jq -c --arg w "$ws" '.result.workspaces[] | select(.workspace_id==$w)')
[ "$(jq -r '.worktree.is_linked_worktree // false' <<< "$info")" = "true" ] || die "focused workspace is not a linked worktree"
path=$(jq -r .worktree.checkout_path <<< "$info"); label=$(jq -r .label <<< "$info")
branch=$(git -C "$path" branch --show-current 2>/dev/null); [ -n "$branch" ] || branch="(detached)"
dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ab=$(git -C "$path" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null | awk '{printf "↓%s ↑%s", $1, $2}')
submods=$(git -C "$path" config -f "$path/.gitmodules" --get-regexp path 2>/dev/null | wc -l | tr -d ' ')

printf '\033[1mRemove worktree\033[0m  %s\n\n' "$label"
printf '  path     %s\n  branch   %s  %s\n' "$path" "$branch" "${ab:-}"
if [ "$dirty" -gt 0 ]; then printf '  \033[33mdirty    %s uncommitted change(s) — these will be lost\033[0m\n' "$dirty"; else printf '  clean\n'; fi
[ "$submods" -gt 0 ] && printf '  submods  %s (git needs --force to remove these; it will be used)\n' "$submods"
printf '\nThe branch is kept. Remove the checkout? [y/N] '
read -rsn1 ans; echo
[[ "$ans" =~ ^[yY]$ ]] || exit 0
out=$("$herdr" worktree remove --workspace "$ws" --force 2>&1) || die "herdr worktree remove failed: $out"
