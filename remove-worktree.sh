#!/bin/bash
# Popup: delete a worktree checkout — the focused workspace's, or the one named
# by STU_REMOVE_PATH when launched from the workspace.closed hook — forcing past git's
# refusal on populated submodules. After `y` the deletion runs detached and a toast
# reports the outcome, so the popup closes immediately.
# refusal to remove trees with populated submodules. Shows the dirty state
# first because --force also skips git's dirty-tree check. Never deletes the
# branch. Launched via `open-remote.sh launch confirm-remove [--env STU_REMOVE_PATH=…]`.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
die() { printf '\n\033[31m%s\033[0m\n' "$1"; read -rsn1 -p 'press any key'; exit 1; }

if [ "${1:-}" = "do-remove" ]; then
  ws="$2"; root="$3"; path="$4"; name="${path##*/}"
  if [ -n "$ws" ]; then out=$("$herdr" worktree remove --workspace "$ws" --force 2>&1); rc=$?
  else out=$(git -C "$root" worktree remove --force "$path" 2>&1); rc=$?; fi
  if [ "$rc" -eq 0 ]; then "$herdr" notification show "Worktree deleted" --body "$name" --sound done >/dev/null 2>&1
  else "$herdr" notification show "Worktree delete failed" --body "$name: ${out:0:200}" --sound request >/dev/null 2>&1; fi
  exit 0
fi

if [ -n "${STU_REMOVE_PATH:-}" ]; then
  # From the workspace.closed hook: the workspace is gone, so work from the path.
  ws=""; path="$STU_REMOVE_PATH"; label="${path##*/} (workspace closed)"
  root=$(dirname "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)") || die "$path is not a git worktree"
else
  ws=$(jq -r '.workspace_id // empty' <<< "${HERDR_PLUGIN_CONTEXT_JSON:-null}")
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
# Detach the deletion so the popup closes at once; a toast reports the outcome.
nohup bash "$0" do-remove "$ws" "$root" "$path" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
printf '⟳ deleting %s in the background — you will get a notification when it is done\n' "${path##*/}"
sleep 1.2
