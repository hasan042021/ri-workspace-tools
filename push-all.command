#!/bin/bash

set -uo pipefail

# Root that holds all the repos (the dir this script lives in)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Colors
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'

# --yes: don't prompt before pushing already-committed work (still prompts for commit messages)
ASSUME_YES="no"
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES="yes" ;;
    -h|--help)
      echo "Usage: ./push-all.command [--yes|-y]"
      echo "  For each non-main repo:"
      echo "    - uncommitted changes -> show files, ask for a commit message, then add+commit+push"
      echo "    - clean but ahead of remote -> push"
      echo "  Repos on 'main' are skipped. You're prompted per repo."
      echo "  --yes, -y   Skip the 'push clean ahead repo?' confirmation (still asks for commit messages)."
      exit 0 ;;
    *) echo "Unknown option: $arg (use --yes or -h)"; exit 1 ;;
  esac
done

line() { printf '%s\n' "$(printf '%.0s-' $(seq 1 70))"; }

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
    REPLY_VAL=""   # no terminal: treat as empty / decline
    echo
  fi
}

printf "${BLD}Push changes across repos (skipping 'main')${RST}\n\n"

pushed=0; committed=0; skipped_main=0; skipped_user=0; nothing=0; errors=0

# Track skipped repos and why, to list them at the end.
skipped_names=(); skipped_reasons=()

for d in */; do
  [ -d "$d/.git" ] || continue
  name="${d%/}"

  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # Skip repos on main entirely
  if [ "$branch" = "main" ]; then
    printf "${DIM}%-26s on main -> skipped${RST}\n" "$name"
    skipped_main=$((skipped_main + 1))
    skipped_names+=("$name"); skipped_reasons+=("on main branch")
    continue
  fi

  dirty="$(git -C "$d" status --porcelain 2>/dev/null)"

  # Determine if the branch is ahead of its upstream (commits to push)
  ahead=0
  if git -C "$d" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    ahead="$(git -C "$d" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)"
  fi

  # Case A: nothing to do
  if [ -z "$dirty" ] && [ "$ahead" = "0" ]; then
    printf "${GRN}%-26s [%s] clean & up to date${RST}\n" "$name" "$branch"
    nothing=$((nothing + 1))
    continue
  fi

  line
  printf "${BLD}%s${RST} ${DIM}[branch: %s]${RST}\n" "$name" "$branch"

  # Case B: uncommitted changes -> show files, ask for message, add+commit
  if [ -n "$dirty" ]; then
    printf "${YEL}Uncommitted changes:${RST}\n"
    git -C "$d" status --short | sed 's/^/   /'
    echo
    ask "${CYN}Commit message (empty = skip this repo): ${RST}"
    msg="$REPLY_VAL"
    if [ -z "$msg" ]; then
      printf "${DIM}   skipped (no message given)${RST}\n"
      skipped_user=$((skipped_user + 1))
      skipped_names+=("$name"); skipped_reasons+=("user skipped (no commit message)")
      continue
    fi
    if git -C "$d" add -A && git -C "$d" commit -q -m "$msg"; then
      printf "${GRN}   committed: %s${RST}\n" "$msg"
      committed=$((committed + 1))
    else
      printf "${RED}   commit failed - skipping push${RST}\n"
      errors=$((errors + 1))
      continue
    fi
  else
    # Case C: clean but ahead -> confirm (unless --yes) then push
    printf "${YEL}%s commit(s) ready to push, working tree clean.${RST}\n" "$ahead"
    if [ "$ASSUME_YES" != "yes" ]; then
      ask "${CYN}Push these? [y/N]: ${RST}"
      case "$REPLY_VAL" in
        y|Y|yes|YES) : ;;
        *) printf "${DIM}   skipped${RST}\n"; skipped_user=$((skipped_user + 1))
           skipped_names+=("$name"); skipped_reasons+=("user skipped (declined push)"); continue ;;
      esac
    fi
  fi

  # Push (sets upstream if the branch has none yet)
  printf "${CYN}   pushing %s ...${RST}\n" "$branch"
  if git -C "$d" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    push_out="$(git -C "$d" push 2>&1)"
  else
    push_out="$(git -C "$d" push -u origin "$branch" 2>&1)"
  fi
  if [ "$?" -eq 0 ]; then
    printf "${GRN}   pushed ✓${RST}\n"
    pushed=$((pushed + 1))
  else
    printf "${RED}   push failed:${RST}\n"
    printf "%s\n" "$push_out" | sed 's/^/      /'
    errors=$((errors + 1))
  fi
done

echo
line
printf "${BLD}Summary:${RST} "
printf "${GRN}%s pushed${RST}, ${GRN}%s committed${RST}, ${DIM}%s on main skipped${RST}, " "$pushed" "$committed" "$skipped_main"
printf "${DIM}%s you skipped${RST}, ${GRN}%s already clean${RST}" "$skipped_user" "$nothing"
[ "$errors" -gt 0 ] && printf ", ${RED}%s error(s)${RST}" "$errors"
echo

# --- Skipped repos breakdown (with reason) ---
if [ "${#skipped_names[@]}" -gt 0 ]; then
  echo
  printf "${BLD}Skipped repos:${RST}\n"
  i=0
  while [ "$i" -lt "${#skipped_names[@]}" ]; do
    reason="${skipped_reasons[$i]}"
    case "$reason" in
      *main*) col="$DIM" ;;     # on main branch
      *)      col="$YEL" ;;     # user-skipped
    esac
    printf "  ${col}%-26s${RST} ${DIM}- %s${RST}\n" "${skipped_names[$i]}" "$reason"
    i=$((i + 1))
  done
fi

# --- colored flag legend (shown every run) ---
echo
printf "${BLD}Flags:${RST}\n"
printf "  ${CYN}%-12s${RST} %s\n" "(no flag)"  "Per repo: commit (asks message) and/or push. Asks before each push. Skips 'main'."
printf "  ${YEL}%-12s${RST} %s\n" "--yes, -y"  "Don't ask before pushing already-committed work (still asks for commit messages)."
printf "  ${DIM}%-12s${RST} %s\n" "--help, -h" "Show usage."
