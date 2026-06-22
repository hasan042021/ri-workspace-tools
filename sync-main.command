#!/bin/bash

set -uo pipefail

# Root that holds all the repos (the dir this script lives in)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Colors
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'
DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'

# Column widths (plain text padding BEFORE color)
W_NAME=28; W_BR=18; W_BH=7; W_AH=6; W_RES=14

# --dry-run: report what WOULD happen, change nothing (only 'git fetch' runs)
# --yes:     skip the confirmation prompt (for scripted / non-interactive use)
DRY_RUN="no"
ASSUME_YES="no"
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN="yes" ;;
    --yes|-y)     ASSUME_YES="yes" ;;
    -h|--help)
      echo "Usage: ./sync-main.command [--dry-run|-n] [--yes|-y]"
      echo "  (no flag)       Preview the sync, then ask for confirmation before changing anything."
      echo "  --dry-run, -n   Show what would happen and exit. Never prompts, never changes."
      echo "  --yes, -y       Skip the confirmation prompt and sync immediately."
      exit 0 ;;
    *) echo "Unknown option: $arg (use --dry-run, --yes, or -h)"; exit 1 ;;
  esac
done

# Decide the run mode:
#   --dry-run         -> one preview pass, no prompt, never changes (PREVIEW stays no, DRY_RUN handles it)
#   --yes             -> straight to the real pass, no prompt
#   (default)         -> a PREVIEW pass first, then prompt, then a real pass on 'y'
PREVIEW="no"
if [ "$DRY_RUN" = "no" ] && [ "$ASSUME_YES" = "no" ]; then
  PREVIEW="yes"          # default: start in preview, gate will flip it after confirm
fi

line() { printf '%s\n' "$(printf '%.0s-' $(seq 1 80))"; }

# Track the repo currently being operated on, so an interrupt can warn about it.
CUR_REPO=""; CUR_STATE=""
on_interrupt() {
  echo
  if [ -n "$CUR_REPO" ]; then
    printf "\n${RED}Interrupted while processing '%s' (%s).${RST}\n" "$CUR_REPO" "$CUR_STATE"
    printf "${YEL}Check it:  git -C '%s' status  &&  git -C '%s' stash list${RST}\n" "$CUR_REPO" "$CUR_REPO"
    printf "${YEL}It may be left on 'main' and/or have changes stashed - recover with:${RST}\n"
    printf "${YEL}  git -C '%s' checkout <your-branch>  &&  git -C '%s' stash pop${RST}\n" "$CUR_REPO" "$CUR_REPO"
  fi
  exit 130
}
trap on_interrupt INT TERM

# Arrays to collect results for the table at the end
names=(); branches=(); behinds=(); aheads=(); results=()

# run_pass: executes one full pass. Behaves as preview when DRY_RUN or PREVIEW is "yes",
# otherwise performs the real sync. Called once or twice by the driver at the bottom.
run_pass() {

if [ "$DRY_RUN" = "yes" ]; then
  printf "${BLD}${YEL}DRY RUN${RST}${BLD} - previewing sync of local main with origin/main (no changes made)${RST}\n\n"
elif [ "$PREVIEW" = "yes" ]; then
  printf "${BLD}${CYN}PREVIEW${RST}${BLD} - what the sync will do (nothing changed yet):${RST}\n\n"
else
  printf "${BLD}Syncing local main with origin/main for each repo...${RST}\n\n"
fi

# Reset accumulators each pass (preview pass and real pass both build the table)
names=(); branches=(); behinds=(); aheads=(); results=()

for d in */; do
  [ -d "$d/.git" ] || continue
  name="${d%/}"

  # 1. Remember the branch we are currently on
  orig_branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # Skip repos with no remote main
  git -C "$d" fetch -q origin main 2>/dev/null
  if ! git -C "$d" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    names+=("$name"); branches+=("$orig_branch"); behinds+=("-"); aheads+=("-")
    results+=("no origin/main")
    printf "${DIM}%-28s skipped (no origin/main)${RST}\n" "$name"
    continue
  fi

  printf "${BLD}== %s ${RST}${DIM}(currently on %s)${RST}\n" "$name" "$orig_branch"

  # ----- DRY RUN / PREVIEW: report only, touch nothing -----
  if [ "$DRY_RUN" = "yes" ] || [ "$PREVIEW" = "yes" ]; then
    dirty="no"
    [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && dirty="yes"

    if git -C "$d" show-ref --verify -q refs/heads/main; then
      # Where local main stands vs origin/main right now
      set -- $(git -C "$d" rev-list --left-right --count origin/main...main 2>/dev/null)
      behind="${1:-?}"; ahead="${2:-?}"
      if [ "$ahead" != "0" ]; then
        result="${RED}would FAIL ff (main ahead by $ahead)${RST}"
      elif [ "$behind" = "0" ]; then
        result="${GRN}already synced${RST}"
      else
        result="${GRN}would ff $behind commit(s)${RST}"
      fi
    else
      behind="-"; ahead="-"
      result="${RED}no local main${RST}"
    fi
    [ "$dirty" = "yes" ] && result="$result ${YEL}(+stash/restore)${RST}"

    names+=("$name"); branches+=("$orig_branch"); behinds+=("$behind"); aheads+=("$ahead")
    results+=("$result")
    continue
  fi
  # ----- end DRY RUN -----

  CUR_REPO="$d"; CUR_STATE="starting"

  # 2. Stash if the working tree is dirty (so we can switch branches safely)
  stashed="no"
  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    printf "   ${YEL}[1] working tree dirty -> git stash push${RST}\n"
    if git -C "$d" stash push -u -q -m "sync-main-autostash" 2>/dev/null; then
      stashed="yes"; CUR_STATE="changes stashed"
      printf "       ${GRN}stashed uncommitted changes${RST}\n"
    else
      # Stash failed: do NOT proceed (checkout could fail or strand changes).
      printf "       ${RED}stash failed - skipping this repo (left untouched on %s)${RST}\n" "$orig_branch"
      names+=("$name"); branches+=("$orig_branch"); behinds+=("?"); aheads+=("?")
      results+=("${RED}skipped (stash failed)${RST}")
      CUR_REPO=""; echo
      continue
    fi
  else
    printf "   ${DIM}[1] working tree clean -> no stash needed${RST}\n"
  fi

  result=""

  # 3. Check out main
  CUR_STATE="${CUR_STATE:+$CUR_STATE, }on main"
  printf "   ${CYN}[2] switching branch: %s -> main${RST}\n" "$orig_branch"
  if git -C "$d" checkout -q main 2>/dev/null; then
    printf "       ${GRN}now on main${RST}\n"
    # 4. Pull (fast-forward only — avoids surprise merge commits)
    printf "   ${CYN}[3] git pull --ff-only origin main${RST}\n"
    if git -C "$d" pull -q --ff-only origin main 2>/dev/null; then
      printf "       ${GRN}main updated${RST}\n"
      result="${GRN}synced${RST}"
    else
      printf "       ${RED}pull failed (main likely ahead / diverged)${RST}\n"
      result="${RED}pull failed${RST}"
    fi
  else
    printf "       ${RED}could not check out main${RST}\n"
    result="${RED}no local main${RST}"
  fi

  # Record behind/ahead of main vs origin/main AFTER the pull
  set -- $(git -C "$d" rev-list --left-right --count origin/main...main 2>/dev/null)
  behind="${1:-?}"; ahead="${2:-?}"

  # 5. Switch back to the branch we started on
  if [ -n "$orig_branch" ] && [ "$orig_branch" != "main" ]; then
    printf "   ${CYN}[4] switching back: main -> %s${RST}\n" "$orig_branch"
    if git -C "$d" checkout -q "$orig_branch" 2>/dev/null; then
      printf "       ${GRN}back on %s${RST}\n" "$orig_branch"
    else
      printf "       ${RED}failed to return to %s (still on main!)${RST}\n" "$orig_branch"
    fi
  else
    printf "   ${DIM}[4] started on main -> no switch back needed${RST}\n"
  fi

  # 6. Restore stashed changes
  if [ "$stashed" = "yes" ]; then
    printf "   ${YEL}[5] git stash pop -> restoring your changes${RST}\n"
    if git -C "$d" stash pop -q 2>/dev/null; then
      printf "       ${GRN}restored stashed changes${RST}\n"
    else
      printf "       ${RED}stash pop conflict! your work is safe in 'git stash list'${RST}\n"
      result="$result ${RED}(stash conflict!)${RST}"
    fi
  fi
  echo

  names+=("$name"); branches+=("$orig_branch"); behinds+=("$behind"); aheads+=("$ahead")
  results+=("$result")
  CUR_REPO=""; CUR_STATE=""   # repo finished cleanly; nothing left mid-operation
done

# ---- Print the summary table ----
echo
printf "${BLD}%-${W_NAME}s %-${W_BR}s %-${W_BH}s %-${W_AH}s %s${RST}\n" \
  "REPO" "WAS ON BRANCH" "BEHIND" "AHEAD" "RESULT"
line

i=0
while [ "$i" -lt "${#names[@]}" ]; do
  nm=$(printf "%-${W_NAME}s" "${names[$i]}")
  br=$(printf "%-${W_BR}s" "${branches[$i]}")
  bh=$(printf "%-${W_BH}s" "${behinds[$i]}")
  ah=$(printf "%-${W_AH}s" "${aheads[$i]}")
  printf "%s ${CYN}%s${RST} %s %s %b\n" "$nm" "$br" "$bh" "$ah" "${results[$i]}"
  i=$((i + 1))
done
line
if [ "$DRY_RUN" = "yes" ]; then
  printf "${DIM}DRY RUN: nothing was changed. BEHIND/AHEAD is local main vs origin/main right now.${RST}\n"
  printf "${DIM}Run without --dry-run to actually sync.${RST}\n"
elif [ "$PREVIEW" = "yes" ]; then
  printf "${DIM}PREVIEW above. BEHIND/AHEAD is local main vs origin/main right now.${RST}\n"
else
  printf "${DIM}Note: BEHIND/AHEAD shown is local main vs origin/main after the sync.${RST}\n"
fi

}   # ----- end run_pass -----

# ===== Driver =====
# 1. Run the first pass (dry-run, preview, or real depending on flags).
run_pass

# 2. If that was a confirmation PREVIEW, ask, and on 'y' run the real pass.
if [ "$PREVIEW" = "yes" ]; then
  echo
  printf "${BLD}${YEL}Proceed with the sync above? [y/N] ${RST}"
  # Read the answer from whichever input is actually a terminal.
  #   - stdin is a tty (normal run / double-click) -> read stdin
  #   - stdin is piped but a controlling tty exists -> read /dev/tty
  #   - no tty at all (CI) -> can't ask; default to "no" (safe)
  reply=""
  if [ -t 0 ]; then
    read -r reply || reply=""
  elif { exec 9</dev/tty; } 2>/dev/null; then
    read -r reply <&9 || reply=""
    exec 9<&-
  else
    printf "\n${DIM}(no terminal to read confirmation; assuming No)${RST}\n"
  fi
  case "$reply" in
    y|Y|yes|YES)
      PREVIEW="no"
      echo
      printf "${BLD}Confirmed - syncing for real...${RST}\n\n"
      run_pass        # real pass
      ;;
    *)
      echo
      printf "${DIM}Aborted - nothing was changed.${RST}\n"
      ;;
  esac
fi

# --- colored flag legend (shown every run) ---
echo
printf "${BLD}Flags:${RST}\n"
printf "  ${YEL}%-16s${RST} %s\n" "(no flag)"      "Preview the sync, then ASK before changing anything."
printf "  ${GRN}%-16s${RST} %s\n" "--dry-run, -n"  "Preview only and exit. Never prompts, never changes."
printf "  ${RED}%-16s${RST} %s\n" "--yes, -y"      "Skip the prompt and sync immediately."
printf "  ${DIM}%-16s${RST} %s\n" "--help, -h"     "Show usage."
printf "${DIM}Dirty repos are auto-stashed and restored. Uses ff-only pull (never merges).${RST}\n"
