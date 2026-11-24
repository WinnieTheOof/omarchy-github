# GitHub for Omarchy

An [Omarchy](https://omarchy.org) bar widget that shows your local repos and your GitHub account at a glance.

## In the bar

- `↑n`: commits not yet pushed, `↓n`: commits not yet pulled, across all scanned repos.
- The icon turns **red** when CI fails on a tracked branch and **yellow** when there are unpushed commits.
- Optionally shows the count of unread GitHub notifications.

## Panel

Click the icon, or run `omarchy-shell mulm.github toggle`.

- **Repos**: the most recently committed ones. Repos with unpushed or unpulled commits are always listed.
  - Each shows its recent commit history and CI state. Expand a repo to review changed files, click **Stage** beside a file or **Stage all**, and commit the staged changes.
  - Actions: **push**, **pull** (`--ff-only`), **fetch**, open in **lazygit**. Results arrive as notifications.
- **Pull requests**: your open PRs and PRs waiting for your review.
- **Notifications** and your **contribution graph**.

## Requirements

- Omarchy with shell plugins (Quickshell bar)
- `git`, `jq`
- [GitHub CLI](https://cli.github.com) `gh`, logged in (`gh auth login`), for the GitHub data. Local repo state works without it.
- `lazygit` for the lazygit action (Omarchy ships it)

## Install

```bash
omarchy plugin add https://github.com/mulmlord/omarchy-github.git --enable
```

Update with `omarchy plugin update mulm.github`.

## Remove

```bash
omarchy plugin remove mulm.github
```

This removes the widget from the bar and deletes its folder. The widget stores nothing anywhere else.

## Settings

| Setting | Default | |
|---|---|---|
| Repo folders | `~/Projects` | Comma-separated. Each folder and its direct subfolders are scanned for git repos |
| Repos listed | 8 | |
| Local refresh | 10 s | Local git scan only, no network, no locks taken |
| GitHub refresh | 180 s | One `gh api graphql` call + notifications |
| Background git fetch | 15 min | `0` turns it off |
| Notification count in bar | off | |

## Network

- **GitHub**: one GraphQL request through `gh` every refresh, plus the notifications request.
- **Your remotes**: optional background `git fetch` with the interval above.

Nothing else leaves your machine.

## License

MIT
