#!/bin/bash
# Run one git action for the widget and report the result as a notification.
# Stage a file with: action.sh stage-file <repo> <Git-quoted path> [rename source]
# Usage: action.sh commit <repo> <message> | stage|push|pull|lazygit <repo> | fetch <repo>...
export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
action=$1; shift
notify() { omarchy-notification-send --app-name GitHub -g 󰊤 "$@" 2>/dev/null || notify-send -a GitHub "$@"; }

case $action in
  fetch)
    printf '%s\0' "$@" | xargs -0 -P 4 -I{} timeout 60 git -C {} fetch --all --quiet 2>/dev/null
    exit 0 ;;
  lazygit)
    exec omarchy-launch-tui lazygit -p "$1" ;;
esac

repo=$1 name=${1##*/}
case $action in
  stage|stage-file)
    if [[ $action == stage-file ]]; then
      shift
      if (($# == 0 || $# > 2)) || [[ -z $1 || ($# == 2 && -z $2) ]]; then
        exit 2
      fi
      out=$(printf '%s\n' "$@" | timeout 90 git -C "$repo" --literal-pathspecs add --pathspec-from-file=- 2>&1)
      status=$?
    else
      out=$(timeout 90 git -C "$repo" add --all 2>&1)
      status=$?
    fi
    if ((status == 0)); then
      notify "Changes staged"
    else
      title="Stage all failed"
      [[ $action == stage-file ]] && title="Stage file failed"
      notify -u critical "$title" "$(tail -n 4 <<< "$out" | jq -Rs @html -r)"
    fi
    exit "$status" ;;
  commit)
    if [[ ! ${2:-} =~ [^[:space:]] ]]; then
      notify "Commit failed" "Enter a commit message."
      exit 2
    fi
    if git -C "$repo" diff --cached --quiet --; then
      notify "Commit failed" "Stage changes before committing."
      exit 2
    fi
    out=$(timeout 90 git -C "$repo" commit --message "$2" 2>&1)
    status=$?
    if ((status == 0)); then
      notify "Changes committed" "Use Push to sync the commit."
    else
      notify -u critical "Commit failed" "$(tail -n 4 <<< "$out" | jq -Rs @html -r)"
    fi
    exit "$status" ;;
  push)
    if git -C "$repo" rev-parse --abbrev-ref '@{push}' > /dev/null 2>&1; then
      out=$(timeout 90 git -C "$repo" push 2>&1)
    else
      remote=$(git -C "$repo" remote | grep -m1 -x origin || git -C "$repo" remote | head -1)
      # Keep an existing (differently named) upstream; only set one when none exists.
      if git -C "$repo" rev-parse --abbrev-ref '@{u}' > /dev/null 2>&1; then
        out=$(timeout 90 git -C "$repo" push "$remote" HEAD 2>&1)
      else
        out=$(timeout 90 git -C "$repo" push -u "$remote" HEAD 2>&1)
      fi
    fi ;;
  pull) out=$(timeout 90 git -C "$repo" pull --ff-only 2>&1) ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac
status=$?
if ((status == 0)); then
  notify "${action^}ed $name" "$(tail -n 2 <<< "$out")"
else
  notify -u critical "${action^} failed: $name" "$(tail -n 4 <<< "$out")"
fi
exit $status
