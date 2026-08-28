# stu — worktree tooling for Herdr

A [Herdr](https://herdr.dev) plugin that makes Git worktrees the unit of work:
open any PR or remote branch as a worktree from a popup, get it bootstrapped
automatically, and see each space's git, PR/CI, and running-app state in the
sidebar.

```
▶ my-app
  master · ↑1 · ~2 ?2 · ▶ :5173
  ├ feat/schema-ai
  │ feat/schema-ai · #1822 ● · ~7
  └ fix/mini-schema
    fix/mini-schema · #1820 ✗
```

## What it does

### Open a PR or remote branch as a worktree

| action | default key | what you pick from |
|---|---|---|
| **Open PR as worktree** | `prefix+shift+o` | the repo's open GitHub PRs, with `gh pr view` preview |
| **Open remote branch as worktree** | `prefix+shift+b` | every `origin/*` branch, newest commit first, with `git log --stat` preview |

Both are fzf popups. On Enter the plugin fetches the branch, creates a local
tracking branch if there isn't one, and calls `herdr worktree create` — or
`herdr worktree open` if that branch is already checked out somewhere. PRs from
forks get their remote added automatically. Both actions also appear in the
command palette and herdr-bar; the plugin closes the palette before opening its
own popup, since Herdr allows one popup at a time.

### Remove a worktree — including ones with submodules

Git refuses `git worktree remove` on a checkout with populated submodules
("working trees containing submodules cannot be moved or removed"), and Herdr's
built-in remove inherits that. Two ways round it, both through the same confirm
popup — path, branch, ahead/behind, uncommitted-change count, then `y` to
delete. The branch is always kept.

- **Close the workspace** (right-click → close, or `prefix+shift+d`). Herdr
  leaves the checkout on disk; the plugin notices a worktree workspace closed
  and asks whether to delete the checkout too. Anything but `y` keeps it.
- **Remove worktree** in the command palette does the same for the focused
  workspace without closing it first. No default key since it's destructive.

### Bootstrap new worktrees — per project

When a worktree is created or opened for the first time, the plugin runs that
repo's bootstrap script in a visible pane inside the new workspace. Progress
shows on the space's sidebar row via the `$setup` token and a toast fires when
it finishes or fails. Each checkout is bootstrapped once; reopening it later is
a no-op.

Scripts live in the plugin's config dir, one per repo, named after the repo's
root checkout directory:

```bash
mkdir -p "$(herdr plugin config-dir stu)/projects"
cp examples/yarn-project.sh "$(herdr plugin config-dir stu)/projects/my-app.sh"   # for ~/Dev/my-app
```

A script is plain bash, sourced inside the new worktree (so `asdf`/`corepack`
pick the project's toolchain) with two helpers in scope:

```bash
copy_from_root .env .env.local      # copy from the source repo unless the worktree already has them
step "yarn install" yarn install    # run a command; ✓/✗ in the pane, progress on the sidebar, abort on failure
step "yarn build"   yarn build
```

`$REPO_ROOT`, `$WORKTREE`, and `$WORKSPACE_ID` are also set. Repos without a
script are left alone.

### Sidebar tokens for every space

Reported per workspace (worktrees included) so you can place and colour them in
`[ui.sidebar.spaces]`:

| token | shows | example |
|---|---|---|
| `$git_dirty` | staged / modified / untracked counts | `+1 ~2 ?3` |
| `$git_conflict` | unmerged paths | `!2` |
| `$pr_pass` `$pr_fail` `$pr_pending` | open PR number + CI rollup; exactly one is set | `#1822 ✓` `#1820 ✗` `#1821 ●` |
| `$run` | listening ports, or a dev-server-looking foreground command | `▶ :5173` `▶ yarn dev` |
| `$setup` | bootstrap progress | `⟳ yarn install` |

Tokens disappear when there's nothing to say (clean tree, no open PR, nothing
running). Herdr's built-in `branch` and `git_status` (ahead/behind) tokens
cover the rest. A CI failure outranks pending checks, since a failed check
already decides the outcome.

## Install

```bash
herdr plugin install iamfozzy/herdr-stu
herdr server reload-config
```

Or for hacking on it: `git clone` this repo, then `herdr plugin link "$PWD"`.

**Dependencies:** `git`, `jq`, `fzf`, `gh` (logged in — only needed for PR
features), plus `nc` and `lsof`, which ship with macOS and most Linux distros.

## Configure the sidebar

The plugin only reports values; layout and colour live in your `config.toml`.
A layout that uses everything:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  ["branch", "git_status",
   { token = "$pr_pass",      fg = "#9ece6a" },
   { token = "$pr_fail",      fg = "#f7768e" },
   { token = "$pr_pending",   fg = "#e0af68" },
   { token = "$git_conflict", fg = "#f7768e" },
   { token = "$git_dirty",    fg = "#e0af68" }],
  [{ token = "$setup", fg = "#e0af68" }, { token = "$run", fg = "#9ece6a" }],
]
```

To change the keys — or bind the remove action — add `[[keys.command]]` entries
to `config.toml` pointing at `stu.open-pr`, `stu.open-branch`, or
`stu.remove-worktree`.

## How it works

One background poller (started by the plugin's `startup` hook, one per Herdr
server, exits with it) rescans every workspace every 3 seconds; pane events
trigger an immediate rescan of the affected workspace. Per tick and workspace
that's one `git status --porcelain` plus the pane process scan — a few tens of
milliseconds on a repo of ~5k files.

PR status is the only network call. It runs in the background, at most once
per 60 seconds per workspace, or immediately when the branch changes — about
60 GitHub API calls per hour per open workspace against a 5,000/hour limit.

## Files

| file | role |
|---|---|
| `herdr-plugin.toml` | manifest: hooks, popup panes, actions, default keys |
| `on-pane-changed.sh` | startup hook + poller: `$run`, `$git_*`, `$pr_*` tokens |
| `on-worktree.sh` | `worktree.created` / `worktree.opened` hook: opens the bootstrap pane once per checkout |
| `bootstrap.sh` | runs inside the new worktree: helpers + sources the project script |
| `examples/yarn-project.sh` | a project script for a yarn repo: `.env` copy, install, build |
| `open-remote.sh` | the two pickers, the shared checkout routine, and the popup launcher |
| `on-workspace-closed.sh` | `workspace.closed` hook: offers to delete a closed worktree's checkout |
| `remove-worktree.sh` | confirm-and-delete popup, for the focused workspace or a just-closed one |

## Decisions

- **Separate `$pr_pass` / `$pr_fail` / `$pr_pending` tokens, not one `$pr`.**
  Herdr styles a token with a single foreground colour, so one token could not
  be green, red, or yellow by state. Setting exactly one of three gets the
  colour for free from config.
- **Own poller rather than events only.** Herdr has no event for "the working
  tree changed" or "a process started listening", so a short poll is the only
  way to keep `$git_dirty` and `$run` honest.
- **Bootstrap on `worktree.opened` too, guarded by a marker.** Opening a PR
  whose branch is already checked out somewhere emits `opened`, not `created`;
  without this the first open of that checkout would never bootstrap. The marker
  stops every later open from reinstalling.
- **Ask on close, never delete silently.** Herdr's `workspace close` keeps the
  checkout on purpose and people close workspaces just to tidy up, so the hook
  only ever asks, defaulting to keep.
- **`--force` for removal, after showing the dirty count.** The submodule check
  lives inside git's clean-tree check, so `--force` is the only way past it — but
  it also skips the dirty-tree refusal, which is why the popup shows uncommitted
  changes before asking.
- **Close the palette, don't fail.** Popups are a singleton; an action launched
  from the command palette would otherwise always fail with "popup already
  open". Closing it via `popup.close` and retrying briefly is the only path that
  works from the palette, the bar, and a keybind alike.

## Licence

MIT
