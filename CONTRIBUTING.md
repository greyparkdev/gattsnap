# Contributing to gattsnap

Thanks for looking. gattsnap is an **experimental** project released to find out
whether snapshotting and diffing BLE GATT tables in CI is useful to real teams.
Bug reports, real-world usage notes, and small focused fixes are all welcome.

Before opening a large change, please open an issue first — the scope is
deliberately narrow (see [Scope](#scope)) and it is kinder to discuss a big
change before you write it.

## Build and test

You need a Swift 6.1 toolchain. No Bluetooth hardware is needed for anything
except capture.

```bash
swift build
swift test                                                          # 160 tests
```

`GATTSnapshotCore` and `GATTSnapshotReport` must keep building on Linux with no
CoreBluetooth import. Verify that before submitting anything that touches them:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test
```

The GitHub Action has its own end-to-end test, which needs Docker:

```bash
./scripts/test-action.sh
```

Capture (`gattsnap capture` / `scan`) is macOS-only and needs a signed `.app`
bundle plus a Bluetooth permission grant — see the README. You do **not** need it
to work on the diff engine, the reporters, or the Action.

## What to know before you change code

Please read [docs/project-state.md](docs/project-state.md) first. A few
constraints there look like cruft but are load-bearing, and are enforced on
purpose (§2, §3, §4). In particular:

- `GATTSnapshotCore` never imports CoreBluetooth and must build on Linux.
- `DiffEngine.compare` has no parameter through which capture metadata can reach
  it — snapshots are compared on their attribute table alone, by design.
- `GATTHandleProbe` is a macOS-only target on purpose; do not fold it into
  `GATTCapture` or gate it with `#if`.
- A degraded comparison must never be able to collapse into a passing exit code.

[docs/schema-decisions.md](docs/schema-decisions.md) explains the snapshot format
and why the stored ordering and comparison ordering differ.

## Scope

In scope: the snapshot format, the diff/severity engine, the reporters, the
GitHub Action, macOS capture, and a future BlueZ (Linux) or Android adapter that
conforms to `CaptureAdapter` without touching the model or diff engine.

Out of scope (flag, don't quietly build): an iOS app, a GUI, code generation from
snapshots, a test-runner DSL. These keep the tool small on purpose.

## Style

- Prefer boring, obvious Swift over clever.
- Tests are not optional. Most bugs in this project were found by running the
  thing against real input, not by reading it — a test that exercises the new
  path is worth more than one that asserts the happy case.
- Match the surrounding code's naming and structure.

## Submitting

1. Fork and branch.
2. Make the change with tests; keep the Linux build green.
3. Open a pull request describing what changed and why, and how you verified it.

By contributing you agree that your contributions are licensed under the
[Apache-2.0](LICENSE) license that covers this project.
