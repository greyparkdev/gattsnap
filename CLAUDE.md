# CLAUDE.md

**Read [docs/project-state.md](docs/project-state.md) before starting work.** It
covers current status, architecture, decisions already made, known gaps, and the
mistakes already paid for. [docs/overview.md](docs/overview.md) explains the
product without code.

gattsnap captures a BLE peripheral's GATT attribute table into a canonical,
diffable file, then diffs two snapshots and classifies changes by severity, so an
unintended GATT change shows up in a pull request before it breaks deployed
mobile clients.

The engine — capture, diff, classification, and the CI/pull-request surface — is
complete and tested. BlueZ is the largest remaining engineering piece.

## Working agreement

- **Stop at milestone boundaries and check in.** Do not run past one.
- **Ask before making architectural decisions that weren't specified.**
- **Push back if a milestone's scope seems wrong** once you're inside it.
- Prefer boring, obvious Swift over clever. Tests are not optional.
- Non-goals — flag rather than quietly build: iOS app, GUI, code generation from
  snapshots, test-runner DSL, Android, BlueZ adapter. The adapter *boundary* must
  stay clean enough that BlueZ is straightforward to add later.

## Do not undo these

They look like cruft if you arrive cold. Each was established the hard way and is
explained in the docs above.

- `GATTSnapshotCore` **never** imports CoreBluetooth and must keep building on
  Linux. Verify before committing changes to it.
- `DiffEngine.compare` has **no** parameter through which `CaptureMetadata` could
  reach it. That exclusion is enforced by the type system on purpose.
- `GATTHandleProbe` is a separate target linked only on macOS via
  `.when(platforms: [.macOS])`. Do not merge it into `GATTCapture` or downgrade it
  to an `#if` — the private selectors must be *absent* from an iOS binary, not
  dormant in it.
- Bluetooth permission needs a signed `.app` **and** runtime self-disclaiming. The
  widely-recommended `-sectcreate __TEXT __info_plist` linker trick does not work
  and fails silently; do not "simplify" `scripts/build-app.sh` back to it.
- Cache detection with an unset threshold is **disabled and says so loudly**. It
  must never silently default to a passing check.
- The bonded-peripheral case is **unverified**. Do not design around an assumption
  in either direction, and do not re-tune the 10 ms threshold on the strength of
  the unbonded measurements.

## Commands

```bash
swift build && swift test                                            # macOS
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test    # Linux — run before committing Core changes
./scripts/test-action.sh                                             # end-to-end GitHub Action test; needs Docker

./scripts/build-app.sh                                               # signed gattsnap.app; required for capture/scan
./gattsnap.app/Contents/MacOS/gattsnap scan [--seconds 8] [--all] [--format human|json]
./gattsnap.app/Contents/MacOS/gattsnap capture --name "<x>" --profile <label> --out snap.json

# diff needs no bundle and no radio
gattsnap diff <base.json> <head.json> [--format human|json|junit|github|markdown] [--summary <p>] [--diff-handles] [--fail-on-warning]
```

Running `.build/debug/gattsnap capture` directly will be killed by TCC — always go
through the `.app` bundle path.
