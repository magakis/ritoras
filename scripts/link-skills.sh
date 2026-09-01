#!/usr/bin/env bash
# link-skills.sh — share ritoras project skills across git worktrees via symlinks.
#
# .opencode/ is gitignored (local per-checkout), so each linked worktree would
# otherwise have no ritoras skills. This script symlinks the current worktree's
# .opencode/skills to the canonical skills directory in the MAIN worktree, giving
# every worktree the same skill set without git.
#
# Trade-off (accepted): concurrent edits to the same skill by two sessions race
# (last write wins). The main worktree holds the canonical, real files.
#
# Usage:
#   bash scripts/link-skills.sh          # link THIS worktree
#   bash scripts/link-skills.sh --all    # link every worktree (re-links nothing)
#
# Safe to re-run (idempotent). Run from anywhere inside the repo.

set -euo pipefail

# Resolve this script to an absolute path so --all can re-invoke it per worktree.
self_script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Print the main worktree's path (the worktree checked out on branch 'main').
main_worktree() {
  git worktree list --porcelain \
    | awk '/^worktree /{wt=$2} /^branch refs\/heads\/main$/{print wt; exit}'
}

# Link the current worktree's .opencode/skills to the canonical dir.
link_here() {
  local main_wt canonical self_wt self_norm main_norm target
  main_wt="$(main_worktree)"
  if [ -z "$main_wt" ]; then
    echo "error: could not find the 'main' worktree via 'git worktree list'." >&2
    echo "       The main worktree holds the canonical .opencode/skills." >&2
    return 1
  fi
  canonical="$main_wt/.opencode/skills"
  if [ ! -d "$canonical" ]; then
    echo "error: canonical skills dir not found at $canonical" >&2
    echo "       (the main worktree has no .opencode/skills — nothing to share)" >&2
    return 1
  fi

  self_wt="$(git rev-parse --show-toplevel)"
  self_norm="$(cd "$self_wt" && pwd)"
  main_norm="$(cd "$main_wt" && pwd)"

  # Main worktree already holds the real files — nothing to symlink.
  if [ "$self_norm" = "$main_norm" ]; then
    echo "main worktree ($self_norm): skills are canonical here, no symlink needed."
    return 0
  fi

  target="$self_wt/.opencode/skills"
  mkdir -p "$self_wt/.opencode"

  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" = "$canonical" ]; then
      echo "already linked: $target -> $canonical"
      return 0
    fi
    echo "error: $target is a symlink to '$(readlink "$target")', not '$canonical'." >&2
    echo "       Remove it manually if you intend to re-link." >&2
    return 1
  fi

  if [ -e "$target" ]; then
    echo "error: $target exists as a real file/dir (not a symlink)." >&2
    echo "       Refusing to clobber it. Move it aside and re-run." >&2
    return 1
  fi

  ln -s "$canonical" "$target"
  echo "linked: $target -> $canonical"
}

case "${1:-}" in
  --all)
    git worktree list --porcelain | awk '/^worktree /{print $2}' | while IFS= read -r wt; do
      echo "--- $wt ---"
      ( cd "$wt" && bash "$self_script" ) || true
    done
    ;;
  "" )
    link_here
    ;;
  * )
    echo "usage: bash scripts/link-skills.sh [--all]" >&2
    exit 2
    ;;
esac
