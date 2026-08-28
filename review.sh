#!/bin/bash
# Branch review: pick a base, then walk the diff file by file in a tree.
#   pick-base   popup: choose what to diff the focused workspace's branch against
#               (the PR's base first if the branch has an open PR), then open the
#               review pane as a new tab in that workspace.
#   review      the pane: fzf tree of changed files, delta preview, ✓ per file.
#   render | preview | toggle | mode | header | fetch
#               fzf callbacks; they read REVIEW_* from the environment.
# State per (checkout, base, head) under $HERDR_PLUGIN_STATE_DIR/review/: a list
# of "<blob fingerprint> <path>" so a file pushed to again after review shows ↻, not ✓.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
self="$HERDR_PLUGIN_ROOT/review.sh"

die() { printf '\n\033[31m%s\033[0m\n' "$1"; read -rsn1 -p 'press any key'; exit 1; }

# ── review state ──────────────────────────────────────────────────────────────
# REVIEW_WT (checkout), REVIEW_BASE (ref), REVIEW_HEAD (ref), REVIEW_STATE (dir),
# REVIEW_PR (number or empty), REVIEW_TITLE (PR title or empty).
mode() { cat "$REVIEW_STATE/mode" 2>/dev/null || echo committed; }   # committed | worktree
merge_base() { git merge-base "$REVIEW_BASE" "$REVIEW_HEAD"; }
# git diff arguments for the current mode; "worktree" compares the merge base
# to the working tree (staged + unstaged), so unpublished edits are reviewable.
range() { local mb; mb=$(merge_base); if [ "$(mode)" = worktree ]; then echo "$mb"; else echo "$mb $REVIEW_HEAD"; fi; }
# shellcheck disable=SC2046
file_diff() { # $1 path → coloured patch on stdout
  if [ "$(mode)" = worktree ] && [ -n "$(git ls-files --others --exclude-standard -- "$1" 2>/dev/null)" ]; then
    git diff --color=always --no-index -- /dev/null "$1"
  else
    git diff --color=always $(range) -- "$1"
  fi
}

# Every changed file as "<status>\t<path>\t<fingerprint>", one git call. The
# fingerprint is the before/after blob pair, so a file that changes again after
# being ticked shows ↻. Working-tree blobs are hashed on the fly (few files).
entries() {
  # shellcheck disable=SC2046
  git diff --raw --abbrev=40 $(range) | awk -F'\t' '
    { split($1, m, " "); path = (NF > 2) ? $3 : $2      # renames/copies: keep the new path
      src = m[3]; dst = m[4]; st = substr(m[5], 1, 1)
      if (dst ~ /^0+$/) { cmd = "git hash-object -- \"" path "\" 2>/dev/null"; if ((cmd | getline dst) <= 0) dst = "gone"; close(cmd) }
      printf "%s\t%s\t%s%s\n", st, path, src, dst }'
  [ "$(mode)" = worktree ] && git ls-files --others --exclude-standard 2>/dev/null \
    | while read -r path; do printf '?\t%s\t%s\n' "$path" "$(git hash-object -- "$path")"; done
}
# entries joined with the reviewed list: "<status>\t<path>\t<mark>" where mark is
# "ok" (ticked, unchanged), "stale" (ticked, changed since) or "".
marked() {
  entries | awk -F'\t' -v f="$REVIEW_STATE/reviewed" '
    BEGIN { while ((getline l < f) > 0) { i = index(l, " "); seen[substr(l, i+1)] = substr(l, 1, i-1) } }
    { m = ""; if ($2 in seen) m = (seen[$2] == $3) ? "ok" : "stale"; print $1 "\t" $2 "\t" m }'
}
fingerprint() { entries | awk -F'\t' -v p="$1" '$2 == p { print $3; exit }'; }

render() { # tree lines: "<path or empty>\t<display>"
  cd "$REVIEW_WT" || exit 1
  local esc=$'\033' g=$'\033[32m' y=$'\033[33m' r=$'\033[31m' b=$'\033[34m' d=$'\033[2m' z=$'\033[0m'
  marked | sort -t$'\t' -k2 | while IFS=$'\t' read -r st path m; do
    local mark=' '
    case "$m" in ok) mark="${g}✓${z}";; stale) mark="${y}↻${z}";; esac
    case "$st" in A|'?') st="${g}$st${z}";; D) st="${r}D${z}";; R|C) st="${b}$st${z}";; *) st="${y}$st${z}";; esac
    printf '%s\t%s\t%s\n' "$path" "$mark $st" "$path"
  done | awk -F'\t' -v d="$d" -v z="$z" -v esc="$esc" '
    # Emit a directory header the first time a path prefix is seen; files are
    # indented to their depth. Field 1 (hidden) carries the path for callbacks.
    { n = split($3, parts, "/"); prefix = ""
      for (i = 1; i < n; i++) {
        prefix = prefix parts[i] "/"
        if (!(prefix in seen)) { seen[prefix] = 1; printf "%s\t    %s%s%s%s\n", prefix, d, indent(i-1), parts[i] "/", z }
      }
      printf "%s\t%s %s%s\n", $1, $2, indent(n-1), parts[n]
    }
    function indent(k, s) { s = ""; while (k-- > 0) s = s "  "; return s }'
}

preview() { # $1 path or directory prefix or empty
  cd "$REVIEW_WT" || exit 1
  local w="${FZF_PREVIEW_COLUMNS:-120}"
  if [ -z "${1:-}" ] || [[ "$1" == */ ]]; then
    # shellcheck disable=SC2046
    git diff --stat=$((w-2)) --color=always $(range) -- ${1:-.}
    return
  fi
  if command -v delta >/dev/null; then
    file_diff "$1" | delta --paging=never --width="$w"
  else
    file_diff "$1"
  fi
}

toggle() { # $1 path (directory rows and empties are ignored)
  [ -n "${1:-}" ] && [[ "$1" != */ ]] || return 0
  cd "$REVIEW_WT" || exit 1
  local f="$REVIEW_STATE/reviewed"; touch "$f"
  # Lines are "<fingerprint> <path>"; match on the exact path after the first space.
  if awk -v p="$1" '{ i = index($0, " "); if (substr($0, i+1) == p) found = 1 } END { exit !found }' "$f"; then
    awk -v p="$1" '{ i = index($0, " "); if (substr($0, i+1) != p) print }' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  else
    printf '%s %s\n' "$(fingerprint "$1")" "$1" >> "$f"
  fi
}

mark_all() { # $1 = on|off
  cd "$REVIEW_WT" || exit 1
  local f="$REVIEW_STATE/reviewed"; : > "$f"
  [ "$1" = on ] || return 0
  entries | awk -F'\t' '{ print $3, $2 }' > "$f"
}

header() {
  cd "$REVIEW_WT" || exit 1
  local total done_n
  read -r total done_n < <(marked | awk -F'\t' '{ n++ } $3 == "ok" { k++ } END { print n+0, k+0 }')
  local what; if [ "$(mode)" = worktree ]; then what="working tree"; else what="$REVIEW_HEAD"; fi
  local pr=""; [ -n "${REVIEW_PR:-}" ] && pr="  #$REVIEW_PR ${REVIEW_TITLE:-}"
  printf '%s ← %s%s   %s/%s reviewed\n' "$REVIEW_BASE" "$what" "$pr" "$done_n" "$total"
  printf 'enter: ✓ toggle · ctrl-w: %s · ctrl-r: refetch · ctrl-o: edit · ctrl-y: copy path · ctrl-a/x: all/none · ctrl-d/u: scroll diff · esc: close' \
    "$([ "$(mode)" = worktree ] && echo 'review commits' || echo 'include working tree')"
}

# ── entrypoints ───────────────────────────────────────────────────────────────
case "${1:-}" in

render)  render ;;
preview) preview "${2:-}" ;;
toggle)  toggle "${2:-}" ;;
header)  header ;;
mode)    if [ "$(mode)" = worktree ]; then echo committed; else echo worktree; fi > "$REVIEW_STATE/mode" ;;
all)     mark_all on ;;
none)    mark_all off ;;
fetch)   cd "$REVIEW_WT" && case "$REVIEW_BASE" in */*) git fetch -q "${REVIEW_BASE%%/*}" "${REVIEW_BASE#*/}" 2>/dev/null;; esac; render ;;
copy)    printf '%s' "${2:-}" | { command -v pbcopy >/dev/null && pbcopy || xclip -selection clipboard 2>/dev/null || wl-copy 2>/dev/null; } ;;

pick-base)
  command -v fzf >/dev/null || die "fzf is not installed"
  ws=$("$herdr" workspace list | jq -c '.result.workspaces[] | select(.focused)')
  wt=$(jq -r '.worktree.checkout_path // empty' <<< "$ws"); wsid=$(jq -r '.workspace_id' <<< "$ws")
  [ -n "$wt" ] || die "focused workspace is not a git checkout"
  cd "$wt" || die "cannot cd to $wt"
  head=$(git symbolic-ref --short -q HEAD) || die "detached HEAD — check out a branch first"
  echo "fetching origin …"; git fetch --prune -q origin 2>/dev/null

  pr="" title="" prbase=""
  if command -v gh >/dev/null; then
    read -r pr prbase title < <(gh pr view "$head" --json number,baseRefName,title -q '[.number,.baseRefName,.title]|@tsv' 2>/dev/null | tr '\t' ' ') || true
  fi
  default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)

  # Candidates: PR base, origin's default branch, then everything else by recency.
  list=$( {
    [ -n "$prbase" ] && printf 'origin/%s\tPR #%s base\n' "$prbase" "$pr"
    [ -n "$default" ] && [ "$default" != "origin/$prbase" ] && printf '%s\tdefault branch\n' "$default"
    git for-each-ref --sort=-committerdate --format='%(refname:short)%09%(committerdate:relative)' refs/heads refs/remotes/origin \
      | grep -v -E "^(origin/HEAD|$head|origin/$head|origin/$prbase|$default)	"
  } | awk -F'\t' '!seen[$1]++')
  pick=$(printf '%s\n' "$list" | fzf --delimiter=$'\t' --tabstop=2 --layout=reverse --border --ansi \
      --header="$head: review against…  (enter: open review · esc: cancel)" --prompt='base> ' \
      --preview "git log --color --oneline {1}...$head | head -40; echo; git diff --stat --color {1}...$head | tail -1" \
      --preview-window=right,50%,wrap) || exit 0
  base=${pick%%$'\t'*}

  state="$HERDR_PLUGIN_STATE_DIR/review/$(printf '%s|%s|%s' "$wt" "$base" "$head" | shasum | cut -c1-16)"
  mkdir -p "$state"
  out=$("$herdr" plugin pane open --plugin "$HERDR_PLUGIN_ID" --entrypoint review --placement tab --focus \
        --workspace "$wsid" \
        --env REVIEW_WT="$wt" --env REVIEW_BASE="$base" --env REVIEW_HEAD="$head" --env REVIEW_STATE="$state" \
        --env REVIEW_PR="$pr" --env REVIEW_TITLE="$title") || die "could not open review pane: $out"
  pane=$(jq -r '[.. | objects | .pane_id? // empty] | last' <<< "$out")
  [ -n "$pane" ] && "$herdr" pane rename "$pane" "review ${base#origin/}←$head" >/dev/null ;;

review)
  [ -n "${REVIEW_STATE:-}" ] && exec 2>>"$REVIEW_STATE/review.log"   # fzf callback errors land here
  : "${REVIEW_WT:?}" "${REVIEW_BASE:?}" "${REVIEW_HEAD:?}" "${REVIEW_STATE:?}"
  command -v fzf >/dev/null || die "fzf is not installed"
  cd "$REVIEW_WT" || die "cannot cd to $REVIEW_WT"
  export REVIEW_WT REVIEW_BASE REVIEW_HEAD REVIEW_STATE REVIEW_PR REVIEW_TITLE HERDR_PLUGIN_ROOT
  editor="${VISUAL:-${EDITOR:-vi}}"
  "$self" render | fzf --ansi --delimiter=$'\t' --with-nth=2 --nth=1 --tabstop=2 --layout=reverse --no-sort \
      --border --header-first --header="$("$self" header)" --prompt='file> ' \
      --preview "bash '$self' preview {1}" --preview-window=right,65%,wrap \
      --bind "enter:execute-silent(bash '$self' toggle {1})+reload(bash '$self' render)+transform-header(bash '$self' header)+down" \
      --bind "ctrl-w:execute-silent(bash '$self' mode)+reload(bash '$self' render)+transform-header(bash '$self' header)" \
      --bind "ctrl-r:reload(bash '$self' fetch)+transform-header(bash '$self' header)" \
      --bind "ctrl-a:execute-silent(bash '$self' all)+reload(bash '$self' render)+transform-header(bash '$self' header)" \
      --bind "ctrl-x:execute-silent(bash '$self' none)+reload(bash '$self' render)+transform-header(bash '$self' header)" \
      --bind "ctrl-o:execute($editor {1} </dev/tty >/dev/tty)+reload(bash '$self' render)" \
      --bind "ctrl-y:execute-silent(bash '$self' copy {1})" \
      --bind 'ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up' \
      --bind 'esc:abort' >/dev/null
  exit 0 ;;

*) echo "usage: review.sh pick-base | review | render | preview <path> | toggle <path> | header | mode | all | none | fetch | copy <path>" >&2; exit 2 ;;
esac
