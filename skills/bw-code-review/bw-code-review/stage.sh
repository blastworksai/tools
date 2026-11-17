#!/usr/bin/env bash
# stage.sh: stage a read-only review of <head> against a freshly fetched <base>,
# in a private mirror of the repository. It never checks anything out.
#
# usage: stage.sh <owner/name> <base-branch> <head>
#   <owner/name>   the GitHub repository, e.g. octocat/hello-world
#   <base-branch>  the branch the change lands on: main, or origin/main
#   <head>         the commit under review: a PR number (407), pull/<n>/head, a full
#                  40-hex SHA, or a branch name (origin/<branch> or <branch>)
#
# Root folder: ${BW_REVIEW_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/bw-code-review}
# The mirror is a bare repository at <root>/repos/<owner>__<name>.git (mode 0700, created
# on first use) with origin https://github.com/<owner>/<name>.git.
# Each run fetches base and head into it, authenticated only by the caller's own
# `gh` login through `gh auth git-credential`: every other credential helper is
# switched off for the fetch, and no token is ever put on a command line or in a file.
#
# Writes into <root>/<head-short>/ (mode 0700):
#   diff.patch  git diff -M -D <base>...<head>   (three-dot: only the change's own side;
#               -D prints a deleted file as a header, not its whole body)
#   files.txt   --name-status of the same range
#   stat.txt    --stat of the same range
#   meta.txt    repo, mirror, base branch + SHA, merge-base, head + SHA, staged-at time
# prints "mirror: <path>" and then the staging folder as its last line.
#
# Read files at the reviewed commit with: git -C <mirror> show <head-sha>:<path>
# It never checks anything out and never runs tests.
#
# STAGE_NO_FETCH=1 skips the fetch and uses whatever the mirror already holds
# (say so in the review: the base was not moved).
# STAGE_REMOTE_BASE overrides the https://github.com prefix of the mirror's origin
# (tests only).

set -euo pipefail
umask 077

if [ "$#" -ne 3 ]; then
    echo "usage: stage.sh <owner/name> <base-branch> <head>" >&2
    exit 2
fi
REPO_ARG=$1
BASE_ARG=$2
HEAD_ARG=$3
ROOT=${BW_REVIEW_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/bw-code-review}
REMOTE_BASE=${STAGE_REMOTE_BASE:-https://github.com}
NAME_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

cannot_observe() {
    echo "stage.sh: $1" >&2
    echo "stage.sh: that is a REWORK NEEDED with reason 'could not observe: <what>', not a defect in the change." >&2
    exit 1
}

# --- <owner/name> ---------------------------------------------------------------
SLUG=$REPO_ARG
if ! [[ "$SLUG" =~ $NAME_RE ]] || [[ "$SLUG" == *..* ]]; then
    echo "stage.sh: '$REPO_ARG' is not owner/name" >&2
    exit 2
fi
OWNER=${SLUG%%/*}
NAME=${SLUG#*/}

# --- <base-branch> -> branch ------------------------------------------------------------
BASE_BRANCH=${BASE_ARG#origin/}
BASE_BRANCH=${BASE_BRANCH#refs/heads/}
if ! git check-ref-format --branch "$BASE_BRANCH" >/dev/null 2>&1; then
    echo "stage.sh: base '$BASE_ARG' is not a branch name" >&2
    exit 2
fi
BASE_REF="refs/remotes/origin/$BASE_BRANCH"

# --- <head> -> what to fetch and what to resolve ---------------------------------
HEAD_FETCH=""
if [[ "$HEAD_ARG" =~ ^#?([0-9]+)$ ]] || [[ "$HEAD_ARG" =~ ^pull/([0-9]+)/head$ ]]; then
    PR=${BASH_REMATCH[1]}
    HEAD_REF="refs/remotes/origin/pull/$PR/head"
    HEAD_FETCH="+refs/pull/$PR/head:$HEAD_REF"
elif [[ "$HEAD_ARG" =~ ^[0-9a-f]{40}$ ]]; then
    HEAD_REF=$HEAD_ARG
    HEAD_FETCH=$HEAD_ARG
elif [[ "$HEAD_ARG" =~ ^[0-9a-f]{7,39}$ ]]; then
    HEAD_REF=$HEAD_ARG # a short SHA cannot be fetched; it resolves only if the mirror has it
else
    HEAD_BRANCH=${HEAD_ARG#origin/}
    HEAD_BRANCH=${HEAD_BRANCH#refs/heads/}
    if ! git check-ref-format --branch "$HEAD_BRANCH" >/dev/null 2>&1; then
        echo "stage.sh: head '$HEAD_ARG' is not a PR number, SHA or branch name" >&2
        exit 2
    fi
    HEAD_REF="refs/remotes/origin/$HEAD_BRANCH"
    HEAD_FETCH="+refs/heads/$HEAD_BRANCH:$HEAD_REF"
fi

# --- the private mirror ----------------------------------------------------------
own_dir() { # create (if absent) a 0700 folder and refuse one another user owns
    mkdir -p "$1"
    if [ ! -O "$1" ]; then
        echo "stage.sh: $1 belongs to another user; refusing to write into it" >&2
        exit 1
    fi
    chmod 700 "$1"
}
own_dir "$ROOT"
own_dir "$ROOT/repos"
MIRROR="$ROOT/repos/${OWNER}__${NAME}.git"
ORIGIN_URL="$REMOTE_BASE/$OWNER/$NAME.git"
if [ ! -e "$MIRROR" ]; then
    git init --quiet --bare "$MIRROR"
    git -C "$MIRROR" remote add origin "$ORIGIN_URL"
fi
own_dir "$MIRROR"
if [ "$(git -C "$MIRROR" config --get remote.origin.url || true)" != "$ORIGIN_URL" ]; then
    echo "stage.sh: $MIRROR does not point at $ORIGIN_URL; refusing to use it" >&2
    exit 1
fi

FETCHED=yes
if [ "${STAGE_NO_FETCH:-0}" = "1" ]; then
    FETCHED="no (STAGE_NO_FETCH=1)"
else
    REFSPECS=("+refs/heads/$BASE_BRANCH:$BASE_REF")
    if [ -n "$HEAD_FETCH" ]; then
        REFSPECS+=("$HEAD_FETCH")
    fi
    # The empty helper clears every inherited helper (a system or repository one may read
    # a secret this user cannot); the second hands git the caller's own gh login.
    if ! GIT_TERMINAL_PROMPT=0 git -C "$MIRROR" \
        -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
        fetch --quiet --no-tags origin "${REFSPECS[@]}"; then
        cannot_observe "git fetch of $OWNER/$NAME ($BASE_BRANCH, $HEAD_ARG) into $MIRROR failed; the base cannot be moved."
    fi
fi

if ! HEAD_SHA=$(git -C "$MIRROR" rev-parse --verify --quiet "$HEAD_REF^{commit}"); then
    if [ "$FETCHED" = "yes" ]; then
        cannot_observe "head $HEAD_ARG is not a commit in $MIRROR after the fetch (pass the full SHA or the PR number)"
    fi
    cannot_observe "head $HEAD_ARG is not in $MIRROR, and STAGE_NO_FETCH=1 fetched nothing"
fi
if ! BASE_SHA=$(git -C "$MIRROR" rev-parse --verify --quiet "$BASE_REF^{commit}"); then
    cannot_observe "base $BASE_BRANCH is not in $MIRROR"
fi
if ! MERGE_BASE=$(git -C "$MIRROR" merge-base "$BASE_SHA" "$HEAD_SHA"); then
    echo "stage.sh: $BASE_BRANCH and $HEAD_ARG share no history" >&2
    exit 1
fi

OUT="$ROOT/${HEAD_SHA:0:12}"
own_dir "$OUT"

git -C "$MIRROR" diff -M -D "$BASE_SHA...$HEAD_SHA" >"$OUT/diff.patch"
git -C "$MIRROR" diff -M --name-status "$BASE_SHA...$HEAD_SHA" >"$OUT/files.txt"
git -C "$MIRROR" diff -M --stat "$BASE_SHA...$HEAD_SHA" >"$OUT/stat.txt"
{
    echo "repo: $OWNER/$NAME"
    echo "mirror: $MIRROR"
    echo "base: $BASE_BRANCH"
    echo "base_sha: $BASE_SHA"
    echo "merge_base: $MERGE_BASE"
    echo "head: $HEAD_ARG"
    echo "head_sha: $HEAD_SHA"
    echo "fetched: $FETCHED"
    echo "staged_at: $(date '+%Y-%m-%d %H:%M %Z')"
} >"$OUT/meta.txt"

echo "stage.sh: $(wc -l <"$OUT/files.txt") file(s), $(wc -c <"$OUT/diff.patch") diff bytes" >&2
echo "mirror: $MIRROR"
echo "$OUT"
