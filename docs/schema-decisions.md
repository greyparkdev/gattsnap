# Schema decisions

Architectural decisions taken at the M1→M2 checkpoint, with the reasoning, so
later milestones can tell a deliberate choice from an accident. Empirical basis
is in [platform-notes.md](platform-notes.md).

---

## Schema 1 compatibility — stored hashes and comparison order

The September 2026 duplicate-UUID fix uses handles to order same-UUID siblings
for comparison and for newly constructed snapshots. Schema 1's hash contract
predates that fix: it sorts by UUID (and primary status for services), retaining
stored order among ties. `StructureHash.compute` preserves those original rules
through `normalizedForSchemaV1Hash`; improvements to comparison matching must
not silently change validation of existing snapshots.

No schema bump or migration is required. Previously saved files retain their
recorded hash and round-trip unchanged. Newly constructed snapshots store the
improved order and remain valid schema-1 files. When an old and new snapshot
have different hashes solely because of repeated-UUID ordering, the diff reports
`quiet_hash_difference` with cause `stored_order_differs`, rather than a firmware
change or unexplained corruption. `--fail-on-warning` still applies.

`legacy-v1-duplicate-handles.json` was generated with Core at `fecf23a` and is an
immutable compatibility fixture, deliberately excluded from fixture regeneration.
Tests verify its original hash/bytes, comparison with newly ordered snapshots,
and rejection of changed data carrying the original hash.

---

## D1 — Attribute handles are opt-in at capture, opt-in at diff, and compiled out on iOS

Handles are readable on Apple platforms via declared-but-private ObjC properties
(platform-notes §2). They are used, but fenced three ways.

**Capture is opt-in** (`--include-handles`). Probed through the ObjC runtime so a
future macOS that drops the property degrades to "absent" rather than crashing.

**Isolation is compile-time, not runtime.** The probe lives in its own file,
excluded from iOS builds at the SwiftPM target level. A runtime guard would still
leave the private selector in the shipped binary; if `GATTCapture` is ever reused
by an iOS app going through TestFlight or App Review, the symbol must be *absent*,
not dormant. (M3 obligation — recorded here so it isn't rediscovered late.)

**Diff is opt-in** (`--diff-handles`), and off by default — but not because
handles are fragile. Because a handle shift is a **different breaking class** from
everything else in the taxonomy:

> A bonded client caches the attribute table by handle. If handles shift under a
> firmware update without a Service Changed indication, that client breaks in the
> field while a fresh re-discovery test passes completely clean.

That is precisely the bug this tool exists to catch, and no other method sees it.
So when `--diff-handles` is on, a shift classifies as **breaking** with its own
message naming bonded clients specifically, kept distinct from generic breaking
output. `.handleShift` is therefore its own `ChangeKind`, not a variant of
`.propertyRemoved`.

## D2 — Diff identity is the attribute table; the profile label is not load-bearing

Two things were being conflated.

**Diff identity** is the attribute table alone. The file's identity is its path in
the repo — the only answer that survives every change the tool is designed to
detect. `peripheral.identifier` cannot serve: it is a host-scoped UUID and two
Macs produce different values for the same peripheral (platform-notes §2).

**`capture_metadata`** holds advertised local name, DIS fields,
`peripheral.identifier`, host, timestamp, RSSI, adapter version — and is excluded
from the diff **by contract, not by convention**. The diff engine cannot see the
block at all: `DiffEngine.compare` takes `AttributeTable` and capabilities, and
has no parameter through which metadata could reach it. Enforced by the type
system, so a later edit can't quietly start diffing it.

**`--profile <label>`** is required at capture so the field is never empty, but it
is *not* the diff key. It is a human-assigned product label used for output
messages and sanity checks. On diff, mismatched labels **warn, never fail** — that
catches diffing the wrong two files without becoming load-bearing.

**`structure_hash`** is a SHA-256 over the canonically-sorted attribute table,
excluding all capture metadata. Gives CI a cheap "did anything change at all"
check without a full diff, and a fast equality assertion in tests.

Rejected: keying on advertised local name + service UUIDs, or on 0x180A. Both
derive identity from fields the tool is actively diffing, which is circular — a
local name change is supposed to classify as *cosmetic*, it cannot also silently
repoint identity. And 0x180A is optional, so it cannot be a universal key.

## D3 — Adapter capabilities, and suppression that is always visible

Each snapshot records the adapter's capability flags. The diff engine intersects
them and, where a range was unobservable on either side, reports it as a distinct
**`unobservable`** class — never as `removed`, and never as silence.

> A cross-adapter diff that quietly drops findings and prints "no changes" is the
> worst possible failure mode for this tool: the user reads a clean result and
> ships.

Output names what was excluded and why, e.g.
`0x1800/0x1801 not comparable: corebluetooth adapter cannot observe GAP/GATT services.`

Capabilities are **declared per adapter and versioned with the adapter**, not
stored as unobservable ranges inside the snapshot. If a future CoreBluetooth (or a
workaround) makes something observable, the adapter's declaration changes and old
snapshots stay honest about what they were captured with. One mechanism carries
D1's handle case and D3's GAP/GATT case.

Rejected: hardcoding a 0x1800/0x1801 exclusion (silently misclassifies, doesn't
generalize) and normalizing them away on load (discards data a BlueZ capture
legitimately observed, on the platform that sees the most).

### Exit codes

`0` clean · `1` additive or cosmetic only · `2` breaking · **`3` degraded** — one
or more attribute ranges were unobservable on at least one side. CI can fail on a
degraded comparison, and must never mistake it for a pass.

---

## D4 — When `structure_hash` and the diff disagree, say why

`structure_hash` is sold to CI as the cheap "did anything change at all" check
(D2). Handles participate in it, so a snapshot pair whose handles shifted hashes
differently — while the default diff, which does not compare handles, correctly
reports nothing. CI's fast path then says "changed" and the full diff says
"clean", and the tool undermines its own signal.

The verdict does not change: opting out of `--diff-handles` means opting out of
those findings, and exit `0` is right. Instead the report carries a
`unexplained_hash_difference` warning naming the actual cause:

> structure_hash differs between these snapshots, but no changes are reported at
> this diff level: both snapshots record attribute handles and `--diff-handles`
> is off — re-run with `--diff-handles` to compare them.

The condition generalizes past handles: a suppressed GAP/GATT range (D3) also
makes hashes diverge while the diff stays quiet, and is named as a cause in the
same way. `--diff-handles` is only suggested when *both* snapshots carry handles,
since otherwise enabling it would degrade the run rather than explain anything.

If no cause can be determined the warning says so and asks for a bug report —
that combination should be unreachable and is worth hearing about.

Rejected: dropping handles from `structure_hash` (the cheap check would stop
catching handle shifts, the case D1 exists for) and emitting a second
`handles_hash` (more schema surface for a problem a sentence solves).

## D5 — `--fail-on-warning`, and exit `4`

CI reads exit codes and swallows stdout, so a well-written warning is invisible
exactly where it matters most. `--fail-on-warning` promotes warnings into the
verdict for teams that want it, without making a profile mismatch or a quiet hash
difference a failure for everyone.

It gets its own exit code, **`4`**, rather than reusing `3`. A profile mismatch is
not an unobservable attribute range, and folding it into `3` would make that code
mean two unrelated things. Full precedence, ordered by how much a reader should
worry rather than numerically:

```
breaking (2) > degraded (3) > warnings under --fail-on-warning (4) > additive/cosmetic (1) > clean (0)
```

**M4 obligation:** JUnit XML must emit warnings as a visible element, not as prose
buried in a `message` body, for the same reason the flag exists.

## D6 — `quiet_hash_difference` causes

Renamed from `unexplained_hash_difference`: both real cases have a *determined*
cause, and only the third is genuinely unexplained. The distinction gives M4 its
rendering split and makes the unreachable branch read as a bug rather than a
category.

| cause | meaning | remedy |
|---|---|---|
| `handles_not_diffed` | both snapshots carry handles, `--diff-handles` is off | re-run with `--diff-handles` |
| `adapter_capability_gap` | findings dropped from a range the adapters cannot both observe | inherent; accompanied by exit `3` |
| `capture_options_differ` | same adapter, different capture flags | re-capture both the same way |
| `undetermined` | should be unreachable | file a bug |

`capture_options_differ` was **not** in the original three. It was found by
running M3 against real hardware: capturing a device once without
`--include-handles` and once with produced `undetermined` — i.e. the tool told a
user to file a bug for an ordinary workflow. It is kept separate from
`adapter_capability_gap` because the remedies differ, and it only fires when both
snapshots come from the *same* adapter; across different adapters the difference
is inherent and "re-capture the same way" would be nonsense advice.

## Consequences taken during M2

These follow from D1–D3 but were not explicitly specified; flagged for review.

- **Precedence when a diff is both breaking and degraded → exit `2`.** Breaking is
  the headline and CI fails either way; the degraded section is still reported in
  full. The invariant that matters is that degraded never collapses to `0` or `1`,
  and it doesn't.
- **Recorded capabilities are adapter declaration ∩ capture options.** With
  `--include-handles` off, a CoreBluetooth capture records `handles: false` even
  though the adapter *can* read them. Otherwise a diff cannot distinguish "not
  captured" from "unchanged" — the exact confusion D1 asks to avoid. Core
  validates recorded capabilities are a subset of the registry declaration for
  that adapter and version.
- **Characteristic values are diffed only for the 0x180A allowlist**, classified
  cosmetic. General characteristic values are runtime state, not table structure,
  and diffing them would make every snapshot dirty. This is how "manufacturer
  string" from the cosmetic tier is actually detected.
- **Descriptor values are recorded but never diffed.** CCCD value is per-connection
  state; the severity spec cares about descriptor *presence* ("descriptor removed,
  CCCD gone"), which is diffed.
- **Device name and advertising interval are `unobservable` on CoreBluetooth**, not
  cosmetic-clean. 0x2A00 lives in GAP 0x1800, which CoreBluetooth hides, and
  advertising interval needs the raw PDU. They flow through D3 rather than being
  silently absent from the cosmetic tier.
- **Duplicate UUIDs are matched by `(uuid, instance)`**, where `instance` is the
  ordinal among same-UUID siblings in canonical order. Without handles there is no
  stronger identity available. Known limitation: reordering two same-UUID siblings
  is invisible to the diff.
