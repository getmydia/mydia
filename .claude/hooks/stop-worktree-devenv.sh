#!/usr/bin/env bash
# SessionEnd hook: stop this worktree's devenv processes when a Claude session
# in a .claude/worktrees/ checkout ends.
#
# Agent worktrees each start their own Phoenix server and Flutter build_runner
# watcher (~1.5 GB apiece), and nothing ever stopped them, so they piled up
# until the machine swapped itself into the ground. The main checkout is left
# alone: a session ending there says nothing about whether you are done with it.
#
# Claude Code gives SessionEnd hooks only a short timeout, and `devenv processes
# down` has to evaluate the devenv first, so it is detached with setsid rather
# than awaited. Anything this misses (crashed sessions, deleted worktrees) is
# swept by the devenv-reaper timer on raider.
set -u

input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<< "$input")"
reason="$(jq -r '.reason // empty' <<< "$input")"

# /clear ends the session but the work carries on in the same worktree.
[ "$reason" = "clear" ] && exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
case "$root" in
    */.claude/worktrees/*) ;;
    *) exit 0 ;;
esac
[ -d "$root/.devenv" ] || exit 0

cd "$root" && setsid -f devenv processes down >/dev/null 2>&1 < /dev/null
exit 0
