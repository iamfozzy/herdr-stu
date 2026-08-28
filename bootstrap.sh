#!/bin/bash
# Runs inside the new worktree's pane (cwd = checkout), so version managers
# pick the project's toolchain. Sources the per-project script with these
# helpers in scope, reports progress to the Space row, toasts on finish, and
# writes the marker so the checkout is not bootstrapped again.
#
#   step <label> <command…>   run a command, show ✓/✗, abort the bootstrap on failure
#   copy_from_root <path…>    copy files from the source repo unless already present
#   $REPO_ROOT $WORKTREE $WORKSPACE_ID
ws="$1"; REPO_ROOT="$2"; project="$3"; marker="$4"; herdr="${5:-herdr}"
WORKTREE="$PWD"; WORKSPACE_ID="$ws"
report() { "$herdr" workspace report-metadata "$ws" --source stu-bootstrap --token setup="$1" >/dev/null; }
toast()  { "$herdr" notification show "$1" --body "$(basename "$PWD")" --sound "$2" >/dev/null 2>&1; }
# Any exit before `finished` is set — Ctrl+C, kill, pane closed — leaves the
# sidebar honest instead of stuck on "⟳ <step>".
current=""; finished=""
on_exit() { [ -n "$finished" ] || { report "✗ ${current:-bootstrap} interrupted"; toast "Worktree bootstrap interrupted" request; }; }
trap on_exit EXIT; trap 'exit 130' INT TERM HUP
step() {
  local label="$1"; shift; current="$label"
  report "⟳ $label"; printf '\n\033[1;34m▶ %s\033[0m\n' "$label"
  if "$@"; then printf '\033[1;32m✓ %s\033[0m\n' "$label"; return; fi
  local rc=$? why=failed; [ "$rc" -ge 128 ] && why=interrupted   # killed by a signal (Ctrl+C = 130)
  finished=1; report "✗ $label $why"; toast "Worktree bootstrap $why: $label" request; exit "$rc"
}
copy_from_root() {
  local f
  for f in "$@"; do
    if [ -e "$REPO_ROOT/$f" ] && [ ! -e "$WORKTREE/$f" ]; then
      mkdir -p "$(dirname "$WORKTREE/$f")" && cp -R "$REPO_ROOT/$f" "$WORKTREE/$f" && printf '\033[1;32m✓ copied %s\033[0m\n' "$f" \
        || { report "✗ copy $f failed"; exit 1; }
    fi
  done
}
# shellcheck source=/dev/null
source "$project"
mkdir -p "$(dirname "$marker")" && : > "$marker"
finished=1
"$herdr" workspace report-metadata "$ws" --source stu-bootstrap --clear-token setup >/dev/null; toast "Worktree ready" done
