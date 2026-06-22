#!/bin/bash

set -uo pipefail

# Root that holds all the repos (the dir this script lives in)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Colors
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'

# This script is already read-only (it never modifies any repo).
# --dry-run / --no-fetch skip the network and show cached results instantly.
NO_FETCH="no"
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n|--no-fetch) NO_FETCH="yes" ;;
    -h|--help)
      echo "Usage: ./check-status.command [--dry-run|--no-fetch|-n]"
      echo "  Read-only. Shows each repo's branch + behind/ahead vs origin/main."
      echo "  --dry-run, --no-fetch, -n   Skip 'git fetch'; use cached refs (offline/instant)."
      exit 0 ;;
    *) echo "Unknown option: $arg (use --dry-run or -h)"; exit 1 ;;
  esac
done

if [ "$NO_FETCH" = "yes" ]; then
  printf "${DIM}Using cached refs (no fetch) - numbers may be stale.${RST}\n\n"
else
  printf "${DIM}Fetching origin/main for each repo...${RST}\n\n"
fi

# Column widths (applied to plain text BEFORE adding color)
W_NAME=28; W_BR=22; W_BH=7; W_AH=6

line() { printf '%s\n' "$(printf '%.0s-' $(seq 1 78))"; }

# Header
printf "${BLD}%-${W_NAME}s %-${W_BR}s %-${W_BH}s %-${W_AH}s %s${RST}\n" \
  "REPO" "BRANCH" "BEHIND" "AHEAD" "STATUS"
line

behind_count=0

for d in */; do
  [ -d "$d/.git" ] || continue
  name="${d%/}"

  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -z "$branch" ] && branch="(detached)"

  # Refresh origin/main quietly (ignore if no network / no remote)
  [ "$NO_FETCH" = "yes" ] || git -C "$d" fetch -q origin main 2>/dev/null

  if ! git -C "$d" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    nm=$(printf "%-${W_NAME}s" "$name")
    br=$(printf "%-${W_BR}s" "$branch")
    bh=$(printf "%-${W_BH}s" "-")
    ah=$(printf "%-${W_AH}s" "-")
    printf "%s ${CYN}%s${RST} %s %s ${DIM}%s${RST}\n" "$nm" "$br" "$bh" "$ah" "no origin/main"
    continue
  fi

  set -- $(git -C "$d" rev-list --left-right --count origin/main...HEAD 2>/dev/null)
  behind="${1:-0}"; ahead="${2:-0}"

  # Pad plain values to column width first, then colorize the whole padded field
  nm=$(printf "%-${W_NAME}s" "$name")
  br=$(printf "%-${W_BR}s" "$branch")
  bh=$(printf "%-${W_BH}s" "$behind")
  ah=$(printf "%-${W_AH}s" "$ahead")

  if [ "$behind" -gt 0 ]; then
    status="${RED}BEHIND${RST}"; bh="${RED}${bh}${RST}"
    behind_count=$((behind_count + 1))
  elif [ "$ahead" -gt 0 ]; then
    status="${YEL}ahead${RST}"
  else
    status="${GRN}up to date${RST}"
  fi
  [ "$ahead" -gt 0 ] && ah="${YEL}${ah}${RST}"

  printf "%s ${CYN}%s${RST} %s %s %b\n" "$nm" "$br" "$bh" "$ah" "$status"
done

line
if [ "$behind_count" -eq 0 ]; then
  printf "${GRN}All repos up to date with origin/main.${RST}\n"
else
  printf "${RED}%d repo(s) behind origin/main.${RST}\n" "$behind_count"
fi

# --- colored flag legend (shown every run) ---
echo
printf "${BLD}Flags:${RST}\n"
printf "  ${CYN}%-22s${RST} %s\n" "(no flag)"             "Fetch origin/main, then report behind/ahead. Live & accurate."
printf "  ${YEL}%-22s${RST} %s\n" "--dry-run, -n"         "Skip fetch; use cached refs. Instant but may be stale."
printf "  ${DIM}%-22s${RST} %s\n" "--no-fetch"            "Same as --dry-run (offline read)."
printf "  ${DIM}%-22s${RST} %s\n" "--help, -h"            "Show usage."
printf "${DIM}This script is read-only - it never modifies any repo.${RST}\n"
