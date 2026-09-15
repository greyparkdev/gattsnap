#!/usr/bin/env bash
#
# End-to-end test for the gattsnap diff Action.
#
# Builds the image, stands up a throwaway repository whose branches differ the
# way a firmware pull request differs, and asserts the step's exit code and
# outputs for each gating mode.
#
# This exists because the parts of the Action that break are not the parts unit
# tests reach: the git plumbing, the exit-code mapping, and whether annotation
# paths come out relative to the workspace. Every one of those is invisible
# until the container actually runs.
#
# Usage: ./scripts/test-action.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/Tests/GATTSnapshotCoreTests/Fixtures"
WORK="$(mktemp -d)"
IMAGE="gattsnap-action:selftest"
trap 'rm -rf "$WORK"' EXIT

failures=0

echo "==> building $IMAGE"
docker build -q -t "$IMAGE" "$ROOT" >/dev/null

echo "==> staging a synthetic firmware repository"
REPO="$WORK/repo"
mkdir -p "$REPO/snapshots"
git init -q -b main "$REPO"
git -C "$REPO" config user.email selftest@example.invalid
git -C "$REPO" config user.name "gattsnap selftest"

commit() { # commit <branch-from> <branch> <fixture>
    git -C "$REPO" checkout -q "$1"
    git -C "$REPO" checkout -q -B "$2"
    cp "$FIXTURES/$3.json" "$REPO/snapshots/sensor.json"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "$2"
}

cp "$FIXTURES/variant-a.json" "$REPO/snapshots/sensor.json"
git -C "$REPO" add -A
git -C "$REPO" commit -qm baseline

# A valid commit that genuinely lacks the snapshot is first adoption. An
# unresolvable ref is a configuration/fetch failure and must not be conflated
# with this branch.
git -C "$REPO" checkout -q -b no-snapshot-base
git -C "$REPO" rm -q snapshots/sensor.json
printf 'first adoption base\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm no-snapshot-yet
git -C "$REPO" checkout -q main

commit main breaking-change     variant-b
commit main cosmetic-change     variant-a-cosmetic
# Handles need their own baseline: comparing a handle-bearing snapshot against
# one captured without --include-handles is a different scenario entirely, and
# it gets its own case below.
commit main handles-base        variant-a-handles
commit handles-base handles-shifted variant-a-handles-shifted
commit main handles-no-baseline variant-a-handles-shifted

# run <name> <branch> <expected-step-exit> <expected-exit-code-output> <args...>
run() {
    local name="$1" branch="$2" want_step="$3" want_code="$4"; shift 4
    local out="$WORK/out" summary="$WORK/summary"
    : >"$out"; : >"$summary"
    git -C "$REPO" checkout -q "$branch"

    local step=0
    docker run --rm \
        -v "$REPO":/github/workspace \
        -v "$out":/github/output \
        -v "$summary":/github/summary \
        -e GITHUB_WORKSPACE=/github/workspace \
        -e GITHUB_OUTPUT=/github/output \
        -e GITHUB_STEP_SUMMARY=/github/summary \
        "$IMAGE" "$@" >"$WORK/log" 2>&1 || step=$?

    local code
    code="$(sed -n 's/^exit-code=//p' "$out")"

    if [ "$step" = "$want_step" ] && [ "${code:-none}" = "$want_code" ]; then
        printf '  ok    %-42s step=%s exit-code=%s\n' "$name" "$step" "${code:-none}"
    else
        printf '  FAIL  %-42s step=%s (want %s) exit-code=%s (want %s)\n' \
            "$name" "$step" "$want_step" "${code:-none}" "$want_code"
        sed 's/^/          /' "$WORK/log"
        failures=$((failures + 1))
    fi
}

SNAP=snapshots/sensor.json

echo "==> gating"
run "breaking, fail-on=breaking"   breaking-change  1 2 "$SNAP" "" main false false breaking
run "breaking, fail-on=any-change" breaking-change  1 2 "$SNAP" "" main false false any-change
run "breaking, fail-on=never"      breaking-change  0 2 "$SNAP" "" main false false never
run "cosmetic, fail-on=breaking"   cosmetic-change  0 1 "$SNAP" "" main false false breaking
run "cosmetic, fail-on=any-change" cosmetic-change  1 1 "$SNAP" "" main false false any-change
run "clean, fail-on=any-change"    main             0 0 "$SNAP" "" main false false any-change

echo "==> handles"
# Without --diff-handles this is a quiet hash difference, not a finding. With it,
# every moved attribute is breaking. Getting these two backwards would make the
# tool's headline feature silently inert.
run "handle shift, handles off"    handles-shifted  0 0 "$SNAP" "" handles-base false false breaking
run "handle shift, handles on"     handles-shifted  1 2 "$SNAP" "" handles-base true  false breaking

# The trap the tool exists to not fall into: one side captured with
# --include-handles and the other without. Findings are dropped, so this must
# degrade to exit 3 and fail — never collapse to a passing "no changes".
run "mismatched capture options"   handles-no-baseline 1 3 "$SNAP" "" main true false breaking

echo "==> error and first-adoption paths"
run "no base snapshot"             breaking-change  0 0 "$SNAP" "" no-snapshot-base false false breaking
run "invalid base ref"              breaking-change  1 none "$SNAP" "" no-such-ref false false breaking
run "snapshot not found"           main             1 none snapshots/absent.json "" main false false breaking
run "unknown fail-on"              main             1 none "$SNAP" "" main false false bogus

echo "==> annotation paths are workspace-relative"
: >"$WORK/out"
git -C "$REPO" checkout -q breaking-change
docker run --rm -v "$REPO":/github/workspace -v "$WORK/out":/github/output \
    -e GITHUB_WORKSPACE=/github/workspace -e GITHUB_OUTPUT=/github/output \
    "$IMAGE" "$SNAP" "" main false false never >"$WORK/log" 2>&1 || true

if grep -q "file=$SNAP,line=[0-9]" "$WORK/log"; then
    echo "  ok    annotations carry a workspace-relative path and a line"
else
    echo "  FAIL  annotations are missing a relative path or a line number"
    sed 's/^/          /' "$WORK/log"
    failures=$((failures + 1))
fi

# GitHub drops an annotation containing a raw newline, and the handle-shift note
# has a blank line in it — so this is the likeliest way for output to silently
# stop appearing in a pull request.
if grep -qv '^::' "$WORK/log" 2>/dev/null && grep -c '' "$WORK/log" >/dev/null; then
    if grep -v '^::' "$WORK/log" | grep -q .; then
        echo "  FAIL  output contains a line that is not a workflow command"
        grep -v '^::' "$WORK/log" | sed 's/^/          /'
        failures=$((failures + 1))
    else
        echo "  ok    every output line is a workflow command"
    fi
else
    echo "  ok    every output line is a workflow command"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "action self-test passed"
else
    echo "action self-test FAILED ($failures)"
    exit 1
fi
