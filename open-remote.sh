#!/bin/bash
# Open a remote branch as a Herdr worktree, picked from a popup.
#   launch <pane-id> [pane-open args…]
#                     close whatever popup is up (the command palette, usually —
#                     popups are a singleton), then open the pane named by
#                     <pane-id>; extra args go to `herdr plugin pane open`.
#   pick-pr           popup: fzf over the repo's open GitHub PRs.
#   pick-branch       popup: fzf over every remote branch, newest commit first.
# On pick: fetch the branch, create a local tracking branch if needed, and hand
# the checkout to `herdr worktree create` (or `open` if already checked out).
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
sock="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"

api() { # $1 method, $2 params JSON (default empty object). Newline-delimited JSON over the Unix socket.
  local params="${2:-}"; [ -n "$params" ] || params='{}'
  printf '{"id":"open-remote","method":"%s","params":%s}\n' "$1" "$params" | nc -U -w 2 "$sock" 2>/dev/null
}

repo_root() { # focused workspace's repo, else the first worktree workspace
  "$herdr" workspace list 2>/dev/null | jq -r '
    [.result.workspaces[] | select(.worktree != null)] as $w
    | ($w | map(select(.focused)) + $w)[0].worktree.repo_root // empty'
}

die() { printf '\n\033[31m%s\033[0m\n' "$1"; read -rsn1 -p 'press any key'; exit 1; }

need_repo() {
  command -v fzf >/dev/null || die "fzf is not installed"
  repo=$(repo_root); [ -n "$repo" ] || die "no git workspace is focused"
  cd "$repo" || die "cannot cd to $repo"
}

# checkout <remote> <branch> <label>
checkout() {
  local remote="$1" branch="$2" label="$3"
  echo "fetching $remote/$branch …"
  git fetch "$remote" "$branch" || die "fetch failed"
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch --track "$branch" "$remote/$branch" || die "could not create branch $branch"
  fi
  if git worktree list --porcelain | grep -qx "branch refs/heads/$branch"; then
    "$herdr" worktree open --cwd "$repo" --branch "$branch" --label "$label" --focus >/dev/null || die "herdr worktree open failed"
  else
    "$herdr" worktree create --cwd "$repo" --branch "$branch" --label "$label" --focus >/dev/null || die "herdr worktree create failed"
  fi
}

case "${1:-}" in
launch)
  pane="${2:?pane id}"; shift 2   # remaining args (e.g. --env K=V) pass through to pane open
  api popup.close >/dev/null
  for _ in 1 2 3 4 5 6 7 8; do
    out=$("$herdr" plugin pane open --plugin "$HERDR_PLUGIN_ID" --entrypoint "$pane" --placement popup --focus "$@" 2>&1) && exit 0
    grep -qE 'popup already open|ui_busy' <<< "$out" || { echo "$out" >&2; exit 1; }
    sleep 0.15
  done
  echo "$out" >&2; exit 1 ;;

pick-pr)
  command -v gh >/dev/null || die "gh is not installed"
  need_repo
  list=$(gh pr list --state open --limit 200 \
    --json number,title,author,headRefName,isCrossRepository,headRepositoryOwner,headRepository \
    --jq '.[] | [.number, .title, "@"+.author.login, .headRefName,
                 (if .isCrossRepository then .headRepositoryOwner.login+"/"+.headRepository.name else "" end)] | @tsv') \
    || die "gh pr list failed (are you logged in?)"
  [ -n "$list" ] || die "no open PRs in ${repo##*/}"
  pick=$(printf '%s\n' "$list" | fzf --delimiter=$'\t' --with-nth=1,2,3,4 --tabstop=2 \
      --header="${repo##*/}: open PR as worktree  (enter: open · esc: cancel)" \
      --prompt='PR> ' --layout=reverse --border --ansi \
      --preview 'gh pr view {1} --comments=false 2>/dev/null | head -60' --preview-window=right,55%,wrap) || exit 0
  IFS=$'\t' read -r num _ _ branch fork <<< "$pick"
  remote=origin
  if [ -n "$fork" ]; then
    remote=${fork%%/*}
    if ! git remote get-url "$remote" >/dev/null 2>&1; then
      if git remote get-url origin | grep -q '^git@'; then url="git@github.com:$fork.git"; else url="https://github.com/$fork.git"; fi
      git remote add "$remote" "$url" || die "could not add remote $remote"
    fi
  fi
  checkout "$remote" "$branch" "#$num $branch" ;;

pick-branch)
  need_repo
  echo "fetching origin …"; git fetch --prune -q origin || die "fetch failed"
  list=$(git for-each-ref --sort=-committerdate \
      --format='%(refname:lstrip=3)%09%(committerdate:relative)%09%(authorname)%09%(subject)' refs/remotes/origin \
      | grep -v $'^HEAD\t')
  [ -n "$list" ] || die "no remote branches on origin"
  pick=$(printf '%s\n' "$list" | fzf --delimiter=$'\t' --tabstop=2 \
      --header="${repo##*/}: open remote branch as worktree  (enter: open · esc: cancel)" \
      --prompt='branch> ' --layout=reverse --border --ansi \
      --preview 'git log --color -8 --stat --format="%C(yellow)%h %C(blue)%ar %C(green)%an%C(reset)%n  %s%n" origin/{1}' --preview-window=right,55%,wrap) || exit 0
  IFS=$'\t' read -r branch _ <<< "$pick"
  checkout origin "$branch" "$branch" ;;

*) echo "usage: open-remote.sh launch <pane-id> [pane-open args…] | pick-pr | pick-branch" >&2; exit 2 ;;
esac
