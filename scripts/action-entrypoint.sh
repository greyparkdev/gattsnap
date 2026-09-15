#!/bin/sh
#
# Entrypoint for the gattsnap diff Action. Arguments come from action.yml, in
# order, and are always present (empty string when unset).
#
#   $1 snapshot   $2 base   $3 base-ref   $4 diff-handles
#   $5 fail-on-warning      $6 fail-on
#
# Written for /bin/sh, not bash: the runtime image is plain Ubuntu, and adding
# bash to it just to use arrays would be a strange trade.

set -eu

SNAPSHOT="$1"
BASE_PATH="$2"
BASE_REF="$3"
DIFF_HANDLES="$4"
FAIL_ON_WARNING="$5"
FAIL_ON="$6"

WORKSPACE="${GITHUB_WORKSPACE:-/github/workspace}"
cd "$WORKSPACE"

# Docker actions mount the workspace with a different owner than the container
# user, and modern git refuses to operate on a repository it considers foreign.
# Without this every `git show` below fails with "dubious ownership".
git config --global --add safe.directory "$WORKSPACE" 2>/dev/null || true

emit() {
    [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
    return 0
}

fail_step() {
    printf '::error title=gattsnap::%s\n' "$1"
    exit 1
}

if [ -z "$SNAPSHOT" ]; then
    fail_step "the 'snapshot' input is required"
fi
if [ ! -f "$SNAPSHOT" ]; then
    fail_step "snapshot not found at '$SNAPSHOT' (paths are relative to the repository root)"
fi

case "$FAIL_ON" in
    breaking|any-change|never) ;;
    *) fail_step "unknown fail-on '$FAIL_ON'; expected breaking, any-change or never" ;;
esac

# ---------------------------------------------------------------- base side

RESOLVED_BASE="$BASE_PATH"
BASE_LABEL="$BASE_PATH"

if [ -z "$RESOLVED_BASE" ]; then
    REF="$BASE_REF"
    if [ -z "$REF" ]; then
        # Set on pull_request events; absent on push, where the previous commit
        # is the honest comparison point.
        REF="${GITHUB_BASE_REF:-}"
        if [ -n "$REF" ]; then
            REF="origin/$REF"
        else
            REF="HEAD^"
        fi
    fi

    if ! git rev-parse --verify "$REF^{commit}" >/dev/null 2>&1; then
        fail_step "base ref '$REF' does not resolve to a commit; fetch it or set a valid base-ref"
    fi

    # What a reviewer needs to see is the commit, not the scratch file it landed
    # in. The short SHA is resolved so the label survives a moving branch ref.
    BASE_LABEL="$SNAPSHOT@$(git rev-parse --short "$REF")"
    if ! git cat-file -e "$REF:$SNAPSHOT" 2>/dev/null; then
        # A snapshot that is new on this branch is the normal first-adoption
        # case, not an error. Failing here would mean the very pull request that
        # introduces gattsnap is the one it breaks.
        printf '::notice title=gattsnap::%s\n' \
            "no base snapshot at $REF:$SNAPSHOT — nothing to compare yet. This is expected on the pull request that first commits it."
        emit "compared" "false"
        emit "exit-code" "0"
        emit "verdict" "no base snapshot to compare against"
        exit 0
    fi
    RESOLVED_BASE="$(mktemp /tmp/gattsnap-base-XXXXXX)"
    if ! git show "$REF:$SNAPSHOT" >"$RESOLVED_BASE" 2>/dev/null; then
        fail_step "could not read base snapshot at $REF:$SNAPSHOT"
    fi
fi

if [ ! -s "$RESOLVED_BASE" ]; then
    fail_step "base snapshot '$RESOLVED_BASE' is empty"
fi

# ---------------------------------------------------------------- the diff

set -- "$RESOLVED_BASE" "$SNAPSHOT" --format github --annotate-path "$SNAPSHOT" \
       --base-label "$BASE_LABEL" --head-label "$SNAPSHOT"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && set -- "$@" --summary "$GITHUB_STEP_SUMMARY"
[ "$DIFF_HANDLES" = "true" ] && set -- "$@" --diff-handles
[ "$FAIL_ON_WARNING" = "true" ] && set -- "$@" --fail-on-warning

# `set -e` would abort on gattsnap's non-zero exit, which is its normal way of
# reporting a finding rather than a failure to run.
set +e
gattsnap diff "$@"
CODE=$?
set -e

case "$CODE" in
    0) VERDICT="no changes" ;;
    1) VERDICT="additive or cosmetic changes only" ;;
    2) VERDICT="breaking changes present" ;;
    3) VERDICT="degraded — findings were dropped from an unobservable range" ;;
    4) VERDICT="warnings present, and fail-on-warning was set" ;;
    64|65|70) fail_step "gattsnap could not run (exit $CODE); see the log above" ;;
    *) fail_step "gattsnap exited $CODE, which this action does not recognise" ;;
esac

emit "compared" "true"
emit "exit-code" "$CODE"
emit "verdict" "$VERDICT"

# ---------------------------------------------------------------- gating
#
# 3 and 4 fail alongside 2 under the default. A degraded comparison dropped
# findings, so treating it as a pass would be exactly the failure this tool
# exists to prevent — reporting a blind spot as a fact.

case "$FAIL_ON" in
    never)
        exit 0
        ;;
    any-change)
        [ "$CODE" -eq 0 ] && exit 0
        exit 1
        ;;
    breaking)
        [ "$CODE" -le 1 ] && exit 0
        exit 1
        ;;
esac
