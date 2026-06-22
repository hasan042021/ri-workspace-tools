#!/bin/bash

set -uo pipefail

# Root that holds all the repos (the dir this script lives in)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Colors
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'

# --yes: skip the push confirmation after a clean update (still stops on conflicts)
ASSUME_YES="no"
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES="yes" ;;
    -h|--help)
      echo "Usage: ./update-branch.command [--yes|-y]"
      echo "  For each non-main repo: run 'git pull origin main' to bring the latest main"
      echo "  into your current feature branch, then show exactly what git reported."
      echo "    - clean update  -> offer to push"
      echo "    - conflict/error-> show git's output and STOP so you resolve it inline,"
      echo "                       then re-run this script to continue with the rest."
      echo "  Repos on 'main' and already-up-to-date repos are skipped."
      echo "  --yes, -y   Auto-push after a clean update (no confirmation)."
      exit 0 ;;
    *) echo "Unknown option: $arg (use --yes or -h)"; exit 1 ;;
  esac
done

line() { printf '%s\n' "$(printf '%.0s-' $(seq 1 72))"; }

# Read a line from the real terminal (works under double-click), fall back to stdin.
ask() {  # ask "prompt" -> sets REPLY_VAL
  printf "%b" "$1"
  REPLY_VAL=""
  if [ -t 0 ]; then
    read -r REPLY_VAL || REPLY_VAL=""
  elif { exec 9</dev/tty; } 2>/dev/null; then
    read -r REPLY_VAL <&9 || REPLY_VAL=""
    exec 9<&-
  else
    REPLY_VAL=""; echo
  fi
}

printf "${BLD}Update each feature branch with latest origin/main (one by one)${RST}\n\n"

updated=0; pushed=0; skipped_main=0; uptodate=0; processed=0

for d in */; do
  [ -d "$d/.git" ] || continue
  name="${d%/}"

  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # Skip repos on main entirely (you only update FEATURE branches)
  if [ "$branch" = "main" ]; then
    printf "${DIM}%-26s on main -> skipped${RST}\n" "$name"
    skipped_main=$((skipped_main + 1))
    continue
  fi

  # Make sure we know where origin/main is, and whether we're already current
  git -C "$d" fetch -q origin main 2>/dev/null
  if ! git -C "$d" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf "${YEL}%-26s [%s] no origin/main -> skipped${RST}\n" "$name" "$branch"
    continue
  fi

  behind="$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "$behind" = "0" ]; then
    printf "${GRN}%-26s [%s] already has all of origin/main${RST}\n" "$name" "$branch"
    uptodate=$((uptodate + 1))
    continue
  fi

  # --- This repo needs updating ---
  line
  printf "${BLD}%s${RST} ${DIM}[branch: %s, behind main by %s]${RST}\n" "$name" "$branch" "$behind"
  printf "${CYN}Running: git pull origin main${RST}\n\n"

  # Run the pull and show git's full output verbatim (stdout+stderr).
  pull_out="$(git -C "$d" pull origin main 2>&1)"
  status=$?
  printf "%s\n" "$pull_out" | sed 's/^/   /'
  echo

  if [ "$status" -eq 0 ]; then
    printf "${GRN}Clean update - no conflicts.${RST}\n"
    updated=$((updated + 1)); processed=$((processed + 1))

    # Offer to push (origin/main is now merged into the feature branch)
    do_push="no"
    if [ "$ASSUME_YES" = "yes" ]; then
      do_push="yes"
    else
      ask "${CYN}Push %s now? [y/N]: ${RST}"
      case "$REPLY_VAL" in y|Y|yes|YES) do_push="yes" ;; esac
    fi
    if [ "$do_push" = "yes" ]; then
      printf "${CYN}   pushing %s ...${RST}\n" "$branch"
      if push_out="$(git -C "$d" push 2>&1)"; then
        printf "${GRN}   pushed ✓${RST}\n"; pushed=$((pushed + 1))
      else
        printf "${RED}   push failed:${RST}\n"; printf "%s\n" "$push_out" | sed 's/^/      /'
      fi
    else
      printf "${DIM}   not pushed (do it yourself when ready).${RST}\n"
    fi
  else
    # Pull failed - almost always a merge conflict. Stop so the user fixes it inline.
    echo
    printf "${RED}${BLD}>>> '%s' could not complete the pull (likely a conflict).${RST}\n" "$name"
    printf "${YEL}Git's output is shown above. Resolve it manually in: %s${RST}\n" "$ROOT/$name"
    printf "${YEL}Typical next steps:${RST}\n"
    printf "${DIM}   git -C '%s' status            # see conflicted files${RST}\n" "$name"
    printf "${DIM}   # edit files, remove <<<<<<< ======= >>>>>>> markers${RST}\n"
    printf "${DIM}   git -C '%s' add <files>${RST}\n" "$name"
    printf "${DIM}   git -C '%s' commit           # finish the merge (or: git rebase --continue)${RST}\n" "$name"
    printf "${DIM}   # to bail out entirely: git -C '%s' merge --abort  (or rebase --abort)${RST}\n" "$name"
    echo
    printf "${BLD}Stopping here. Fix '%s', then re-run ./update-branch.command to continue.${RST}\n" "$name"
    echo
    line
    printf "${BLD}Summary (stopped early):${RST} ${GRN}%s updated${RST}, ${GRN}%s pushed${RST}, ${DIM}%s on main, %s up to date${RST}\n" \
      "$updated" "$pushed" "$skipped_main" "$uptodate"
    exit 1
  fi
done

echo
line
printf "${BLD}Summary:${RST} ${GRN}%s updated${RST}, ${GRN}%s pushed${RST}, ${DIM}%s on main skipped${RST}, ${GRN}%s already up to date${RST}\n" \
  "$updated" "$pushed" "$skipped_main" "$uptodate"

# --- colored flag legend (shown every run) ---
echo
printf "${BLD}Flags:${RST}\n"
printf "  ${CYN}%-12s${RST} %s\n" "(no flag)"  "Pull origin/main into each feature branch; offer to push. Stops on first conflict."
printf "  ${YEL}%-12s${RST} %s\n" "--yes, -y"  "Auto-push after a clean update (still stops on conflicts)."
printf "  ${DIM}%-12s${RST} %s\n" "--help, -h" "Show usage."
printf "${DIM}On conflict: resolve inline, finish the merge/rebase, then re-run to continue.${RST}\n"
