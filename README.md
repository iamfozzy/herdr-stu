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

### Bootstrap new worktrees

On `worktree.created` (however the worktree was made): copy `.env` from the
source repo if the checkout has none, then — for yarn projects — open a pane in
the new workspace running `yarn install && yarn build` so the output is
visible. Progress shows on the space's sidebar row via the `$setup` token and a
toast fires when it finishes or fails.

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

To change the keys, add `[[keys.command]]` entries to `config.toml` pointing at
`stu.open-pr` and `stu.open-branch`.

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
| `on-worktree-created.sh` | `worktree.created` hook: `.env` copy, opens the bootstrap pane |
| `bootstrap.sh` | runs inside the new worktree: `yarn install && yarn build` |
| `open-remote.sh` | the two pickers and the shared checkout routine |

## Decisions

- **Separate `$pr_pass` / `$pr_fail` / `$pr_pending` tokens, not one `$pr`.**
  Herdr styles a token with a single foreground colour, so one token could not
  be green, red, or yellow by state. Setting exactly one of three gets the
  colour for free from config.
- **Own poller rather than events only.** Herdr has no event for "the working
  tree changed" or "a process started listening", so a short poll is the only
  way to keep `$git_dirty` and `$run` honest.
- **Close the palette, don't fail.** Popups are a singleton; an action launched
  from the command palette would otherwise always fail with "popup already
  open". Closing it via `popup.close` and retrying briefly is the only path that
  works from the palette, the bar, and a keybind alike.

## Licence

MIT
