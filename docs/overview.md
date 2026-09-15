# gattsnap — what it is and why it exists

*Written for anyone who wants to understand the product without reading code.
The engineering detail lives in [project-state.md](project-state.md).*

---

## The problem in one paragraph

A Bluetooth device — a fitness tracker, a smart lock, a medical sensor, an
industrial gauge — advertises a menu of everything it can do. Which readings it
offers, which settings you can change, which alerts it can push to your phone.
Phone apps are written against that menu. When a firmware update quietly changes
the menu, every app already installed on every customer's phone starts talking to
a device that no longer answers the way it used to.

The failure is silent, and the timing is the worst part: firmware ships, then
breaks apps in the field, on phones the firmware team does not control and cannot
update.

## What gattsnap does

It takes a snapshot of that menu and writes it to a small text file, which the
firmware team commits to their code repository alongside the firmware itself.

From then on, any change to the menu shows up as a change to that file — in the
pull request, next to the code that caused it, before it ships. The reviewer sees
it the same way they'd see any other change.

And gattsnap doesn't just show *that* something changed. It says how much it
matters:

| | | |
|---|---|---|
| 🔴 **Breaking** | something apps depend on disappeared | a reading is gone; an alert can no longer be subscribed to |
| 🟡 **Additive** | something new was added | a new reading is available; old apps are unaffected |
| ⚪️ **Cosmetic** | a label changed | the manufacturer name string was updated |

Then it exits with a code the automated build system understands, so a breaking
change can *stop the build* rather than being something a reviewer has to spot.

## Who it's for

Firmware teams building Bluetooth Low Energy products who also ship — or whose
customers ship — a phone app against them.

Concretely that means consumer wearables and health devices, smart-home and
access-control hardware, medical and industrial sensors, and the contract
development shops that build for all of them. The common shape is: the firmware
and the app are built by different people, on different schedules, and the app is
already on phones you can't reach.

**The pain scales with how far away your users are.** A team whose app and
firmware ship together on the same day has a manageable problem. A team with
200,000 devices in the field and an app store review queue between them and a fix
has an expensive one.

### Why this isn't already solved

There is no shortage of Bluetooth debugging tools. They are all *interactive* —
you connect, you look, you decide whether it seems right. That works when a human
is watching, and fails at exactly the moment it matters: a routine firmware change
that nobody thought to check.

Existing tools answer *"what does this device look like right now?"*
gattsnap answers **"what changed since last time, and does it matter?"** — which
is the question a code review asks, and the only one an automated build can act
on.

## How it works, in three steps

**1. Capture.** Point it at a device. It connects, walks the device's entire
menu, and writes it to a file.

```
gattsnap capture --name "acme-sensor" --profile acme-sensor-v2 --out gatt.json
```

**2. Commit.** The file goes into the repository like any other source file.

**3. Compare.** On every change, capture again and compare against the committed
file. Identical means nothing changed. Different means the build shows exactly
what, and how much it matters.

The file itself is deliberately boring: plain text, in a format any programming
language can read, with everything in a fixed order so the same device always
produces a byte-for-byte identical file. That last property is what makes the
whole thing work — if the file wobbled between captures, every comparison would be
noise and the team would stop reading them.

## What makes it trustworthy

A tool like this is only worth having if a clean result actually means "nothing
changed." Three design commitments protect that, and they cost real effort:

**It refuses rather than guesses.** Apple's Bluetooth stack sometimes hands back a
*remembered* copy of a device's menu instead of reading the real one. A tool that
accepted that would happily report "no changes" for a device that had changed
completely — the worst possible outcome. gattsnap measures how long the read took
and, if it's implausibly fast, refuses to write a file at all. It would rather
fail loudly than give you a green light it can't stand behind.

**It never hides what it couldn't see.** Every platform has blind spots — Apple's
Bluetooth stack cannot see certain parts of the menu at all. When a comparison
can't cover something, gattsnap says so explicitly, as its own category, with its
own build exit code. A tool that silently skipped what it couldn't check and
printed "no changes" would be actively dangerous: the user reads a clean result
and ships.

**It catches a class of bug nothing else does.** When apps stay permanently paired
to a device, they memorise the *positions* of items in the menu, not just their
names. A firmware update can leave every item present and correct while shifting
their positions — and every paired app in the field breaks, while a fresh test on
a developer's desk passes perfectly clean. gattsnap can detect this and flags it
with an explanation of who it breaks. As far as we know, no other tool sees it.

## Where it is today

Working and tested against real hardware. It captures devices and produces
correct, reproducible files, and the comparison engine handles every severity
case with 80 automated tests behind it.

The remaining work is the finishing layer: the compare command's various output
formats, documentation, and packaging for automated build systems.

**Two open risks**, both known and neither hidden:

- One device configuration (permanently-paired devices) hasn't been verified yet.
  Hardware is being sourced. The tool is deliberately not designed around an
  assumption in either direction.
- Apple requires a human to click "Allow" the first time the tool uses Bluetooth
  on a machine. On an unattended build server there is nobody to click. There is a
  standard corporate-IT mechanism for pre-approving this, but it means gattsnap's
  headline use case needs an IT step on Macs. This is a genuine adoption cost and
  it is the main open strategic question.

## Where it's going

**Near term** — finish the compare command, write the documentation, ship the
build-system integration.

**Then, and this is the interesting one:** the Linux version. The capture tool is
built so a Linux backend drops in without touching anything else, and the
comparison engine already runs on Linux today. Linux is where automated build
servers actually live, it has none of Apple's permission problem, and it can see
*more* of the device menu than Apple can. The architecture was shaped around this
from the first day precisely so that the choice of whether to go there first stays
open.

**Longer term**, the snapshot file is the real asset. Once a machine-readable,
version-controlled description of a device's interface exists, other things become
possible on top of it: generating app code from it, generating documentation,
tracking a device's interface across its whole product lifetime. Those are
deliberately not being built yet — the file format has to prove itself first.

## The one-sentence version

**A device's Bluetooth interface is a contract with every app already installed on
every customer's phone. gattsnap makes that contract a file in your repository, so
breaking it becomes something you review on a Tuesday instead of something you
discover from support tickets.**
