# gattsnap

Capture a BLE peripheral's GATT attribute table into a canonical, diffable file.
Commit it. When firmware changes the table, the diff shows up in the pull request
— classified by severity — instead of in support tickets.

A device's GATT table is a contract with every app already installed on every
customer's phone. `gattsnap` makes that contract a file in your repository.

```
BREAKING (2)
  180D/2A37  [property_removed]
      characteristic 2A37 lost the 'notify' property
  180D/2A37/2902  [descriptor_removed]
      CCCD (0x2902) removed from characteristic 2A37 — clients can no longer
      subscribe to notifications or indications

exit 2  breaking changes present
```

> **Status: experimental.** Diffing, five output formats and the GitHub Action are
> complete and tested on macOS and Linux; macOS capture has been exercised against
> real hardware. The BlueZ (Linux) capture adapter is not built yet, and the
> bonded-peripheral cache case is unverified. See
> [docs/project-state.md](docs/project-state.md) for exactly what is and is not
> verified, and please treat a clean diff as evidence, not proof, of client
> compatibility.

---

## Try it in five minutes — no Bluetooth, no signing

`diff` is pure Swift with no radio and no permission model, so you can see a
real breaking-change report against the bundled synthetic snapshots on macOS
**or** Linux, with nothing but a Swift toolchain:

```bash
git clone https://github.com/greyparkdev/gattsnap.git && cd gattsnap
swift run gattsnap diff \
  Tests/GATTSnapshotCoreTests/Fixtures/variant-a.json \
  Tests/GATTSnapshotCoreTests/Fixtures/variant-b.json
```

You get a classified report — three breaking changes, two additive — and **exit
code 2**. From there:

- `--format markdown` or `--format github` shows the two CI surfaces.
- `--diff-handles` and `--fail-on-warning` exercise the policy flags.

Capturing your own device is the other path, and it needs a Mac and a signed
bundle — see [Install](#install).

---

## Install

macOS 13+, Swift 6. Capture requires a signed `.app` bundle — this is not
optional, see [Bluetooth permission](#bluetooth-permission-on-macos).

```bash
git clone https://github.com/greyparkdev/gattsnap.git && cd gattsnap
./scripts/build-app.sh
```

That produces `gattsnap.app/Contents/MacOS/gattsnap`. Run it through the bundle
path, not from `.build`.

```bash
alias gattsnap="$PWD/gattsnap.app/Contents/MacOS/gattsnap"
```

## Worked example

Your firmware team ships `acme-sensor`. It exposes a heart-rate service whose
measurement characteristic supports `notify`, which is how the phone app receives
live readings.

### 0. Find the device

You cannot capture a device whose advertised name you do not know, and it is not
something you can look up anywhere else.

```bash
gattsnap scan
```

```
RSSI   NAME                       IDENTIFIER
-39    acme-sensor-a1b2           11111111-2222-3333-4444-555555555555
       OS-cached name differs: 'acme-sensor-old' — match on the advertised name above
       services: 180D, 180F
-90    ESP32                      39FADDEA-3097-4789-8F4E-944BA33D7B6D

19 non-connectable advertiser(s) hidden — pass --all to show them.

To capture the strongest match:
  gattsnap capture --name "acme-sensor-a1b2" --profile <label> --out snapshot.json
```

Strongest signal first, so the board on your desk is at the top. Non-connectable
advertisers are hidden by default — you cannot capture them — but counted, so a
missing device is never a mystery.

The `OS-cached name differs` line matters: macOS remembers a name independently of
what the device broadcasts, and they drift. Match on the advertised name.

### 1. Capture the baseline and commit it

```bash
gattsnap capture --name "acme-sensor" --profile acme-sensor-v2 --out gatt/acme-sensor.json
```

```
gattsnap: wrote gatt/acme-sensor.json
  profile          acme-sensor-v2
  structure_hash   sha256:3c2eb3c0518b39f04927a91e07ac056d8ae3104dcfc3667e37650e1a81bd1313
  attributes       3 service(s), 4 characteristic(s)
  discovery        461.0 ms
  handles          not recorded
```

```bash
git add gatt/acme-sensor.json && git commit -m "Record GATT baseline"
```

The file is plain JSON with normalized table ordering and explicit
platform-dependent fields. Capture metadata such as timestamps and RSSI varies
between runs; the table's `structure_hash` excludes that metadata.

### 2. A firmware change lands

Someone refactors the heart-rate service. Nothing obviously breaks; the firmware
builds, the unit tests pass, and a manual test with a fresh phone works fine —
because a fresh app re-discovers the table and adapts.

### 3. CI captures again and diffs

```bash
gattsnap capture --name "acme-sensor" --profile acme-sensor-v2 --out /tmp/head.json
gattsnap diff gatt/acme-sensor.json /tmp/head.json
```

```
base  gatt/acme-sensor.json
      profile 'acme-sensor-v2'  sha256:3c2eb3c0…
head  /tmp/head.json
      profile 'acme-sensor-v2'  sha256:457b8b97…

BREAKING (2)
  180D/2A37  [property_removed]
      characteristic 2A37 lost the 'notify' property
  180D/2A37/2902  [descriptor_removed]
      CCCD (0x2902) removed from characteristic 2A37 — clients can no longer
      subscribe to notifications or indications

ADDITIVE (1)
  180D/2A38  [characteristic_added]
      characteristic 2A38 added to service 180D [read]

NOT COVERED  outside what these adapters can observe
  GAP/GATT services (0x1800/0x1801), including device name (0x2A00) not
  comparable: neither adapter can observe it — nothing was dropped, but the
  comparison does not cover it

exit 2  breaking changes present
```

The build fails. Every deployed app that subscribes to heart-rate notifications
would have silently stopped receiving them — and no test on a developer's desk
would have caught it, because a fresh app re-discovers and adapts. Only an app
that was *already installed* breaks.

## Commands

### `scan`

```bash
gattsnap scan [--seconds <s>] [--all] [--format human|json] [--no-color]
```

Exits `0` when something connectable was found, `1` when nothing was.

### `capture`

```bash
gattsnap capture (--name <substring> | --id <uuid>) --profile <label> [options]
```

| flag | |
|---|---|
| `--name <substring>` | match the advertised local name, case-insensitive |
| `--id <uuid>` | match the peripheral identifier (host-scoped, see below) |
| `--profile <label>` | **required.** Product label recorded in the snapshot |
| `--out <path>` | write here instead of stdout |
| `--include-handles` | record attribute handles (macOS only, private API) |
| `--scan-timeout <s>` | default 12 |
| `--connect-timeout <s>` | default 15 |
| `--auth-timeout <s>` | default 45 |
| `--cache-threshold <ms>` | default 10; `off` **disables** cache detection |

### `diff`

```bash
gattsnap diff <base.json> <head.json> [options]
```

| flag | |
|---|---|
| `--format <f>` | `human` (default), `json`, `junit`, `github`, `markdown` |
| `--out <path>` | write here instead of stdout |
| `--summary <path>` | additionally write a markdown summary here |
| `--annotate-path <p>` | repo-relative path for `github` annotations |
| `--base-label <s>` `--head-label <s>` | display names, when a path is a temp file |
| `--diff-handles` | compare attribute handles; a shift is breaking |
| `--fail-on-warning` | promote warnings into the exit code |
| `--no-color` | never colourise (also honours `NO_COLOR`) |

Colour is automatic when stdout is a terminal and suppressed when piped.

`--format github` emits GitHub Actions workflow commands, so each finding becomes
an inline annotation on the line of the snapshot file it concerns. Removals have
no line in the head snapshot, so they annotate the nearest attribute that still
exists — a removed characteristic lands on its service.

## Exit codes

| code | meaning |
|---|---|
| `0` | no changes |
| `1` | additive or cosmetic changes only |
| `2` | breaking changes present |
| `3` | degraded — findings were dropped from a range one side cannot observe |
| `4` | warnings present, and `--fail-on-warning` was set |

Precedence is by how much you should worry, not numerically: `2 > 3 > 4 > 1 > 0`.
**A degraded comparison can never collapse to `0` or `1`** and be mistaken for a
pass.

To fail only on breaking changes:

```bash
gattsnap diff base.json head.json; [ $? -ne 2 ]
```

## Severity

| | |
|---|---|
| **breaking** | service or characteristic removed, property dropped, descriptor or CCCD removed, included service removed, service demoted to secondary — and, under `--diff-handles`, a handle shift |
| **additive** | new service, characteristic, property, descriptor, or included service |
| **cosmetic** | Device Information (0x180A) value changed — manufacturer name, model number, firmware revision |

### Handle shifts

Off by default, because handles legitimately move on any additive change. But
they detect something nothing else does:

> A bonded client caches the attribute table **by handle**. If handles shift under
> a firmware update without a Service Changed indication, that client reads or
> writes the wrong attribute until it re-discovers — so it breaks in the field
> while a fresh re-discovery test passes completely clean.

Both snapshots must have been captured with `--include-handles`. When they were
not, the diff says so rather than silently skipping.

## CI

The two halves of `gattsnap` have very different hosting requirements, and it is
worth being blunt about which is which.

**`diff` runs anywhere.** Pure Swift, no radio, no CoreBluetooth, no permission
model. It works on a stock GitHub-hosted Linux runner today.

**`capture` needs hardware** — a Bluetooth adapter, a physical peripheral, and on
macOS a TCC grant that no hosted runner can give. It belongs on a self-hosted
runner or a developer's desk.

So the pull-request check compares the **committed** snapshot against the version
of that same file on the base branch. The capture that produced it happened
earlier, wherever the hardware is.

### GitHub Action

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0        # required: the base snapshot is read with `git show`

- uses: greyparkdev/gattsnap@v0.1.0
  with:
    snapshot: snapshots/acme-sensor.json
    fail-on: breaking
```

| input | |
|---|---|
| `snapshot` | **required.** Path to the committed snapshot, relative to the repo root |
| `base` | explicit base snapshot path; defaults to reading `snapshot` from `base-ref` |
| `base-ref` | ref to compare against; defaults to the pull request's base branch |
| `diff-handles` | compare attribute handles (`false` by default) |
| `fail-on-warning` | promote warnings into the exit code |
| `fail-on` | `breaking` (default, fails on exit 2/3/4), `any-change` (also 1), `never` |

Outputs `exit-code`, `verdict` and `compared`. Findings appear as inline
annotations on the snapshot file, and the full report — which annotations cannot
be, since GitHub caps them at ten per level — goes to the job summary.

A snapshot that is new on the branch has nothing to compare against, so the
action reports that and passes. The pull request that first adopts `gattsnap` is
not the one it should block.

### Plain `run:` steps

No action required if you would rather not add one:

```yaml
- run: gattsnap diff base.json head.json --format junit --out results.xml
```

JUnit output makes every finding its own `<testcase>`, so each shows up as a named
row in the CI UI rather than as prose buried in one message body. Breaking changes
and dropped findings are `<failure>`; standing platform limitations and warnings
are `<skipped>`, so they stay **visible without failing the build**.

### Bluetooth permission on macOS

**This is a real adoption cost. Read it before planning a CI rollout.**

macOS attributes a Bluetooth request to the *responsible process* of the process
tree — Terminal, `sshd`, your CI runner — not to `gattsnap`. Three things are
required, and none is sufficient alone:

1. an `.app` bundle carrying `NSBluetoothAlwaysUsageDescription`
2. a real code-signing identity (ad-hoc has no stable identity and stalls forever)
3. self-disclaiming at runtime, which `gattsnap` does automatically

`scripts/build-app.sh` handles 1 and 2. The widely-recommended
`-sectcreate __TEXT __info_plist` linker trick **does not work** and fails with no
message on stderr — see [docs/platform-notes.md](docs/platform-notes.md) §1.

**The first run needs a human to click Allow.** On a headless runner nobody can,
so a macOS CI job needs an **MDM-deployed PPPC profile** granting
`kTCCServiceBluetoothAlways` to the bundle identifier. There is no CLI to
pre-authorize this.

A Linux/BlueZ adapter would avoid all of this. The core and diff engine already
build and test on Linux; only the capture backend is missing.

## What it will not pretend to know

A clean result is only worth having if it means what it says.

**It refuses rather than guesses.** CoreBluetooth can serve a cached attribute
table instead of reading the air. A cache hit measures 0.0 ms; real discovery
measures 439–471 ms. Below the 10 ms threshold, `capture` refuses to emit a
snapshot at all rather than vouch for one it did not read.

**It never hides what it could not see.** CoreBluetooth cannot observe GAP/GATT
services (so device name 0x2A00 is unreachable), MAC addresses, or advertising
parameters. Where a comparison genuinely drops a finding, that is reported as its
own class with exit code `3` — never as "removed", and never silently.

**Capture metadata is excluded from diffs by contract.** Timestamps, RSSI, host
name and the host-scoped peripheral UUID live in `capture_metadata`, which the
diff engine has no parameter to receive. Two engineers on two Macs capturing the
same device produce the same `structure_hash`.

## Snapshot format

Version-tagged from day one, language-neutral, stably ordered.

```json
{
  "schema_version": 1,
  "profile": "acme-sensor-v2",
  "adapter": {
    "id": "corebluetooth",
    "capability_version": 1,
    "capabilities": {
      "handles": false, "mac_address": false,
      "gap_gatt_services": false, "advertising_parameters": false
    }
  },
  "structure_hash": "sha256:…",
  "capture_metadata": { "captured_at": "…", "host": "…", "rssi": -49 },
  "table": { "services": [ { "uuid": "180A", "characteristics": [] } ] }
}
```

`structure_hash` is a SHA-256 over the canonically sorted attribute table only,
so CI can ask "did anything change at all" without running a full diff. When it
differs but the diff reports nothing, the report explains why rather than leaving
you with two contradicting signals.

Existing schema-1 snapshots remain readable without migration. Older captures
may store repeated UUIDs in discovery order, while new captures use handles to
order them when available. If that ordering alone changes the hash, the diff
explains it with a `stored_order_differs` warning and reports no attribute changes.

`--profile` is a human label, not an identity key. It warns on mismatch and never
fails — the file's identity is its path in your repository.

## Documentation

| | |
|---|---|
| [docs/overview.md](docs/overview.md) | the product without the code |
| [docs/project-state.md](docs/project-state.md) | status, architecture, known gaps |
| [docs/platform-notes.md](docs/platform-notes.md) | measured CoreBluetooth findings |
| [docs/schema-decisions.md](docs/schema-decisions.md) | design decisions and reasoning |

## Development

```bash
swift test                                                          # 160 tests
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test    # Linux
```

`GATTSnapshotCore` is pure Swift with no CoreBluetooth import and must keep
building on Linux — a BlueZ or Android adapter conforms to `CaptureAdapter`
without touching the model or the diff engine.

## Not doing

No iOS app, no GUI, no code generation from snapshots, no assertion DSL, no
Android, no BlueZ adapter yet — but the adapter boundary keeps one
straightforward to add.

## License

[Apache-2.0](LICENSE), copyright Grey Park LLC.
