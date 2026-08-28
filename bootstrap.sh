#!/bin/bash
# Runs inside the new worktree's pane (cwd = checkout), so asdf/corepack pick
# the project's yarn. Reports progress to the Space row and toasts on finish.
ws="$1"; herdr="${2:-herdr}"
report() { "$herdr" workspace report-metadata "$ws" --source stu-bootstrap --token setup="$1" >/dev/null; }
toast()  { "$herdr" notification show "$1" --body "$(basename "$PWD")" --sound "$2" >/dev/null 2>&1; }
step() {
  local label="$1"; shift
  report "⟳ $label"; printf '\n\033[1;34m▶ %s\033[0m\n' "$label"
  if "$@"; then printf '\033[1;32m✓ %s\033[0m\n' "$label"
  else report "✗ $label failed"; toast "Worktree bootstrap failed: $label" request; exit 1; fi
}
step "yarn install" yarn install
step "yarn build"   yarn build
"$herdr" workspace report-metadata "$ws" --source stu-bootstrap --clear-token setup >/dev/null; toast "Worktree ready" done
