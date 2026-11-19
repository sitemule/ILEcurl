#!/usr/bin/env bash
# sync_build.sh — [optionally] rsync to IBM i then run gmake via SSH
#
# Usage: .sitemule/sync_build.sh [gmake-target] [VAR=value ...]
#
# Config (in .env or as environment variables):
#   I_HOST       SSH hostname or alias for the IBM i
#   DEPLOY_PATH  Deployment path on the IBM i  (e.g. /prj/ILEvator)
#   RSYNC_EXCLUDE  Optional: more paths rsync must not send, separated by blanks
#   SKIP_RSYNC   Set to "true" to force-skip rsync (auto-detected for network mounts)
#
# MAKEDIR=<folder> runs gmake in that folder of the project (examples, issues, ...).
# When the build writes error.txt (the makefiles' "current" / "example" targets send the
# compiler output there), it is shown afterwards, so VS Code's problem matcher sees it.
#
# Examples:
#   .sitemule/sync_build.sh all
#   .sitemule/sync_build.sh current SRC=src/ilevator.c OUTPUT=*PRINT
#   .sitemule/sync_build.sh compile MAKEDIR=examples "SRC=IVEX01-Simple GET request.rpgle"
#   .sitemule/sync_build.sh sync-only
#
# Master copy: .sitemule/sync_build.sh in the sitemule-factory repo - the same file in every
# project that builds this way; project settings go in its .env.

# Load .env if present (does not override already-exported vars)
if [ -f ".env" ]; then
    set -o allexport
    # shellcheck disable=SC1091
    source .env
    set +o allexport
fi

: "${I_HOST:?I_HOST is not set. Add it to .env or export it before running.}"
: "${DEPLOY_PATH:?DEPLOY_PATH is not set. Add it to .env or export it before running.}"

MAKE_TARGET="${1:-all}"
shift 1 || true

# The remaining args are make variables; MAKEDIR= is ours. Quote each one for the remote
# shell - file names may contain blanks.
BUILD_DIR="$DEPLOY_PATH"
MAKE_VARS=""
for arg in "$@"; do
    case "$arg" in
        MAKEDIR=*) BUILD_DIR="$DEPLOY_PATH/${arg#MAKEDIR=}" ;;
        *)     MAKE_VARS="$MAKE_VARS $(printf '%q' "$arg")" ;;
    esac
done

# ---------------------------------------------------------------
# Auto-detect if the workspace is on a network/IFS share.
# When the project folder is mounted from the IBM i over SMB/NFS
# and opened directly (rather than cloned locally), rsync is not
# needed — edits already land on the IFS.
# ---------------------------------------------------------------
if [ -z "$SKIP_RSYNC" ]; then
    _fs=$(df -P . 2>/dev/null | awk 'NR==2{print $1}')
    case "$_fs" in
        //*) SKIP_RSYNC=true ;;
        *)   SKIP_RSYNC=false ;;
    esac
fi

# ---------------------------------------------------------------
# 1. Sync source files (local clone → IBM i only)
#
# --inplace: write directly to the target file instead of using a
#   temp file + rename. Avoids "Device busy (16)" on IBM i IFS when
#   another job has the directory open.
# --ignore-errors: treat per-file errors as warnings so the build
#   still runs even if one locked file couldn't be updated.
# ---------------------------------------------------------------
if [ "$SKIP_RSYNC" = "true" ]; then
    echo ">>> Working from IFS share — skipping rsync."
else
    echo ">>> Syncing to $I_HOST:$DEPLOY_PATH ..."
    rsync -az \
        --inplace \
        --ignore-errors \
        --exclude '.git/' \
        --exclude '.gitignore' \
        --exclude '.gitattributes' \
        --exclude '.vscode/' \
        --exclude '.DS_Store' \
        --exclude 'node_modules/' \
        --exclude '.claude/' \
        --exclude '.github/' \
        --exclude 'error.txt' \
        $(for x in $RSYNC_EXCLUDE; do printf -- "--exclude %s " "$x"; done) \
        --rsync-path="/QOpenSys/pkgs/bin/rsync" \
        --omit-dir-times \
        --no-perms \
        "./" \
        "$I_HOST:$DEPLOY_PATH" || echo ">>> rsync finished with warnings (continuing to build)"
    # Leave a note on the IFS: this folder is a copy of the git repo, edits here are lost
    .sitemule/git_managed_note.sh "$I_HOST" "$DEPLOY_PATH"
fi

# ---------------------------------------------------------------
# 2. Build on IBM i (skip if target is sync-only)
# ---------------------------------------------------------------
if [ "$MAKE_TARGET" = "sync-only" ]; then
    echo ">>> Sync complete (no build requested)."
    exit 0
fi

# BUILD_JOBQ (optional, .env): run gmake as a batch job on this job queue instead of in the ssh
# session - e.g. QBATCH, one job at a time - so builds and deploys (RUNSQLSTM jobs on the same
# queue) on the box run one after the other instead of over each other. Waits for the job and
# shows its output while it runs. Without it gmake runs in the ssh session, as before.
if [ -n "$BUILD_JOBQ" ]; then
    REMOTE="/tmp/sync_build-$(date +%Y%m%d%H%M%S)-$$"
    echo ">>> Submitting to job queue $BUILD_JOBQ: gmake $MAKE_TARGET$MAKE_VARS in $BUILD_DIR"
    ssh "$I_HOST" "cat > $REMOTE.sh" <<REMOTE_SCRIPT
PATH=/QOpenSys/pkgs/bin:\$PATH
cd '$BUILD_DIR' || { echo 1 > $REMOTE.rc; exit 1; }
rm -f error.txt
gmake $MAKE_TARGET$MAKE_VARS > $REMOTE.log 2>&1
rc=\$?
[ -s error.txt ] && cat error.txt >> $REMOTE.log
echo \$rc > $REMOTE.rc
REMOTE_SCRIPT
    ssh "$I_HOST" "system \"SBMJOB CMD(QSH CMD('/QOpenSys/usr/bin/sh $REMOTE.sh')) JOB(GMAKE) JOBQ($BUILD_JOBQ)\"" || exit 1
    # Show the job's output while it runs: a waiter ends when the job has written its return
    # code (or after BUILD_WAIT seconds), and GNU tail follows the log until the waiter is gone
    # (--pid: it prints what is left, then stops). -F: the log appears when the job starts -
    # until then it waits in the queue behind the others.
    echo ">>> Waiting for the job (queued behind others on $BUILD_JOBQ, then running) - its output follows"
    ssh "$I_HOST" "PATH=/QOpenSys/pkgs/bin:\$PATH
        ( waited=0
          while [ ! -f $REMOTE.rc ] && [ \$waited -lt ${BUILD_WAIT:-3600} ]; do sleep 2; waited=\$((waited + 2)); done ) &
        waiter=\$!
        tail -n +1 -F --pid=\$waiter $REMOTE.log 2>/dev/null
        wait \$waiter
        if [ ! -f $REMOTE.rc ]; then
            echo '>>> No result after ${BUILD_WAIT:-3600}s - the job may still be queued or have ended abnormally (WRKSBMJOB, $REMOTE.log)'
            exit 1
        fi
        rc=\$(cat $REMOTE.rc); rm -f $REMOTE.sh $REMOTE.log $REMOTE.rc; exit \$rc"
    exit $?
fi

echo ">>> Building in $BUILD_DIR: gmake $MAKE_TARGET$MAKE_VARS"
ssh "$I_HOST" "PATH=/QOpenSys/pkgs/bin:\$PATH
    cd '$BUILD_DIR' || exit 1
    rm -f error.txt
    gmake $MAKE_TARGET$MAKE_VARS; rc=\$?
    [ -s error.txt ] && cat error.txt
    exit \$rc"
