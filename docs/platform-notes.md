# Platform notes — CoreBluetooth capture on macOS

Findings from the M1 hardware spike. Everything below was measured, not assumed;
where something was *not* measured it says so explicitly.

**Test rig:** MacBook Pro, Apple silicon, BCM_4387 controller, macOS 26.2 (25C56),
Xcode 26.6, Swift 6.3.3. Spike code in [`spike/`](../spike).

The probe commands (`perm`, `scan`, `dump`, `cache`, `btcycle`) are throwaway —
they exist to produce this document. `serve` is **not**: it is retained as the
M2 fixture generator and the integration-test peripheral for M3.

---

## 1. The macOS CLI Bluetooth permission problem

**Conclusion: use an `.app` wrapper *and* self-disclaim the process. The commonly
cited linker trick alone does not work.**

### What does not work: `-sectcreate __TEXT __info_plist`

Embedding an `Info.plist` into a bare Mach-O with

```
-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
```

is the standard advice for CLI tools that need a usage-description string. It is
insufficient here, and it fails in a way that actively misleads you.

The section lands correctly and is genuinely readable at runtime:

- `otool -P` shows `NSBluetoothAlwaysUsageDescription` present
- `codesign -dvvv` reports `Info.plist entries=7` — it is *sealed into the signature*
- `Bundle.main.infoDictionary` reads the key back inside the running process
- `Bundle.main.bundleIdentifier` resolves to `dev.gattsnap.blespike`

And the process is still killed on `CBCentralManager` init:

```
termination: { "namespace": "TCC", "details": [
  "This app has crashed because it attempted to access privacy-sensitive data
   without a usage description. The app's Info.plist must contain an
   NSBluetoothAlwaysUsageDescription key ..." ]}
exception: { "type": "EXC_CRASH", "signal": "SIGABRT" }
```

Exit status 134. Note there is **no message on stderr** — the only way to see the
reason is the `.ips` crash report in `~/Library/Logs/DiagnosticReports/`.

### Why it fails: TCC bills the *responsible process*, not your binary

The crash report's `responsibleProc` field is the whole story:

```
procPath:        .../blespike.app/Contents/MacOS/blespike
codeSigningID:   dev.gattsnap.blespike
responsibleProc: claude          <-- the process TCC actually evaluated
```

TCC attributes a privacy request to the **responsible process** of the process
tree — for a CLI that is `Terminal.app`, `iTerm2`, `sshd`, a CI runner, or (here)
whatever spawned the shell. It reads *that* process's `Info.plist` and *that*
process's grant. Your own binary's usage description is never consulted.

The error message says "the app's Info.plist" and means the responsible app's,
which is why this burns so much time. Wrapping in an `.app` alone does **not**
fix it — a `.app` bundle launched from a shell inherits the shell's responsible
process and dies identically (verified).

This also explains the folklore that "it works from Terminal": it does, because
Terminal.app ships `NSBluetoothAlwaysUsageDescription` and holds the grant, and
every CLI beneath it free-rides on that. The grant is recorded against
*Terminal*, not your tool.

### What works: disclaim responsibility

`responsibility_spawnattrs_setdisclaim` (libSystem SPI, used by browser
updaters and launchd) makes a spawned child its own responsible process. The
tool re-execs itself once through `posix_spawn` with that attribute set, and TCC
then evaluates the child's own bundle identity and usage description:

```
disclaim: responsibility_spawnattrs_setdisclaim -> 0
state -> poweredOn  (authorization = allowedAlways)
```

Implementation: [`spike/Sources/blespike/Disclaim.swift`](../spike/Sources/blespike/Disclaim.swift).
`posix_spawn` inherits fds, so stdio passes through and the parent just
`waitpid`s and forwards the child's exit code. Re-exec costs ~10 ms.

The `.app` wrapper is still required — TCC resolves the identity from the
containing bundle, so the executable must sit at
`Foo.app/Contents/MacOS/foo` with a real `Info.plist` beside it. Both pieces are
needed; neither alone is sufficient.

### Signing: get a real identity

| Signature | Result |
|---|---|
| Ad-hoc (`--sign -`) | Never reached `poweredOn`; stuck at `notDetermined`, no visible prompt |
| Apple Development (team `9WN49B522B`) | `allowedAlways`, and **survives rebuilds** |

Verified durability explicitly: changed `CFBundleVersion`, re-signed, confirmed a
new `CDHash` (`b3e4c505…` vs `9556ed97…`), re-ran — still `allowedAlways`. TCC keys
on the designated requirement (bundle id + team id), not the cdhash, so a signed
tool prompts once and never again. Ad-hoc has no stable identity, which is
presumably why it stalls.

**Recommendation for `gattsnap`:** ship as a signed `.app` wrapper with a thin
`gattsnap` shim on `PATH`; self-disclaim on every run. Fail with an explicit
message if `CBManager.authorization != .allowedAlways` after ~2 s rather than
hanging.

### Open item for M4/CI

First grant needs a human click; there is no CLI to pre-authorize. On a headless
CI runner this needs an **MDM-deployed PPPC profile** granting
`kTCCServiceBluetoothAlways` to the bundle id + team id. Since "run this in CI"
is the product's entire premise, this belongs in the README and probably wants
verifying on a real runner before M4 ships.

Caveat, stated plainly: I could not read `TCC.db` (needs Full Disk Access) and no
prompt was observed on screen during the successful grant, so I cannot say
whether the Developer-signed grant came from a dialog you clicked or was granted
another way. Worth 30 seconds of confirmation on a clean machine.

---

## 2. What is and isn't reachable

Measured against two BLE devices running identical firmware — their identical
structure fingerprints are a nice sanity check on the fingerprinting itself.

### Attribute handles — **available**, contrary to the usual assumption

This is the finding that should change the schema design. CoreBluetooth's model
classes declare handles as real ObjC **properties** (not merely ivars), so plain
KVC reads them — no `dlsym`, no swizzling:

| Class | Handle-bearing members |
|---|---|
| `CBService` | `startHandle`, `endHandle` |
| `CBCharacteristic` | `handle`, `valueHandle` |
| `CBDescriptor` | `handle` |

Real values from a live capture:

```
180A / 2A29  [read]                      handle=11, valueHandle=12
180A / 2A24  [read]                      handle=13, valueHandle=14
D0611E78-… / 8667556C-…  [write|notify]  handle=16, valueHandle=17
9FA480E0-… / AF0BADB1-…  [write|notify]  handle=21, valueHandle=22
```

They are consistent and correct — contiguous, ordered, and the declaration/value
handle pairs are exactly one apart as the spec requires.

**But they are private API.** Not in any public header, and a silent behaviour
change in a future macOS would corrupt snapshots rather than fail loudly. My
recommendation, which I'd like your call on before M2 freezes the schema:

- keep `handles` **optional in the schema** exactly as you planned, but populate
  them on macOS behind an explicit opt-in flag (`--include-handles`)
- probe via the ObjC runtime (`class_copyPropertyList`) and only KVC a key that
  actually exists, so a future macOS that drops the property degrades to "absent"
  instead of crashing — this is what the spike does
  ([`Introspect.swift`](../spike/Sources/blespike/Introspect.swift))
- **never diff on handles by default.** Handles legitimately shift when a table
  changes and would fire on every additive change; they're diagnostic detail, not
  identity

### MAC address — **not available**

`CBPeripheral` declares `BDAddress` (and `_BDAddress`), which looks promising. It
returns **nil** on a live connection. Same for `stableIdentifier`. So the field
stays optional-and-absent on Apple platforms, as you designed.

`peripheral.identifier` is a **host-scoped UUID**, not a device identity: it is
derived per-Mac and two machines produce different UUIDs for the same physical
peripheral. It must not be the snapshot's identity key or committed snapshots
won't match across developers' machines. This needs a real answer in M2.

### Raw advertising PDU — **not available**

Only the parsed `advertisementData` dictionary. Three undocumented keys show up
consistently and are worth knowing about:

```
kCBAdvDataRxPrimaryPHY      1 or 129   (129 = LE Coded/2M secondary)
kCBAdvDataRxSecondaryPHY    0
kCBAdvDataTimestamp         807774475.949205  (CFAbsoluteTime)
```

Plus the documented `kCBAdvDataIsConnectable`, `LocalName`, `ManufacturerData`,
`ServiceUUIDs`, `ServiceData`, `TxPowerLevel`. `kCBAdvDataTimestamp` is
capture-time-varying and **must be excluded from snapshots** or every capture
diffs dirty.

### Descriptor values — **available and readable**

`readValue(for: CBDescriptor)` works, including on unbonded links:

```
desc AF0BADB1-…/2900 = num 1     Characteristic Extended Properties
desc AF0BADB1-…/2902 = num 0     CCCD
```

Schema note: descriptor values come back **type-varying** — `NSNumber` for 0x2900
and 0x2902, `NSString` for 0x2901, `NSData` for others. Serialization must
normalize these to a single canonical representation (I'd suggest hex bytes) or
the same descriptor will encode differently across platforms and break the BlueZ
adapter later.

### 0x1800 and 0x1801 are filtered out — **important**

Observed CoreBluetooth discovery omitted both GAP (0x1800) and GATT (0x1801).
CoreBluetooth handles those services internally and hides them. Device-specific
captures and handle layouts are intentionally not retained in this repository.

Handle order may differ from snapshot order: the canonical form sorts by UUID
for stable diffs, while handles record physical layout.

Consequences:
- The snapshot can never contain GAP/GATT service entries on Apple platforms, but
  a BlueZ capture *will* see them. **The diff engine must not report 0x1800/0x1801
  as "removed" when comparing an Apple snapshot against a BlueZ one.** This is a
  concrete cross-platform trap and argues for recording the capture platform's
  known blind spots in the snapshot itself, not just the adapter name.
- You cannot subscribe to Service Changed (0x2A05) from CoreBluetooth. It is not
  an available cache-busting lever at the API level.

---

## 3. Does CoreBluetooth return a stale cached service table?

**For unbonded peripherals: no. Every fresh connection re-discovers over the air.**

Timing is a clean instrument here because a CoreBluetooth cache hit is not merely
fast, it is *free*. Calling `discoverServices(nil)` a second time on an already
open connection is served from memory and gives the calibration baseline:

| Measurement | Time |
|---|---|
| discovery #2, same live connection (definitionally cached) | **0.0 ms** |
| discovery #1, after fresh connect, round 1 | 469 ms |
| discovery #1, after fresh connect, round 2 | 439 ms |
| discovery #1, after fresh connect, round 3 | 439 ms |
| discovery #1, fresh **process** | 471 ms |

Three orders of magnitude. Every reconnect pays the full ~450 ms of real ATT
traffic, including from a brand-new process, so there is no per-process *or*
system-wide fast path being taken. Structure fingerprints were identical across
all rounds, which is the expected result when the peripheral hasn't changed.

This matches the spec: persistent GATT caching is only permitted for **bonded**
peripherals. The device under test reported `isLinkEncrypted = 0` and
`pairingState = 0` — definitively unbonded — so this result covers the unbonded
case only.

### What this does not yet establish

Three gaps I'd rather flag than paper over:

1. **Bonded peripherals.** This is exactly where the spec *allows* persistent
   caching, so it is the case most likely to bite. Untested — I had no bondable
   peripheral I could pair and mutate.
2. **An actual structural mutation.** The above is inferred from timing on a
   *static* table. Strong inference — 450 ms of ATT traffic can't return stale
   data — but not the same as watching a real change propagate.
3. 🔴 **The experiment is confounded: bonding may not be the operative variable
   at all.**

#### The confound

Vendor literature (Punch Through, *Attribute Caching In BLE*) reports that iOS and
macOS **do not cache the attribute table when the Generic Attribute Service
(0x1801) is present on the peripheral.** That is a different explanation for the
same measurement.

The devices used for the timing experiment appeared to implement it, but
CoreBluetooth filters 0x1800/0x1801 out of discovery. The raw device-specific
captures and handle evidence are intentionally not retained here. Consequently,
the devices were **unbonded *and* appeared to have 0x1801 present**, and the "no
stale cache" result is equally consistent with either cause:

- *bonding is the variable* → bonded peripherals are the risk
- *0x1801 presence is the variable* → **peripherals lacking 0x1801 are the risk,
  bonded or not**

These have materially different consequences. Under the second reading the
exposure is wider — an unbonded peripheral without a Generic Attribute Service
could serve a stale table — and the at-risk population is identifiable in advance,
because a peripheral either implements 0x1801 or it does not.

#### What the experiment has to become

Not "bonded vs unbonded" but a 2×2:

|  | 0x1801 present | 0x1801 absent |
|---|---|---|
| **unbonded** | ✅ measured, no caching | ❓ untested |
| **bonded** | ❓ untested | ❓ untested |

Only one cell has data.

A useful accident: `CBPeripheralManager` does not permit publishing 0x1800/0x1801
— they are reserved and the stack owns them — so a peripheral created by
`spike/blespike serve` almost certainly lands in the **0x1801-absent** column.
That makes the existing test rig the right tool for the untested row rather than
merely a convenience, and it is plausible the spike peripheral would show caching
where the observed devices did not. Confirm by capturing it with `--include-handles`
and checking whether its first service starts at handle 1.

Until that runs, treat the 10 ms threshold as validated for *one* cell of the
matrix. It does not need re-tuning on this basis — a cache hit is 0 ms under any
explanation — but the claim about *which peripherals are at risk* is not
established.
[`spike/Sources/blespike/Serve.swift`](../spike/Sources/blespike/Serve.swift)
publishes a controlled, mutable GATT table via `CBPeripheralManager` in two
variants:

- **A** → service AAAA {A1 `read|notify`, A2 `write`}
- **B** → service AAAA {A1 `read`, A3 `read|write`} + service BBBB {B1 `read`}

B differs from A by one dropped property, one removed characteristic, one added
characteristic and one added service — i.e. it exercises breaking *and* additive
classification in a single mutation, which makes it reusable as an M2 fixture
source.

A Mac cannot discover its own advertisements, so this needs a second machine:

```bash
# on machine 2
./spike/build.sh && ./spike/blespike.app/Contents/MacOS/blespike serve --variant a --disclaim

# on machine 1
./spike/blespike.app/Contents/MacOS/blespike cache --name gattsnap-spike --rounds 3 --disclaim
# then restart machine 2 with --variant b and re-run, comparing fingerprints
```

### Cache-busting levers, ranked

Given no caching was observed for unbonded devices, this is provisional and
ordered by expected reliability rather than by measurement:

1. **Full disconnect + reconnect** — measured, always re-discovers (unbonded)
2. **Bluetooth power cycle** — `IOBluetoothPreferenceSetControllerPowerState`
   works from a CLI without sudo and is wired up as `blespike btcycle`. I did
   **not** run it: it drops the machine's active audio/HID links, and with no
   caching to bust it had no diagnostic value today. Available when the bonded
   case gets tested.
3. **Unpair / forget device** — the documented remedy for a stale bonded cache
4. **Service Changed (0x2A05)** — **unavailable**, see §2; the stack consumes it
5. **Reboot** — last resort, useless in CI

**Recommendation for M3:** always disconnect fully between captures, never reuse
a live connection, and record `mtuLength` plus the measured discovery duration in
the capture metadata. A capture that completes suspiciously fast (< ~50 ms for a
non-trivial table) is the signature of a cache hit and should refuse to emit a
snapshot rather than vouch for one it didn't actually read off the air. That
gives you the "fail loudly" behaviour you asked for, driven by a real signal.

⚠️ **That threshold is calibrated on the unbonded path only.** The 0 ms / ~450 ms
split was measured against an unbonded peripheral, which is the case where
caching is *not* permitted. A bonded device may legitimately re-discover on a
different timing curve, and a heuristic tuned to the easy case would either
false-positive on every bonded capture or, worse, silently pass a genuinely
stale one.

### Status as shipped in M3

M3 sets the threshold to **10 ms** (`CacheDetectionPolicy.measured`). The basis is
the three-orders-of-magnitude gap above: any value in the 5–50 ms band separates
the two populations, so 10 ms is a round number in the middle of that band rather
than a tuned value.

### Threshold calibration caveat

Later testing against a smaller attribute table narrowed the empirical margin
over the 10 ms threshold. Device-specific service counts, radio measurements,
timings and captures are intentionally not retained here.

The stronger argument for the current threshold is physical rather than a fit to
one device: **sub-10 ms discovery is not achievable over the air.** BLE's minimum
connection interval is 7.5 ms, typical intervals are longer, and ATT discovery
needs several round trips regardless of table size. The heuristic remains
provisional until the bonded/cache matrix below is measured with non-confidential
test hardware.

**The bonded case remains unverified.** It is not designed around in either
direction: the threshold is a plain configurable value, the code says so at every
point it is used (`CacheDetectionPolicy`, `CaptureError.suspectedCachedTable`),
and nothing in the adapter assumes bonded devices behave like unbonded ones.
Closing it needs a bondable peripheral that can mutate its table; hardware is
being sourced. When it lands, re-measure and revisit the 10 ms figure before
trusting it for bonded captures.

If the threshold is ever unset, cache detection is **disabled**, and both the
library (`CacheDetectionPolicy.disabledWarning`) and the CLI say so loudly. It
never silently defaults to a passing check — an unset safety threshold that
quietly becomes a pass is the same failure class as reporting a blind spot as a
fact.

---

## 4. Incidental findings worth keeping

- **`mtuLength` is readable** (23 on the test device — no MTU exchange happened).
  Useful capture metadata, but it is a *negotiated link* property, not a property
  of the attribute table, so it belongs in metadata and must not participate in
  the diff.
- **`peripheral.name` is system-cached, not from the current advertisement.**
  An OS-cached name resolved to a value that was absent from the live advertising packet.
  If device name is going to be a `cosmetic` diff input, capture it from
  `kCBAdvDataLocalName` (what's on the air) rather than `peripheral.name` (what
  the OS remembers), or a rename will silently fail to show up in the diff.
- **Not every advertiser is connectable.** 27 peripherals were in range; several
  advertised `kCBAdvDataIsConnectable = 0`. `gattsnap capture` should reject a
  non-connectable match immediately with a clear message.
- **Connection can hang indefinitely with no callback.** A third-party device matched,
  `connect` was called, and neither `didConnect` nor `didFailToConnect` ever
  fired. CoreBluetooth has no connection timeout — **you must implement one** or
  `gattsnap capture` will hang forever in CI.
- **`peripheral.attributes` exists but is an empty dictionary** — not a shortcut
  to the hidden 0x1800/0x1801 entries.
- No `PacketLogger` and no `blueutil` on this machine; `/Library/Bluetooth/`
  (the paired-device/cache store) is TCC-protected and unreadable without
  Full Disk Access, so on-disk cache inspection was not possible.

---

## 5. Linux / BlueZ — first empirical check

**Rig:** an Intel/AMD desktop booted from an Ubuntu 24.04 (noble) live USB, with a
MediaTek BT 5.4 controller (`hci0`, powered, roles central *and* peripheral). This
is the "second machine with a real radio" the rest of this repo has been blocked
on — a Mac cannot provide one. It answered check 1 of
[project-state.md §12](project-state.md) with **no Swift and no BlueZ adapter**:
`bluetoothctl` connects and browses, and `busctl tree org.bluez` exposes the whole
attribute table over D-Bus.

Measured against a **commercial BLE heart-rate monitor, unbonded** (device
specifics deliberately not retained, per the repo's privacy stance — only standard
SIG UUIDs are recorded below).

### Handles — **exposed, and inherent to the D-Bus model**

BlueZ names every GATT D-Bus object by its attribute handle in hex:

```
/org/bluez/hci0/dev_XX/service0001                       handle 0x0001
/org/bluez/hci0/dev_XX/service0001/char0002              handle 0x0002
/org/bluez/hci0/dev_XX/service0010/char0011/desc0013     handle 0x0013
```

`bluetoothctl` → `menu gatt` → `list-attributes` prints the same handles
explicitly ("Handle 0x0001", …). So on Linux, handles need neither a private-API
probe nor an opt-in flag — they are always present. This is the opposite of the
macOS situation, where handles are private ObjC properties isolated in
`GATTHandleProbe` (§2 above) and gated behind `--include-handles`.

⚠️ **One asymmetry the future BlueZ adapter must decide deliberately.**
CoreBluetooth exposes *two* handles per characteristic — a declaration `handle`
and a `valueHandle`. BlueZ's object path exposes *one* per characteristic. Read
BlueZ's `Handle` D-Bus property rather than parsing the object-path suffix, and
pin down which handle it corresponds to before cross-adapter handle diffing
(`--diff-handles`) is trusted across a CoreBluetooth↔BlueZ pair.

### 0x1800 / 0x1801 — **fully browsable, NOT filtered**

This is the finding that could have gone the other way. §2 records that
CoreBluetooth filters GAP (0x1800) and GATT (0x1801) out of discovery entirely,
and [project-state.md §12](project-state.md) flagged it as *plausible* that BlueZ
does the same, since it too consumes these services internally (device name and
appearance surface as `Device1` properties; Service Changed is handled by the
stack). **It does not.** Both appear as ordinary primary services:

- **0x1800 Generic Access Profile** — Device Name (0x2A00), Appearance (0x2A01),
  Central Address Resolution (0x2AA6)
- **0x1801 Generic Attribute Profile** — Service Changed (0x2A05) + its CCCD

Consequences for the codebase:

- `AdapterRegistry`'s `bluez` declaration is **correct** on `handles` and
  `gap_gatt_services` (MAC was already certain). Nothing to fix.
- The `variant-a-bluez` fixture and the cross-adapter degradation tests model a
  scenario that **genuinely occurs**: a BlueZ snapshot sees 0x1800/0x1801 that a
  CoreBluetooth snapshot structurally cannot — exactly what the
  `suppressed_comparison` vs `standing_limitation` split (project-state §6) exists
  to handle.
- "Linux sees more of the table" is now measured, not asserted — including the
  **0x2A00 device-name rename** that is unobservable on Apple (§2; project-state
  §8 known gap).

### On-disk GATT cache — **readable, and written even for an unbonded device**

Unlike macOS's TCC-protected `/Library/Bluetooth/` (§4), BlueZ stores its GATT
cache as **plaintext files** under `/var/lib/bluetooth/<adapter-mac>/cache/`, one
per remote device, named by the device MAC. Confirmed present for the *unbonded*
heart-rate monitor above — a ~1.9 KB file holding its full attribute table —
alongside 22–34-byte stubs for devices that were only seen in advertising. This is
BlueZ's default `[GATT] Cache = always` policy, which caches (and can serve) even
unbonded peripherals.

Two things follow:

- **The cache-inspection instrument the 2×2 (§3, project-state §5) has been missing
  now exists, and needs no bonding to use.** The file can be read, diffed against a
  fresh over-the-air discovery, or deleted to force a re-read — none of which is
  possible on macOS.
- **The future BlueZ adapter needs its own cache-busting story.** Because BlueZ
  caches unbonded GATT by default, a capture could vouch for a stale table exactly
  as the macOS concern in §3 describes. The Linux levers are inspectable and
  concrete: delete the per-device cache file, or set `Cache = no` in
  `/etc/bluetooth/main.conf`.

> Access gotcha: `/var/lib/bluetooth/` is `root`-only (`drwx------`), so a shell
> glob like `sudo ls /var/lib/bluetooth/*/cache/` **fails** — the non-root shell
> expands the `*` before `sudo` runs and cannot stat inside. Use an explicit path
> or `sudo ls -laR /var/lib/bluetooth/`.

A live USB without a persistence partition loses all of this on reboot, so the
bonded/unbonded cache matrix wants a persistent stick or a real install.

### Not yet measured on Linux

- Whether BlueZ actually *serves* the stale cache on reconnect (the presence of a
  cache file shows storage, not that a reconnect skips the air) — and how that
  differs across bonded/unbonded and mutation. This is the Linux side of the §3
  cache 2×2.
- The `advertising_parameters` capability — this was a connect-and-browse, not an
  advertising-parameter capture.
- Check 2 (does `blespike serve` land in the 0x1801-absent column) — needs the Mac
  serving and the Linux box observing.

---

## Spike usage

```bash
./spike/build.sh                     # build + sign the .app wrapper
B=./spike/blespike.app/Contents/MacOS/blespike

$B perm 3 --disclaim                 # permission / authorization probe
$B scan 10 --disclaim                # enumerate advertisers + adv-data keys
$B dump  --name "<device name>" --disclaim         # full attribute table + handle probe
$B cache --name "<device name>" --rounds 3 --disclaim   # cache timing across reconnects
$B serve --variant a|b --disclaim    # publish a mutable GATT table (needs 2nd Mac)
$B btcycle 4                         # Bluetooth power cycle (disruptive; untested)
```

`--disclaim` is required whenever running from a shell. Without it the process is
SIGABRT'd by TCC with no stderr output.
