# Security Policy

gattsnap is experimental software, provided under the [Apache-2.0](LICENSE)
license with no warranty. That said, security reports are taken seriously and are
appreciated.

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability.**

Report it privately through GitHub's private vulnerability reporting: open the
repository's **Security** tab and choose **Report a vulnerability**. This creates
a private advisory visible only to the maintainers and you.

Please include:

- what the issue is and the impact you see,
- the version or commit you tested,
- your OS and Swift toolchain version,
- steps to reproduce, ideally against a **synthetic or redacted** snapshot rather
  than one captured from a real device.

## What is in scope

This is a command-line tool that parses snapshot JSON, diffs it, and renders
reports. The most relevant concerns are:

- parsing untrusted snapshot files (malformed or hostile JSON),
- report output that is pasted into a shell or embedded in CI surfaces
  (for example, device names that contain shell or markup metacharacters),
- the GitHub Action's handling of repository state.

## Response

Because this is a best-effort, part-time project, there is no guaranteed response
time. Expect acknowledgement of a valid report within a couple of weeks, and a
fix or a documented mitigation as capacity allows. Fixed issues will be credited
in the advisory unless you ask otherwise.

## Handling captured data

A real GATT capture can reveal vendor UUIDs and firmware structure. Never attach
a capture from a device you do not own or are not permitted to share; a synthetic
fixture (see `Tests/GATTSnapshotCoreTests/Fixtures/`) is almost always enough to
reproduce a parsing or diffing bug.
