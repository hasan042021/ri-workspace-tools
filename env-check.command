#!/bin/bash

set -uo pipefail

# Root that holds all the repos (the dir this script lives in)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Where we store the baseline of known env KEYS (names only, never values).
SNAP_DIR="$ROOT/.env-keys"
mkdir -p "$SNAP_DIR"

# Colors
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'

# --- options ---
ACCEPT="no"   # --accept:  update the baseline to match current .env (acknowledge changes)
REJECT="no"   # --reject:  edit .env to remove ADDED keys (back to baseline); backs up first
RESTORE="no"  # --restore: put each repo's .env.bak back into place (undo a --reject)
for arg in "$@"; do
  case "$arg" in
    --accept|-a) ACCEPT="yes" ;;
    --reject|-r) REJECT="yes" ;;
    --restore)   RESTORE="yes" ;;
    -h|--help)
      echo "Usage: ./env-check.command [--accept|-a | --reject|-r | --restore]"
      echo "  Detects added/removed env KEYS in each repo's .env vs a saved baseline."
      echo "  Stores only key NAMES (never values) in .env-keys/ at the workspace root."
      echo "  --accept, -a   Update the baseline to current keys (bless the changes)."
      echo "  --reject, -r   Remove ADDED keys from .env (revert to baseline). Backs up to .env.bak."
      echo "  --restore      Restore each repo's .env from its .env.bak (undo a --reject)."
      exit 0 ;;
    *) echo "Unknown option: $arg (use --accept, --reject, --restore, or -h)"; exit 1 ;;
  esac
done

# Mutually-exclusive write actions
picked=0
[ "$ACCEPT" = "yes" ]  && picked=$((picked + 1))
[ "$REJECT" = "yes" ]  && picked=$((picked + 1))
[ "$RESTORE" = "yes" ] && picked=$((picked + 1))
if [ "$picked" -gt 1 ]; then
  echo "Error: --accept, --reject and --restore are mutually exclusive; use only one." >&2
  exit 1
fi

# Extract just the KEY names from a .env file: lines like FOO=... -> FOO
# Ignores blank lines, comments, and anything without a key=value shape.
extract_keys() {
  grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\1/' \
    | sort -u
}

# --- --restore: swap each repo's .env.bak back into .env, then exit ---
if [ "$RESTORE" = "yes" ]; then
  printf "${BLD}Restoring .env from .env.bak in each repo${RST}\n\n"
  restored=0; nobak=0
  for d in */; do
    [ -d "$d/.git" ] || continue
    name="${d%/}"
    if [ -f "$d/.env.bak" ]; then
      cp "$d/.env.bak" "$d/.env"
      rm -f "$d/.env.bak"          # consume the backup once restored
      printf "${GRN}%-26s restored from .env.bak (backup removed)${RST}\n" "$name"
      restored=$((restored + 1))
    else
      printf "${DIM}%-26s no .env.bak${RST}\n" "$name"
      nobak=$((nobak + 1))
    fi
  done
  echo
  printf '%s\n' "$(printf '%.0s-' $(seq 1 60))"
  if [ "$restored" -eq 0 ]; then
    printf "${YEL}Nothing to restore (no .env.bak files found).${RST}\n"
  else
    printf "${GRN}Restored %s repo(s) from backup.${RST}\n" "$restored"
    printf "${DIM}Run with no flag to re-check drift.${RST}\n"
  fi
  exit 0
fi

printf "${BLD}Env-key drift check across repos${RST}"
[ "$ACCEPT" = "yes" ] && printf " ${YEL}(--accept: updating baseline)${RST}"
[ "$REJECT" = "yes" ] && printf " ${RED}(--reject: removing added keys from .env, backups -> .env.bak)${RST}"
echo; echo

total_added=0; total_removed=0; total_new_files=0; changed_repos=0

for d in */; do
  [ -d "$d/.git" ] || continue
  name="${d%/}"
  envfile="$d/.env"
  snap="$SNAP_DIR/$name.keys"

  if [ ! -f "$envfile" ]; then
    printf "${DIM}%-26s no .env${RST}\n" "$name"
    continue
  fi

  current="$(extract_keys "$envfile")"

  # First time we've seen this repo: record baseline, report as new.
  if [ ! -f "$snap" ]; then
    printf "$current\n" > "$snap"
    n=$(printf "%s\n" "$current" | grep -c . )
    printf "${CYN}%-26s baseline created (%s keys tracked)${RST}\n" "$name" "$n"
    total_new_files=$((total_new_files + 1))
    continue
  fi

  baseline="$(cat "$snap")"

  # Diff key sets
  added="$(comm -13 <(printf "%s\n" "$baseline") <(printf "%s\n" "$current"))"
  removed="$(comm -23 <(printf "%s\n" "$baseline") <(printf "%s\n" "$current"))"

  if [ -z "$added" ] && [ -z "$removed" ]; then
    printf "${GRN}%-26s OK (no key changes)${RST}\n" "$name"
  else
    changed_repos=$((changed_repos + 1))
    printf "${YEL}%-26s CHANGED${RST}\n" "$name"
    if [ -n "$added" ]; then
      while IFS= read -r k; do
        [ -n "$k" ] && { printf "   ${GRN}+ added   %s${RST}\n" "$k"; total_added=$((total_added + 1)); }
      done <<< "$added"
    fi
    if [ -n "$removed" ]; then
      while IFS= read -r k; do
        [ -n "$k" ] && { printf "   ${RED}- removed %s${RST}\n" "$k"; total_removed=$((total_removed + 1)); }
      done <<< "$removed"
    fi

    # --accept: bless current state by updating the baseline.
    if [ "$ACCEPT" = "yes" ]; then
      printf "%s\n" "$current" > "$snap"
    fi

    # --reject: strip the ADDED keys' lines from the real .env (revert toward baseline).
    # Only touches ADDED keys; never re-adds removed keys (can't recover their values).
    if [ "$REJECT" = "yes" ] && [ -n "$added" ]; then
      cp "$envfile" "$envfile.bak"          # safety backup before editing
      while IFS= read -r k; do
        [ -z "$k" ] && continue
        # Delete lines whose key (allowing leading space) is exactly this added key.
        sed -i '' -E "/^[[:space:]]*${k}[[:space:]]*=/d" "$envfile"
        printf "   ${RED}-> reverted: removed line for %s from .env${RST}\n" "$k"
      done <<< "$added"
      printf "   ${DIM}(backup saved: %s.bak)${RST}\n" "$envfile"
      if [ -n "$removed" ]; then
        printf "   ${YEL}note: %s key(s) were 'removed' from .env - --reject cannot restore those (values unknown)${RST}\n" \
          "$(printf "%s\n" "$removed" | grep -c .)"
      fi
    fi
  fi
done

echo
printf '%s\n' "$(printf '%.0s-' $(seq 1 60))"
if [ "$total_new_files" -gt 0 ]; then
  printf "${CYN}%s repo(s) had a baseline created this run.${RST}\n" "$total_new_files"
fi
if [ "$changed_repos" -eq 0 ]; then
  printf "${GRN}No env-key drift detected.${RST}\n"
else
  printf "${YEL}%s repo(s) drifted: ${GRN}%s added${RST}${YEL}, ${RED}%s removed${RST}${YEL}.${RST}\n" \
    "$changed_repos" "$total_added" "$total_removed"
  if [ "$ACCEPT" = "yes" ]; then
    printf "${DIM}Baseline updated to current keys.${RST}\n"
  elif [ "$REJECT" = "yes" ]; then
    printf "${DIM}Added keys removed from .env (backups in each repo's .env.bak).${RST}\n"
  else
    printf "${DIM}Review the changes above, then choose a flag below.${RST}\n"
  fi
fi

# --- colored flag legend (shown every run) ---
echo
printf "${BLD}Flags:${RST}\n"
printf "  ${CYN}%-16s${RST} %s\n" "(no flag)"      "Check & report drift only. Changes nothing."
printf "  ${GRN}%-16s${RST} %s\n" "--accept, -a"   "Bless current .env: update baseline so changes stop alerting."
printf "  ${RED}%-16s${RST} %s\n" "--reject, -r"   "Undo added keys: delete them from .env (backs up to .env.bak)."
printf "  ${YEL}%-16s${RST} %s\n" "--restore"      "Put each repo's .env.bak back (undo a --reject)."
printf "  ${DIM}%-16s${RST} %s\n" "--help, -h"     "Show usage."
printf "${DIM}Tip: always run with no flag first and read the +/- lines before --accept or --reject.${RST}\n"
