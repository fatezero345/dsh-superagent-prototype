#!/bin/sh
# prepare.sh - dsh-superagent "prepare" step for the Windows / Git Bash executor.
#
# Invoked once per ticket as:
#     sh /c/Users/fixadmin/src/dsh-superagent-prototype/prepare.sh
# with cwd = the execution root, a 10 minute budget, and these variables:
#     DSH_SUPERAGENT_DIR                 ticket directory (C:/..., C:\..., or /c/...)
#     DSH_SUPERAGENT_NAME                ticket short name
#     DSH_SUPERAGENT_TICKET              ticket id
#     DSH_SUPERAGENT_GITHUB_REPOSITORY   owner/repo
#     DSH_SUPERAGENT_GITHUB_PR_HEAD      optional ref/branch to base the work on
#
# It creates $DSH_SUPERAGENT_DIR as a git worktree of the base clone, on branch
# agent/$DSH_SUPERAGENT_NAME, based on the fetched ticket ref, or on the clone
# default branch when there is no PR head, no network, or no such ref.
#
# Contract:
#   * tracked files in the base clone are never modified; nothing is committed
#     or pushed. A fetch only writes refs/dsh-superagent/<ticket>.
#   * idempotent: a retry over an existing worktree, an existing agent/<name>
#     branch, or an empty leftover directory still succeeds.
#   * exit 0 means the ticket directory is ready; a non-zero exit is a real,
#     unfixable error and says why.
set -u

BASE='C:/Users/fixadmin/src/dsh-superagent-prototype'

log()  { printf 'prepare: %s\n' "$*" >&2; }
fail() { printf 'prepare: ERROR: %s\n' "$*" >&2; exit 1; }

# --- environment -------------------------------------------------------------

fix_tmpdir() {
  # MSYS bash warns "could not find /tmp, please create!" when /tmp is absent,
  # which leaves git without a scratch dir for its lock files. Point TMPDIR at
  # a directory that really exists; never create one inside the repository.
  if [ -n "${TMPDIR-}" ] && [ -d "$TMPDIR" ] && [ -w "$TMPDIR" ]; then
    return 0
  fi
  for cand in /tmp "${TEMP-}" "${TMP-}" /c/Users/fixadmin/AppData/Local/Temp "${HOME-}"; do
    [ -n "$cand" ] || continue
    if [ -d "$cand" ] && [ -w "$cand" ]; then
      TMPDIR=$cand; export TMPDIR
      log "TMPDIR=$cand (avoids the missing-/tmp warning)"
      return 0
    fi
  done
  for cand in "${TEMP-}" /c/Users/fixadmin/AppData/Local/Temp; do
    [ -n "$cand" ] || continue
    if command -v mkdir >/dev/null 2>&1 && mkdir -p "$cand" 2>/dev/null && [ -w "$cand" ]; then
      TMPDIR=$cand; export TMPDIR
      log "TMPDIR=$cand (created)"
      return 0
    fi
  done
  log "no writable temporary directory found; continuing without TMPDIR"
  return 0
}

git_path() {
  # git.exe here is native Git for Windows, so C:/... and C:\... are already
  # valid. Backslashes are normalised when tr is available, and a POSIX
  # /c/Users/... path is rewritten to c:/Users/... because native git would
  # otherwise treat it as relative.
  _p=$1
  case $_p in
    *\\*) if command -v tr >/dev/null 2>&1; then _p=$(printf '%s' "$_p" | tr '\\' '/'); fi ;;
  esac
  case $_p in
    /?/*)
      _rest=${_p#/}; _drive=${_rest%%/*}; _tail=${_rest#*/}
      case $_drive in
        [A-Za-z]) printf '%s' "$_drive:/$_tail"; return 0 ;;
      esac ;;
  esac
  printf '%s' "$_p"
}

default_commit() {
  # Base commit for the offline / no-PR-head case: the remote default branch if
  # known, then main, then HEAD. Always a commit id, so the branch can be
  # created even when main itself is checked out in another worktree.
  _def=$(git -C "$BASE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  [ -n "$_def" ] || _def=origin/main
  for _c in "$_def" origin/main main HEAD; do
    if _sha=$(git -C "$BASE" rev-parse --verify --quiet "$_c^{commit}" 2>/dev/null); then
      printf '%s\n' "$_sha"; return 0
    fi
  done
  return 1
}

# --- worktree helpers --------------------------------------------------------

current_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }

usable_checkout() {
  # Ready only when HEAD resolves *and* index/object plumbing works, which
  # catches a half-built worktree.
  [ -n "$(current_branch "$1")" ] || return 1
  git -C "$1" status --porcelain >/dev/null 2>&1
}

has_branch() { git -C "$BASE" show-ref --verify --quiet "refs/heads/$BRANCH"; }

add_worktree() {
  # $1 = new (create the branch) | attach (reuse an existing branch)
  if [ "$1" = new ]; then
    if _out=$(git -C "$BASE" worktree add -b "$BRANCH" "$DIR" "$START" 2>&1); then
      log "created $DIR on new branch $BRANCH from $START"
      return 0
    fi
  else
    if _out=$(git -C "$BASE" worktree add "$DIR" "$BRANCH" 2>&1); then
      log "attached $DIR to existing branch $BRANCH"
      return 0
    fi
  fi
  ADD_ERROR=$_out
  return 1
}

try_add() { if has_branch; then add_worktree attach; else add_worktree new; fi; }

dir_is_empty() {
  [ -d "$1" ] || return 1
  command -v ls >/dev/null 2>&1 || return 1
  [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

registered_here() {
  # Does the base clone still hold a worktree registration for exactly $DIR?
  _pl=$(git -C "$BASE" worktree list --porcelain 2>/dev/null)
  case $_pl in
    *"worktree $DIR"*) return 0 ;;
  esac
  return 1
}

clean_stale_registration() {
  # A registration whose directory is gone or half-built blocks re-use of both
  # the path and the branch. Real checkouts are never touched.
  registered_here || return 0
  if [ -d "$DIR" ] && usable_checkout "$DIR"; then return 0; fi
  log "dropping stale worktree registration for $DIR"
  git -C "$BASE" worktree remove --force "$DIR" >/dev/null 2>&1 || true
  git -C "$BASE" worktree prune >/dev/null 2>&1 || true
  if dir_is_empty "$DIR"; then rmdir "$DIR" 2>/dev/null || true; fi
  return 0
}

fetch_ticket_ref() {
  # Bounded on purpose: a stalled network must not eat the ticket's 10 minutes.
  if command -v timeout >/dev/null 2>&1; then
    timeout "${FETCH_TIMEOUT:-120}" git -C "$BASE" fetch --no-tags \
      "https://github.com/$REPO.git" "${PR_HEAD}:${TICKET_REF}" >/dev/null
  else
    git -C "$BASE" fetch --no-tags \
      "https://github.com/$REPO.git" "${PR_HEAD}:${TICKET_REF}" >/dev/null
  fi
}

# --- main --------------------------------------------------------------------

fix_tmpdir

TICKET=${DSH_SUPERAGENT_TICKET:-}
NAME=${DSH_SUPERAGENT_NAME:-}
RAW_DIR=${DSH_SUPERAGENT_DIR:-}
REPO=${DSH_SUPERAGENT_GITHUB_REPOSITORY:-}
PR_HEAD=${DSH_SUPERAGENT_GITHUB_PR_HEAD:-}

[ -n "$NAME" ] || fail "DSH_SUPERAGENT_NAME is empty; cannot name the agent branch"
[ -n "$RAW_DIR" ] || fail "DSH_SUPERAGENT_DIR is empty; no ticket directory to create"
command -v git >/dev/null 2>&1 || fail "git is not on PATH"
git -C "$BASE" rev-parse --git-dir >/dev/null 2>&1 || fail "base clone is not a git repository: $BASE"

DIR=$(git_path "$RAW_DIR")
BRANCH="agent/$NAME"
START=
ADD_ERROR=
BRANCH_EXISTED=0

log "ticket=${TICKET:-<none>} branch=$BRANCH dir=$DIR"

# Retry over a healthy directory: nothing to do, whatever created it.
if [ -d "$DIR" ] && usable_checkout "$DIR"; then
  cur=$(current_branch "$DIR")
  if [ "$cur" = "$BRANCH" ]; then
    log "already prepared on $BRANCH; nothing to do"
    exit 0
  fi
  log "WARNING: $DIR already holds a checkout on '$cur', expected '$BRANCH'; leaving it untouched"
  exit 0
fi

# 1. Fetch the ticket ref, but only when the ticket carries a PR head. An empty
#    PR head, missing repository, or an unreachable network all fall through to
#    the local default branch instead of failing.
TICKET_REF=
if [ -n "$TICKET" ]; then TICKET_REF="refs/dsh-superagent/$TICKET"; fi
if [ -n "$PR_HEAD" ] && [ -n "$REPO" ] && [ -n "$TICKET_REF" ]; then
  export GIT_TERMINAL_PROMPT=0
  log "fetching $PR_HEAD from https://github.com/$REPO.git"
  if fetch_ticket_ref; then
    log "fetched into $TICKET_REF"
  else
    log "fetch failed (network or credentials); continuing with local refs"
  fi
fi

# 2. Pick the base commit.
if [ -n "$TICKET_REF" ]; then
  START=$(git -C "$BASE" rev-parse --verify --quiet "${TICKET_REF}^{commit}" 2>/dev/null || true)
  if [ -n "$START" ]; then log "basing on ticket ref $TICKET_REF ($START)"; fi
fi
if [ -z "$START" ]; then
  START=$(default_commit) || fail "no usable base commit in $BASE (looked for origin/HEAD, origin/main, main, HEAD)"
  log "basing on the clone default branch ($START)"
fi

# 3. Create the worktree, with one repair-and-retry pass for a retry run.
if has_branch; then BRANCH_EXISTED=1; else BRANCH_EXISTED=0; fi
git -C "$BASE" worktree prune >/dev/null 2>&1 || true
if ! try_add; then
  log "worktree add failed: $ADD_ERROR"
  clean_stale_registration
  if dir_is_empty "$DIR"; then rmdir "$DIR" 2>/dev/null || true; fi
  if ! try_add; then
    log "retry failed: $ADD_ERROR"
    if [ "$BRANCH_EXISTED" = 0 ] && has_branch; then
      git -C "$BASE" branch -D "$BRANCH" >/dev/null 2>&1 && log "dropped branch $BRANCH created by this failed attempt"
    fi
    fail "could not create the ticket worktree at $DIR on branch $BRANCH; $DIR exists and is not one of our checkouts"
  fi
fi

# 4. Final check: the directory must really be a working checkout.
if usable_checkout "$DIR"; then
  log "ready: $(current_branch "$DIR") at $DIR"
  exit 0
fi
fail "worktree created but $DIR is not a usable checkout"