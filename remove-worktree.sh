#!/bin/bash
# Popup: delete a worktree checkout — the focused workspace's, or the one named
# by STU_REMOVE_PATH when launched from the workspace.closed hook — forcing past git's
# refusal to remove trees with populated submodules. Shows the dirty state
# first because --force also skips git's dirty-tree check. Never deletes the
# branch. Launched via `open-remote.sh launch confirm-remove [--env STU_REMOVE_PATH=…]`.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
die() { printf '\n\033[31m%s\033[0m\n' "$1"; read -rsn1 -p 'press any key'; exit 1; }

if [ -n "${STU_REMOVE_PATH:-}" ]; then
  # From the workspace.closed hook: the workspace is gone, so work from the path.
  ws=""; path="$STU_REMOVE_PATH"; label="${path##*/} (workspace closed)"
  root=$(dirname "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)") || die "$path is not a git worktree"
else
  ws=$(jq -r '.workspace_id // empty' <<< "${HERDR_PLUGIN_CONTEXT_JSON:-{\}}")
  [ -n "$ws" ] || ws="${HERDR_WORKSPACE_ID:-}"
  [ -n "$ws" ] || die "no focused workspace"
  info=$("$herdr" workspace list | jq -c --arg w "$ws" '.result.workspaces[] | select(.workspace_id==$w)')
  [ "$(jq -r '.worktree.is_linked_worktree // false' <<< "$info")" = "true" ] || die "focused workspace is not a linked worktree"
  path=$(jq -r .worktree.checkout_path <<< "$info"); label=$(jq -r .label <<< "$info"); root=$(jq -r .worktree.repo_root <<< "$info")
fi
branch=$(git -C "$path" branch --show-current 2>/dev/null); [ -n "$branch" ] || branch="(detached)"
dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ab=$(git -C "$path" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null | awk '{printf "↓%s ↑%s", $1, $2}')
submods=$(git -C "$path" config -f "$path/.gitmodules" --get-regexp path 2>/dev/null | wc -l | tr -d ' ')

printf '\033[1mRemove worktree\033[0m  %s\n\n' "$label"
printf '  path     %s\n  branch   %s  %s\n' "$path" "$branch" "${ab:-}"
if [ "$dirty" -gt 0 ]; then printf '  \033[33mdirty    %s uncommitted change(s) — these will be lost\033[0m\n' "$dirty"; else printf '  clean\n'; fi
[ "$submods" -gt 0 ] && printf '  submods  %s (git needs --force to remove these; it will be used)\n' "$submods"
printf '\nThe branch is kept. Delete the checkout? [y/N] '
read -rsn1 ans; echo
[[ "$ans" =~ ^[yY]$ ]] || exit 0
size=$(du -sh "$path" 2>/dev/null | cut -f1)
printf '\n⟳ deleting %s%s …' "$path" "${size:+ ($size)}"
if [ -n "$ws" ]; then "$herdr" worktree remove --workspace "$ws" --force >"$tmp" 2>&1 &
else git -C "$root" worktree remove --force "$path" >"$tmp" 2>&1 &
fi
job=$!; i=0; sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
while kill -0 "$job" 2>/dev/null; do printf '\r⟳ deleting %s%s … %s' "$path" "${size:+ ($size)}" "${sp:i%10:1}"; i=$((i+1)); sleep 0.1; done
if wait "$job"; then printf '\r\033[32m✓ deleted %s%s\033[0m\n' "$path" "${size:+ ($size)}"; sleep 1
else die "remove failed: $(cat "$tmp")"; fi
