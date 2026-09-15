# gattsnap — project state

> **Status:** Experimental open-source release. The engine — capture, diff,
> severity classification, and the CI/pull-request surface — is complete and
> tested. The BlueZ adapter is the largest remaining piece.

**Orientation document for engineers and for future agents working on this
repository.** Read this first. It says what exists, what is decided, what is
deliberately unresolved, and which mistakes have already been made and paid for.

- Non-technical framing: [overview.md](overview.md)
- Empirical platform findings: [platform-notes.md](platform-notes.md)
- Design decisions with reasoning: [schema-decisions.md](schema-decisions.md)

> **Starting a fresh session? Read §1, §8 and §12.** §12 is the roadmap: what to
> pick up, and the five-minute checks that should happen before any adapter work,
> because they could invalidate things currently written down as fact. (Check 1 —
> does BlueZ expose handles and 0x1800/0x1801 — is done and passed, 2026-08-10;
> Check 2 remains.)

---

## 1. Status

| Milestone | State |
|---|---|
| **M1** — hardware spike, platform findings | ✅ complete (`1cf935c`) |
| **M2** — model, schema, diff engine | ✅ complete (`93d8ebc`) |
| **M3** — macOS capture | ✅ complete (`00583d7`) |
| **M4** — CLI diff output modes, README, CI surface | ✅ complete |
| **M5** — pull-request surface: annotations, job summary, GitHub Action | ✅ complete (diff half only) |
| **Next** — BlueZ adapter, and validation with real users | ⬜️ not started |

**160 tests in 27 suites, green on macOS and on Linux** (`swift:6.1-noble` under
Docker), plus 15 end-to-end Action cases in `scripts/test-action.sh`.
Reverified 2026-09-15 after the technical fixes and schema-1 hash compatibility
repair. The compatibility fixture comes from the original `fecf23a` writer;
existing files require no migration. See `schema-decisions.md` for the stored
ordering versus comparison ordering contract.

Live smoke test on 2026-09-15: two captures of a test peripheral
with `--include-handles` and default cache detection succeeded
(6 services, 18 characteristics; discovery 379 ms and 298 ms). Their structure
hashes matched and `diff --diff-handles --fail-on-warning` exited 0 without
warnings. Captures remain outside the repository. This checks ordinary repeat
capture, not bonded-cache behavior or injected discovery failures.

Working end to end today: `gattsnap capture` has been exercised against hardware,
but the repository retains no live-device snapshots. `gattsnap diff` supports
human, JSON, JUnit, GitHub and markdown formats, with all five exit codes
verified through the real binary. `gattdemo` is deleted — `gattsnap diff`
replaced it.

### Licensing

`LICENSE` is Apache-2.0 (verbatim upstream text) — chosen over MIT for the
contributor patent grant (§3) and the trademark reservation (§6); the patent
language is the part worth having in BLE tooling.

CI runs on every push — Linux, macOS and the Action self-test.

### The working agreement

How this repository is built, and how contributions are reviewed:

- **Prefer boring, obvious Swift over clever.**
- **Tests are not optional.**
- **Ask before making architectural decisions that weren't specified.** Do not
  quietly pick and proceed.
- **Push back if a change's scope seems wrong once inside it.** This has happened
  productively several times — see §7.
- Non-goals, to be flagged rather than quietly built: no iOS app, no GUI, no code
  generation, no test-runner DSL, no Android — but the adapter boundary must keep
  a new adapter (BlueZ, Android) straightforward to add.

---

## 2. Repository layout

```
Package.swift              GATTSnapshotCore, GATTSnapshotReport, GATTHandleProbe, GATTCapture, gattsnap
action.yml, Dockerfile     the GitHub Action — diff half only, see §10
Sources/
  GATTSnapshotCore/        pure Swift, no CoreBluetooth, MUST keep building on Linux
    Model/                 AttributeTable, Snapshot, Adapter (capabilities + registry)
    Serialization/         SHA256, StructureHash, SnapshotCoding
    Diff/                  Change, DiffReport, DiffEngine
    CacheDetection.swift   threshold policy
    CaptureAdapter.swift   the platform boundary protocol
  GATTSnapshotReport/      human / JSON / JUnit / GitHub / markdown renderers,
                           plus SnapshotLineIndex. Linux-clean like Core
  GATTHandleProbe/         private-API handle reads. macOS-only, see §4
  GATTCapture/             CoreBluetooth adapter (macOS + iOS)
  gattsnap/                the CLI: `scan`, `capture` and `diff`
Tests/GATTSnapshotCoreTests/
  Fixtures/*.json          six synthetic fixtures
scripts/build-app.sh       builds + signs gattsnap.app (required, see §4)
scripts/action-entrypoint.sh   Action entrypoint: resolves the base with `git show`
scripts/test-action.sh     end-to-end Action test against a throwaway git repo
spike/                     M1 spike. `serve` is retained; the probes are throwaway
docs/
```

### Fixtures

Six synthetic (`variant-*`) fixtures cover the severity taxonomy,
cross-adapter degradation and handle shifts. Live-device captures are deliberately
not retained in this repository: even a nominally anonymized GATT table can reveal
vendor UUIDs, firmware structure and other vendor or third-party information.

### Layering rule, non-negotiable

`GATTSnapshotCore` never imports CoreBluetooth and must compile and test on
Linux. Verify with:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test
```

Run this before committing anything that touches Core. It has caught real
problems and is cheap.

---

## 3. The snapshot format

The product's actual contract. Version-tagged (`schema_version: 1`), stably
ordered, pretty-printed with sorted keys because these files are read in pull
request diffs.

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
  "capture_metadata": { "captured_at": "…", "host": "…", "rssi": -49, … },
  "table": { "services": [ { "uuid": "180A", "characteristics": [ … ] } ] }
}
```

Four things about this that are load-bearing:

**`table` is the only diffable payload.** `capture_metadata` is excluded *by
contract, not convention*: `DiffEngine.compare` takes `AttributeTable` and
capabilities, and has no parameter through which metadata could reach it. This is
enforced by the type system so a later edit cannot quietly start diffing a
timestamp. Do not "helpfully" add a metadata parameter.

**There is no identity key.** The file's identity is its path in the repo.
`peripheral.identifier` is a *host-scoped UUID* — two Macs produce different
values for the same physical device — so it can never key anything.
`--profile` is a required human label used for warnings only; a mismatch warns and
never fails.

**`structure_hash`** is SHA-256 over a canonical text encoding of the table alone,
deliberately *not* over the JSON, so an encoder change cannot silently invalidate
every committed snapshot. Handles participate in it. See §7 for why that created a
problem and how it was solved.

**UUIDs are normalized** to short form when inside the Bluetooth base range, so a
CoreBluetooth `"180A"` and a BlueZ `"0000180a-0000-1000-8000-00805f9b34fb"`
compare equal. Without this every cross-adapter diff would report every standard
service as simultaneously removed and added.

### Severity taxonomy

| Severity | Kinds |
|---|---|
| **breaking** | `service_removed`, `characteristic_removed`, `property_removed`, `descriptor_removed`, `handle_shift`, `included_service_removed`, `service_primary_changed` (to secondary) |
| **additive** | `service_added`, `characteristic_added`, `property_added`, `descriptor_added`, `included_service_added` |
| **cosmetic** | `device_information_changed` |

### Exit codes

```
0  clean
1  additive or cosmetic only
2  breaking
3  degraded — findings were dropped from an unobservable range
4  warnings present and --fail-on-warning was set
```

Precedence is by how much a reader should worry, not numerically:
`2 > 3 > 4 > 1 > 0`. The invariant that matters: **a degraded comparison can never
collapse to 0 or 1 and be mistaken for a pass.**

---

## 4. macOS platform realities

All of this was established empirically in M1. Full detail and measurements in
[platform-notes.md](platform-notes.md).

### Bluetooth permission needs three things, and none suffices alone

1. A **`.app` bundle** — TCC resolves the usage description from the containing
   bundle.
2. A **real signing identity** — TCC keys on (bundle id, team id), so the grant
   survives rebuilds. Ad-hoc signing has no stable identity and stalls at
   `notDetermined` forever.
3. **Self-disclaiming at runtime** — `responsibility_spawnattrs_setdisclaim`, so
   the process becomes its own TCC-responsible process.

> ⚠️ The widely-recommended `-sectcreate __TEXT __info_plist` linker trick **does
> not work**, and fails deceptively: the section lands, `codesign` seals it,
> `Bundle.main.infoDictionary` reads it back at runtime — and TCC still SIGABRTs
> the process with **nothing on stderr**. The reason is that TCC bills the
> *responsible process* of the tree (Terminal, sshd, a CI runner), never your
> binary. Do not "simplify" the build script back to this.

Build and run:

```bash
./scripts/build-app.sh
./gattsnap.app/Contents/MacOS/gattsnap scan [--seconds 8] [--all] [--format human|json]
./gattsnap.app/Contents/MacOS/gattsnap capture --name "<x>" --profile <label> --out snap.json
```

Running `.build/debug/gattsnap` directly will be killed by TCC. A new bundle ID
needs a fresh human "Allow" click.

### What CoreBluetooth can and cannot see

| | |
|---|---|
| Attribute handles | ✅ available — declared ObjC properties, but **private API** |
| MAC address | ❌ `CBPeripheral.BDAddress` exists and returns **nil** |
| Raw advertising PDU | ❌ parsed dictionary only |
| Descriptor values | ✅ readable, but **type-varying** (NSNumber/NSString/NSData) |
| GAP 0x1800 / GATT 0x1801 | ❌ **filtered out of discovery entirely** |

That last one has two consequences worth internalising: Service Changed (0x2A05)
is not reachable as a cache-busting lever, and device name (0x2A00) lives inside
GAP so a rename is *unobservable* on Apple platforms rather than cosmetic-clean.

### Handles are private API, and isolated at the package level

`GATTHandleProbe` is its own target, linked into `GATTCapture` **only on macOS**
via `.when(platforms: [.macOS])`. This is deliberate and was specifically
requested: a runtime guard would leave the private selectors present-but-dormant
in a shipped iOS binary, and App Review scans for the symbol, not for whether it
executes. **Do not merge this target into `GATTCapture` or replace the platform
condition with an `#if`.**

The probe reads keys only after confirming via `class_copyPropertyList` that a
property backs them, because `-valueForKey:` raises on an unknown key and Swift
cannot catch an ObjC exception. A future macOS that drops these degrades to
"handles absent" instead of crashing.

### Other traps found the hard way

- **CoreBluetooth has no connection timeout.** A peripheral can match, accept
  `connect`, and never call back — neither `didConnect` nor `didFailToConnect`.
  Every adapter must impose its own bound. Observed on a real third-party device.
- **`peripheral.name` is OS-cached** and survives a device rename. Match and
  capture from `kCBAdvDataLocalName` instead.
- **Not every advertiser is connectable** — check `kCBAdvDataIsConnectable`.
- **`kCBAdvDataTimestamp`** is capture-time-varying and must never enter a
  snapshot.

---

## 5. Cache detection

Apple can serve a stale cached attribute table instead of reading the air. A tool
that accepted one would report "no changes" for a device that changed completely.

Measured in M1: a cache hit is **0.0 ms**; real over-the-air discovery is
**439–471 ms**, including from a fresh process. Three orders of magnitude, so any
threshold in the 5–50 ms band works. **Set to 10 ms**
(`CacheDetectionPolicy.measured`). Below it, `capture` refuses to emit a snapshot.

> **Hard requirement:** if the threshold is ever unset, detection is **disabled**
> and the run must say so loudly (`CacheDetectionPolicy.disabledWarning`, echoed
> by the CLI and stamped into the summary). It must **never** silently default to
> a passing check. An unset safety threshold that quietly becomes a pass is the
> same failure class as reporting a blind spot as a fact.

> 🔶 **The bonded-peripheral case is UNVERIFIED.** The measurements above come
> from an unbonded device (`isLinkEncrypted = 0`, `pairingState = 0`). The spec
> permits persistent caching only for *bonded* peripherals — precisely where a
> stale table is most likely, and it needs bonded hardware to test. **Do not
> design around an assumption in either direction**, and do not quietly re-tune
> the threshold on the strength of the unbonded numbers.

> 🔴 **Worse: the experiment is confounded.** Vendor literature reports that
> Apple platforms do not cache when the Generic Attribute Service (0x1801) is
> present on the peripheral, and *both* devices measured turn out to have it —
> their first visible service handle is 10, leaving 1–9 for the hidden GAP/GATT.
> So the result is equally consistent with "bonding is the variable" and with
> "0x1801 presence is the variable", and those imply different at-risk
> populations: the second is wider and identifiable in advance. The experiment
> has to become a 2×2 over {bonded, unbonded} × {0x1801 present, absent}; only
> one cell has data. Full reasoning in [platform-notes.md](platform-notes.md) §3,
> "The confound".

`spike/blespike serve --variant a|b` is the test rig for this. Usefully,
`CBPeripheralManager` cannot publish 0x1800/0x1801, so its peripheral almost
certainly lands in the **0x1801-absent** column — making it the right tool for
the untested row rather than just a convenience. Confirm by capturing it with
`--include-handles` and checking whether its first service starts at handle 1. It publishes a
controlled, mutable GATT table via `CBPeripheralManager`; variant B drops a
property, removes a characteristic, adds a characteristic and adds a service, so
one mutation exercises breaking *and* additive. A Mac cannot discover its own
advertisements, so this needs a second machine — see §12, where the test rig that
provides one is specified.

---

## 6. Adapter capabilities — how cross-platform honesty works

Every snapshot records what its adapter observed. The diff intersects them and
splits the result in two, which is the subtlest part of the design:

| category | meaning | degrades? |
|---|---|---|
| `suppressed_comparison` | a finding was **actually dropped** — one side saw something the other structurally cannot | ✅ exit 3 |
| `standing_limitation` | neither side could ever see it, so nothing was dropped | ❌ reported only |

Suppression is detected **as the diff walks the table**, not inferred from
capability flags, so degradation reflects what was genuinely lost.

Recorded capabilities are **declaration ∩ capture options**: a CoreBluetooth
capture without `--include-handles` records `handles: false` even though the
adapter *can* read them. Otherwise a diff cannot distinguish "not captured" from
"unchanged". `SnapshotCoding.validate` rejects a snapshot claiming more than its
adapter's registry declaration allows.

`AdapterRegistry` already declares a `bluez` v1 entry with full capabilities, so
the cross-adapter path is exercised by tests before the adapter exists. Its
`handles` and `gap_gatt_services` claims were confirmed empirically on 2026-08-10
(§12, check 1); `mac_address` was already certain; `advertising_parameters`
remains unmeasured.

### Adding a new adapter

1. Conform to `CaptureAdapter` in a new target.
2. Add its declaration to `AdapterRegistry.declarations`.
3. `capabilities(for:)` returns declaration ∩ options.
4. Nothing in `Model/`, `Serialization/` or `Diff/` should need to change. If it
   does, the boundary has leaked — fix the boundary.

---

## 7. Mistakes already made and paid for

Kept because rediscovering them is expensive.

**Degradation was initially inferred from capability flags.** Every
CoreBluetooth↔CoreBluetooth diff exited 3 — permanently, on the primary platform.
A signal that fires on 100% of runs is one everyone learns to ignore, which would
have defeated the very requirement it served. Fixed by splitting
`suppressed_comparison` from `standing_limitation`. *Caught by tests.*

**`structure_hash` and the diff could contradict each other.** Handles are in the
hash, but the default diff doesn't compare them — so a handle shift made the cheap
CI check say "changed" while the full diff said "clean". Fixed with a
`quiet_hash_difference` warning that names the cause rather than by removing
handles from the hash. *Caught by running the demo by hand.*

**The `undetermined` cause was documented as unreachable — and was reached
immediately.** Capturing a device once without `--include-handles` and once with
produced `undetermined`, i.e. the tool told the user to file a bug for an ordinary
workflow. Fixed by adding `capture_options_differ`, scoped to same-adapter
comparisons. *Caught within two minutes of running against real hardware.*

**A warning claimed "both snapshots record attribute handles" when only one did**,
and recommended `--diff-handles`, which would have degraded the run rather than
explaining anything. Fixed by requiring both sides to carry handles before
suggesting it.

**The first TCC error message blamed the wrong cause** (disclaim) with a 5-second
window, when the real cause was an unanswered permission dialog. The three
authorization failures look identical from outside and have completely different
fixes; the diagnosis now branches on `CBManager.authorization` and the window is
45 s.

**The handle-shift note was repeated verbatim in all six rows** of a markdown
handle-shift table — sixty words of the most important text in the product,
restated per row until the table was unreadable. Notes are now de-duplicated and
hoisted below the table. *Caught by looking at the rendered output, not by a
test; every assertion still passed.*

**The first CI run failed before compiling a line.** `macos-14` ships Xcode 15 /
Swift 5.10, which cannot even *parse* a `swift-tools-version: 6.0` manifest.
`macos-15` defaults to Xcode 16.4, whose Swift 6.1 matches the `swift:6.1-noble`
container the Linux job uses. Worth knowing before adding any macOS job. In the
same pass, `actions/checkout` turned out to be at **v7**, not the v4 in the
original workflows or the v5 that looked like the obvious bump — the version was
checked against the API rather than assumed, which is the cheaper habit.

The pattern worth noticing: **every one of these was found by running the thing,
not by reading it.** Build the harness, run it against real inputs, and read the
output critically.

---

## 8. Known gaps and open questions

**Open design questions:**

- 🔶 **Bonded peripherals** (§5). Needs bonded hardware to unblock.
- 🔶 **BlueZ-first?** TCC's responsible-process attribution plus an MDM
  requirement is a real adoption tax on the CI story specifically — which is the
  headline use case. Linux has none of it and sees *more* of the table. Held open
  deliberately.
- **`--diff-handles` is under-served by `capture`.** Diffing handles needs both
  snapshots to have them, so a team must remember `--include-handles` on every
  capture forever; one forgotten flag silently downgrades the comparison. Sticky
  per-profile capture settings, or a loud warning at capture time, would fix it.

**Known limitations, documented rather than hidden:**

- **0x2A00 device name** is a readable characteristic on BlueZ but is not in the
  0x180A allowlist, so a rename currently classifies as *nothing*. A passing test
  documents this. Two-line fix when wanted.
- **Duplicate-UUID siblings** match on `(uuid, instance)`, so swapping two
  same-UUID characteristics is invisible. Unfixable without handles.
- **Descriptor values are recorded but never diffed** — CCCD value is
  per-connection state. Presence *is* diffed.
- **Characteristic values are diffed only for the 0x180A allowlist** — everything
  else is runtime state and would make every capture dirty.

---

## 9. Output formats (M4 and M5, shipped)

`GATTSnapshotReport` holds the renderers. It is a **fourth target the
original architecture did not specify** — added so the formats could be unit
tested, since renderers inside an executable are not practically testable and
`GATTSnapshotCore` should stay free of presentation. Reversible if unwanted.

| finding | JUnit element |
|---|---|
| breaking change | `<failure>` |
| additive / cosmetic change | passing case + `<system-out>` |
| suppressed comparison (degrades) | `<failure>` |
| standing limitation | `<skipped>` |
| warning, `--fail-on-warning` on | `<failure>` |
| warning, off | `<skipped>` |

Every finding is its own `<testcase>` — a named row in the CI UI — rather than
prose in one message body (D5). Warnings appear in *both* states: a warning that
only surfaced when it also failed the build would be useless for the case
`--fail-on-warning` exists to serve.

An empty report still emits one testcase, or CI reports "no tests ran" and green
becomes indistinguishable from a broken job.

Colour is decided in the CLI (`isatty` + `NO_COLOR` + `--no-color`) and passed to
the renderer, so every rendering path is testable with colour off.

XML escaping is not optional: diff details carry `<`, `&` and quotes from UUIDs
and device strings, and one unescaped character makes the document unparseable —
which CI reports as an infrastructure error rather than as the finding it was
trying to show. Tests run the output through a real `XMLParser`, which needs
`import FoundationXML` on Linux.

### Still not started

- **BlueZ adapter.** See §8 — the decision on whether it comes first is open.

---

## 10. The pull-request surface (M5, shipped)

Two renderers and an Action, all on the **diff half only**. `diff` is pure Swift
with no radio and no permission model, so it runs on a stock GitHub-hosted Linux
runner today; `capture` needs hardware and stays on a desk or a self-hosted
runner. That split is what made this shippable before the platform decision in §8
is settled — nothing here has to be redone when it is.

**`--format github`** emits workflow commands. Levels mirror the JUnit mapping
deliberately, so one finding cannot be a failure in one CI surface and a note in
another.

**`SnapshotLineIndex`** maps an `AttributePath` onto a line in the head snapshot
file, so an annotation lands on the characteristic that changed. It does not
decode the file — `SnapshotCoding` already did, and the caller holds the resulting
table, which is what supplies array indices. All that was missing is where each
element begins, so it only skims structure and counts newlines.

Three things about it are load-bearing:

- **Removals fall back outward.** Roughly half of all findings are removals, and a
  removed attribute has no line in the head snapshot. A removed characteristic
  annotates its service; a removed service annotates `table`. Without this the
  most important findings would be the ones with no location.
- **It anchors on the `uuid` line, not the opening brace.** GitHub shows the
  annotated line's text next to the message, and `{` tells a reviewer nothing.
- **Malformed input degrades, never hangs.** Every branch consumes a byte and
  every loop is bounded, so a hand-mangled file yields a partial index and a
  coarser annotation.

**Annotations are capped at ten per level by GitHub, silently.** A tool whose
premise is never reporting a blind spot as a fact cannot let that happen quietly,
so a capped level spends its last slot saying how many findings it is hiding and
pointing at the job summary, which always carries all of them.

**`--summary <path>` appends** rather than truncating: `$GITHUB_STEP_SUMMARY` is
shared with every other step in the job.

### The Action

`action.yml` + `Dockerfile` at the repository root, entrypoint in
`scripts/action-entrypoint.sh`. It resolves the base snapshot with
`git show <base-ref>:<path>`, which is what makes it a pull-request diff rather
than a comparison of two files someone staged by hand.

Decisions worth not re-litigating:

- **Workflow commands, not the Checks API.** No token, no network call, no failure
  mode where findings vanish because a request timed out.
- **`fail-on: breaking` fails on exit 2, 3 *and* 4.** A degraded comparison
  dropped findings; treating it as a pass is precisely the failure this tool
  exists to prevent.
- **A missing base snapshot passes.** The pull request that first adopts gattsnap
  must not be the one it blocks.
- **`fetch-depth: 0` is required** on `actions/checkout`, or the base commit is
  not in the runner's clone. This is the most likely setup failure.
- **`git config --global --add safe.directory`** is not optional in a Docker
  action; without it every `git show` fails with "dubious ownership".

`scripts/test-action.sh` covers all of this end to end — it builds the image,
stands up a throwaway repository whose branches differ the way a firmware pull
request differs, and asserts step exit codes and outputs across fourteen cases.
It exists because none of what breaks here is reachable from unit tests: the git
plumbing, the exit-code mapping, and whether annotation paths come out relative
to the workspace are all invisible until the container runs. It found a real bug
on its first run.

### Not built

- **Publishing to GitHub Marketplace**, which needs a public repository with a
  root `action.yml` and a tagged release.
- **The capture half of the Action.** Needs a self-hosted runner with a radio, and
  its shape depends on the platform decision in §8.

---

## 11. Commands

```bash
swift build && swift test                                    # macOS
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test   # Linux; run before committing Core changes
./scripts/test-action.sh                                     # end-to-end Action test; needs Docker

./scripts/build-app.sh                                       # signed gattsnap.app — required for capture
./gattsnap.app/Contents/MacOS/gattsnap scan [--seconds 8] [--all] [--format human|json]
./gattsnap.app/Contents/MacOS/gattsnap capture --name "<x>" --profile <label> --out snap.json

# diff needs no bundle and no radio — .build/debug/gattsnap is fine
gattsnap diff <base.json> <head.json> [--format human|json|junit|github|markdown]
    [--summary <path>] [--annotate-path <p>] [--diff-handles] [--fail-on-warning]

GATTSNAP_REGENERATE_FIXTURES=1 swift test --filter regenerateFixtureHashes   # after editing a fixture table

./spike/build.sh                                             # M1 spike
./spike/blespike.app/Contents/MacOS/blespike serve --variant a|b --disclaim   # mutable test peripheral
```

`--disclaim` is required for every `blespike` invocation from a shell; without it
TCC kills it with no stderr output.

---

## 12. Handoff — where to pick up

Everything through M5 is done and committed. Work paused here deliberately.

M5 was chosen over BlueZ for a product reason, not an engineering one: nobody
could evaluate gattsnap without a Mac, a signing identity and a BLE peripheral,
which is fatal for a tool that has to be try-able by a stranger. The diff half
needs none of those, and it is the half the value lives in.

### The test rig, and why it is worth having before either check

Both checks below need **a machine with a real BLE radio running BlueZ**. No
container or VM on the Mac provides one, which is the whole reason they are
blocked. Docker already covers "a Linux box" for building and testing; what is
missing is the radio.

**A Raspberry Pi 5 (8GB) running Ubuntu Server 24.04 LTS (arm64) is a good fit:**

- **8GB, not 4GB.** Swift compilation is memory-hungry, and native builds are
  what make D-Bus iteration bearable compared with cross-compiling and copying
  binaries over.
- **Ubuntu, not Raspberry Pi OS.** Swift.org publishes official *aarch64 Ubuntu*
  toolchains, and 24.04 matches the `swift:6.1-noble` container the Linux CI job
  already uses. Raspberry Pi OS is Debian-based and would probably work, but off
  the supported path for no benefit.
- The Pi 5 needs adequate power and active cooling — underpowering produces flaky
  USB and misleading failures, and it throttles hard under sustained compilation
  without cooling.
- The onboard Bluetooth is attached over UART and has a reputation for being less
  solid than a USB dongle under sustained BLE work. Fine for discovery and GATT
  reads. If it turns flaky during real capture runs, **a USB dongle is the first
  thing to swap**, not the code.

**The Pi is the "second machine" §5 has been waiting for.** A Mac cannot discover
its own advertisements, which is what has blocked the spike-peripheral work. With
the Pi, `blespike serve` runs on the Mac and the Pi observes it.

**Check 2 does not need the BlueZ adapter.** This is the part worth not
re-deriving: BlueZ exposes attribute handles through its D-Bus objects, so
`bluetoothctl` on the Pi can scan, connect and read the table with **no Swift
written at all**. The adapter is not a prerequisite for answering the question.
The same trip also opens up the caching 2×2, since BlueZ keeps its GATT cache as
readable files under `/var/lib/bluetooth/` where macOS's is TCC-protected.

**A quicker alternative for check 1:** a USB Bluetooth dongle passed through to a
Linux VM on the Mac (UTM is free) answers it without dedicated hardware. Pass
through the *external* dongle — macOS will not release the internal radio. Good
enough to find out whether `AdapterRegistry.declarations` is telling the truth;
not a substitute for the rig, and the adapter should not be built against it.

### Do these checks first

They could invalidate things this repo currently records as fact; doing adapter
work before them risks building on sand.

**1. Does BlueZ actually expose 0x1800/0x1801 and attribute handles? — ✅ YES,
verified 2026-08-10.**

`AdapterRegistry.declarations` claims a `bluez` v1 adapter observes handles, MAC,
GAP/GATT services and advertising parameters. MAC was already certain; the rest
was an assumption driving the cross-adapter degradation logic, the
`variant-a-bluez` fixture, and the argument that CI should run on Linux. **The
assumption held** — measured against a commercial BLE heart-rate monitor
(unbonded) on Ubuntu 24.04 with BlueZ, via `bluetoothctl` `menu gatt` /
`list-attributes` and `busctl tree org.bluez`:

- **Handles are exposed with no code and no private API.** Each D-Bus object name
  *is* the attribute handle in hex — `.../service0001/char0002/desc0013` — and
  `list-attributes` prints it ("Handle 0x0001"). This is the thing that is
  private-API and fragile on macOS (`GATTHandleProbe`); on BlueZ it is inherent to
  the object path.
- **0x1800/0x1801 are fully browsable, not filtered.** GAP appears as a primary
  service (Device Name 0x2A00, Appearance 0x2A01, Central Address Resolution) and
  GATT as another (Service Changed 0x2A05) — exactly the services CoreBluetooth
  hides. BlueZ does **not** consume them the way CoreBluetooth does, contrary to
  the prior "plausible" worry.

Consequences: the `bluez` registry entry is correct on `handles` and
`gap_gatt_services`; `variant-a-bluez` and the cross-adapter tests model a
scenario that genuinely occurs; and "Linux sees more of the table" is now measured
rather than asserted, including the 0x2A00 device-name rename that is unobservable
on Apple (see §8). Detail in [platform-notes.md §5](platform-notes.md).

Still not measured: the `advertising_parameters` capability (this was a
connect-and-browse, not an advertising-parameter capture), and — for the future
adapter — how to reconcile CoreBluetooth's *two* handles per characteristic
(declaration + value) against BlueZ's *one*. Read the `Handle` D-Bus property; do
not parse the object path.

**2. Does the spike peripheral land in the 0x1801-absent column?**

`CBPeripheralManager` cannot publish 0x1800/0x1801, so `blespike serve` should
produce a peripheral without a Generic Attribute Service — the untested cell of
the cache 2×2 (§5). Check whether its first service starts at handle **1** rather
than **10**. If it does, the existing rig is the right instrument for the
confound, and it is plausible it will show caching where the observed devices did
not.

Do this with `bluetoothctl` against `blespike serve` on the Mac, from the Linux
box. It needs neither `--include-handles` nor the BlueZ adapter — see the rig
notes above.

### Then

**BlueZ adapter.** The largest remaining piece and the only one that could still
surprise. Conform to `CaptureAdapter`, add a registry declaration, done — nothing
in `Model/`, `Serialization/` or `Diff/` should change; if it does, the boundary
leaked. The real work is D-Bus from Swift (`org.bluez`,
`GattService1`/`GattCharacteristic1`/`GattDescriptor1`), for which there is no
good binding — either a `systemLibrary` target over sd-bus or shelling out to
`busctl`.

Unlocks: no TCC, no MDM/PPPC, no `.app`, no signing. And BlueZ stores its GATT
cache as a **readable file** under `/var/lib/bluetooth/`, where macOS's is
TCC-protected — so the cache questions in §5 may be far easier to answer there.

Check 1 above is done: the registry's `handles` and `gap_gatt_services` claims for
`bluez` are confirmed, so the adapter can be built against them with confidence.

### Explicitly not started

- **The capture half of the Action** — needs a self-hosted runner with a radio,
  and its shape depends on the platform decision in §8. Building it before that
  decision means designing around macOS's permission model and then redoing it.
- **Marketplace publication** — needs a tagged release and a root `action.yml`.
