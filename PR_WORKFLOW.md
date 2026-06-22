# Multi-Repo PR Workflow

How we work across the ~13 repos in `ERP_Working`. `main` is **never** pushed to
directly — it only moves when a Pull Request is merged. Everyone works on a
personal feature branch (e.g. `hasan`) and ships through PRs.

This doc covers the day-to-day flow and the helper scripts at the workspace root
that automate the repetitive multi-repo parts.

---

## The golden rules

1. **Never commit or push to `main`.** Main advances only via merged PRs.
2. **Work on your feature branch** (`hasan`, `ATS/hasan`, …) in every repo.
3. **Keep your feature branch updated** with the latest `main` before/while a PR is open.
4. **Resolve conflicts inline, manually** — read what git says, fix the files, finish the merge.

---

## The branch model

```
                    (PRs merge here)
  origin/main   A───B───────────C───────────D            ← shared, PR-only
                     \                        \
  your branch         X───Y───Z                \          ← you: feature branch "hasan"
                                  \   (pull origin main)   \
                                   ────────────────────────► X─Y─Z─merge(D)
                                        update-branches      (now has C, D)
```

- `A,B,C,D` land on `main` through merged PRs (never by you pushing directly).
- `X,Y,Z` are your work on the feature branch.
- `update-branches` pulls `origin/main` into your branch so you have `C,D` too.

---

## The full loop (one cycle)

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │                                                                     │
 │   1. SEE STATE            ./check-status.command                    │
 │      "who's behind/ahead origin/main?"  (read-only)                 │
 │                          │                                          │
 │                          ▼                                          │
 │   2. WRITE CODE          (edit on your feature branch)              │
 │                          │                                          │
 │                          ▼                                          │
 │   3. UPDATE BRANCH       ./update-branches.command                  │
 │      pull origin/main into each feature branch.                     │
 │      ── conflict? ──► resolve INLINE ──► finish merge ──► re-run    │
 │                          │                                          │
 │                          ▼                                          │
 │   4. COMMIT + PUSH       ./push-all.command                         │
 │      show changed files, ask commit msg, push (skips main).         │
 │                          │                                          │
 │                          ▼                                          │
 │   5. OPEN / UPDATE PR     on github.com  ──► review ──► merge        │
 │                          │                                          │
 │                          ▼                                          │
 │   6. MIRROR MAIN          ./sync-main.command                       │
 │      after merges, refresh local main mirrors.                      │
 │                                                                     │
 └─────────────────────────────────────────────────────────────────────┘
```

---

## The scripts

All live at the `ERP_Working` root, are double-clickable (`.command`), auto-discover
every sibling `.git` repo, and print a colored flag legend at the bottom of each run.

| Script | Read/Write | What it does |
|--------|:---------:|--------------|
| `check-status.command`   | read-only | Report each repo's branch + behind/ahead vs `origin/main`. |
| `update-branches.command`| **write** | Pull `origin/main` into each **feature** branch; offer to push. Stops on conflict. |
| `push-all.command`       | **write** | Per repo: show changed files, ask commit message, commit + push. Skips `main`. |
| `sync-main.command`      | **write** | Mirror each repo's local `main` to `origin/main` (checkout + stash/pop). |
| `env-check.command`      | local only| Track `.env` key drift (names only, never values). |

### How "is my branch behind main?" is decided

```bash
git fetch -q origin main                         # refresh origin/main
behind=$(git rev-list --count HEAD..origin/main) # commits on main I don't have
# behind == 0  -> up to date, skip
# behind  > 0  -> pull origin main into this branch
```

`HEAD..origin/main` counts only commits that are on `origin/main` but **not** on your
branch — i.e. "what am I missing from main." It ignores your own feature commits.

---

## When `update-branches` hits a conflict

A conflict happens when a merged PR on `main` touched the **same lines** as your
in-progress work. The script runs `git pull origin main`, shows git's full output,
and **stops** so you fix that repo by hand.

```
   git pull origin main
   ▼
   CONFLICT (content): Merge conflict in src/foo.ts
   ▼
   git -C <repo> status               # list conflicted files
   ▼
   edit files → remove  <<<<<<<  =======  >>>>>>>  markers
   ▼
   git -C <repo> add <files>
   ▼
   git -C <repo> commit               # finish the merge
   │                                  # (or: git rebase --continue)
   ▼
   re-run ./update-branches.command   # continues with the remaining repos
```

To bail out of a bad merge entirely: `git -C <repo> merge --abort`.

---

## Quick reference

```bash
# See what's going on (safe, no changes)
./check-status.command
./check-status.command --dry-run     # offline / instant (cached)

# Bring latest main into your feature branches (stops on conflict)
./update-branches.command
./update-branches.command --yes      # auto-push clean updates

# Commit + push your work (asks message per repo, skips main)
./push-all.command
./push-all.command --yes             # don't ask before pushing already-committed repos

# After PRs merge: refresh local main mirrors
./sync-main.command                  # previews, then asks to confirm
./sync-main.command --dry-run        # preview only
./sync-main.command --yes            # sync without prompt

# Track .env key drift across repos
./env-check.command                  # report added/removed keys
./env-check.command --accept         # bless current keys as baseline
```

---

## Why `sync-main` and `update-branches` are different

- **`sync-main`** keeps your local `main` *branch pointer* matching `origin/main`.
  It physically checks out `main`, pulls, and switches back (stashing your work if
  needed). Useful for keeping the mirror tidy, but you rarely build on local `main`.

- **`update-branches`** keeps your **feature branch** current by pulling `origin/main`
  *into it*. This is the one that matters for PRs — it's what makes your PR
  "up to date with main" and surfaces the conflicts you resolve inline.

In a PR-only workflow, `update-branches` is the script you'll reach for most.
