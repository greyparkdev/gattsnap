import Foundation
import Testing
@testable import GATTSnapshotCore

@Suite("--fail-on-warning")
struct FailOnWarningTests {

    @Test("Warnings do not affect the verdict by default")
    func warningsAreAdvisoryByDefault() throws {
        let a = try Fixture.snapshot("variant-a")
        var b = a
        b.profile = "some-other-product"
        let report = DiffEngine.compare(base: a, head: b)
        #expect(!report.warnings.isEmpty)
        #expect(report.exitCode == 0)
    }

    @Test("A warning becomes exit 4 under --fail-on-warning")
    func warningBecomesFailure() throws {
        // CI reads exit codes and swallows stdout, so a well-written warning is
        // invisible exactly where it matters most.
        let a = try Fixture.snapshot("variant-a")
        var b = a
        b.profile = "some-other-product"
        let report = DiffEngine.compare(base: a, head: b,
                                        options: DiffOptions(failOnWarning: true))
        #expect(report.exitCode == 4)
    }

    @Test("A quiet hash difference becomes exit 4 under --fail-on-warning")
    func quietHashBecomesFailure() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"),
                                        options: DiffOptions(failOnWarning: true))
        #expect(report.exitCode == 4)
    }

    @Test("No warnings means the flag changes nothing")
    func noWarningsNoEffect() throws {
        let a = try Fixture.snapshot("variant-a")
        #expect(DiffEngine.compare(base: a, head: a,
                                   options: DiffOptions(failOnWarning: true)).exitCode == 0)
    }

    @Test("Breaking and degraded still outrank a warning failure")
    func precedenceHolds() throws {
        let breaking = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                          head: try Fixture.snapshot("variant-b"),
                                          options: DiffOptions(failOnWarning: true))
        #expect(breaking.exitCode == 2)

        let degraded = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                          head: try Fixture.snapshot("variant-a"),
                                          options: DiffOptions(failOnWarning: true))
        #expect(degraded.exitCode == 3)
    }

    @Test("The flag is recorded in the report so an exit code can be explained")
    func flagIsSelfDescribing() throws {
        let a = try Fixture.snapshot("variant-a")
        let report = DiffEngine.compare(base: a, head: a,
                                        options: DiffOptions(failOnWarning: true))
        #expect(report.failOnWarning)
    }
}

@Suite("Quiet hash difference causes")
struct QuietHashCauseTests {

    @Test("An undiffed handle shift reports handles_not_diffed")
    func handlesCause() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"))
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.causes == [.handlesNotDiffed])
        #expect(!warning.causes.contains(.undetermined))
    }

    @Test("A capability gap reports adapter_capability_gap")
    func capabilityCause() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                        head: try Fixture.snapshot("variant-a"))
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.causes == [.adapterCapabilityGap])
    }

    @Test("Both causes are reported together when both apply")
    func bothCauses() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                        head: try Fixture.snapshot("variant-a-handles"))
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.causes.contains(.handlesNotDiffed))
        #expect(warning.causes.contains(.adapterCapabilityGap))
        // Sharing a warning surface must not merge the verdicts: the capability
        // gap degrades, the handles opt-out does not.
        #expect(report.exitCode == 3)
    }

    /// Found by running M3 against real hardware: capture once without
    /// --include-handles and once with, and the cause was `undetermined` —
    /// which is documented as unreachable and a bug. It is an ordinary
    /// workflow, and the cause is perfectly determinable.
    @Test("Mismatched capture options are a determined cause, not a bug report")
    func captureOptionsDifferIsDetermined() throws {
        let withoutHandles = try Fixture.snapshot("variant-a")
        let withHandles = try Fixture.snapshot("variant-a-handles")
        #expect(withoutHandles.structureHash != withHandles.structureHash)

        let report = DiffEngine.compare(base: withoutHandles, head: withHandles)
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.causes.contains(.captureOptionsDiffer))
        #expect(!warning.causes.contains(.undetermined))
        // The remedy is re-capturing, so the message has to say so.
        #expect(warning.message.contains("re-capture"))
        #expect(warning.message.contains("handles"))
    }

    @Test("Matching capture options do not report an options mismatch")
    func matchingOptionsAreQuiet() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"))
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(!warning.causes.contains(.captureOptionsDiffer))
    }

    @Test("Undetermined never appears alongside a real cause")
    func undeterminedIsExclusive() throws {
        for (b, h) in [("variant-a-handles", "variant-a-handles-shifted"),
                       ("variant-a-bluez", "variant-a"),
                       ("variant-a-bluez", "variant-a-handles"),
                       ("variant-a", "variant-a-handles"),
                       ("variant-a-handles", "variant-a")] {
            let report = DiffEngine.compare(base: try Fixture.snapshot(b),
                                            head: try Fixture.snapshot(h))
            for warning in report.warnings where warning.kind == .quietHashDifference {
                #expect(!warning.causes.contains(.undetermined), "\(b) vs \(h)")
            }
        }
    }
}

/// The threshold is a safety check. An unset one that quietly becomes a passing
/// check is the same failure class as reporting a blind spot as a fact.
@Suite("Cache detection policy")
struct CacheDetectionTests {

    @Test("The measured default is 10 ms")
    func measuredDefault() {
        #expect(CacheDetectionPolicy.measured.thresholdMs == 10)
        #expect(CacheDetectionPolicy.measured.isEnabled)
    }

    @Test("A cache hit is caught", arguments: [0.0, 0.5, 4.0, 9.9])
    func catchesCacheHit(durationMs: Double) {
        let outcome = CacheDetectionPolicy.measured.evaluate(durationMs: durationMs)
        #expect(outcome == .suspectedCache(durationMs: durationMs, thresholdMs: 10))
    }

    @Test("Real over-the-air discovery passes", arguments: [10.0, 50.0, 310.0, 439.0, 471.0])
    func allowsLiveRead(durationMs: Double) {
        // 439–471 ms are the M1 measurements; 310 ms is the BlueZ fixture.
        #expect(CacheDetectionPolicy.measured.evaluate(durationMs: durationMs)
                == .liveRead(durationMs: durationMs))
    }

    @Test("Three orders of magnitude sit between the two populations")
    func thresholdHasEnormousMargin() {
        // The point of picking 10 ms: it is ~44x below the fastest observed
        // real discovery and infinitely above a cache hit, so table size, host
        // speed and macOS version cannot move a result across it.
        let policy = CacheDetectionPolicy.measured
        #expect(policy.evaluate(durationMs: 0.0) != .liveRead(durationMs: 0.0))
        #expect(policy.evaluate(durationMs: 439.0) == .liveRead(durationMs: 439.0))
    }

    @Test("An unset threshold disables detection rather than defaulting")
    func unsetDisables() {
        let policy = CacheDetectionPolicy.disabled
        #expect(!policy.isEnabled)
        #expect(policy.thresholdMs == nil)
        // Critically: not `.liveRead`. A disabled check must never report a
        // pass it did not perform.
        #expect(policy.evaluate(durationMs: 0.0) == .notChecked(durationMs: 0.0))
        #expect(policy.evaluate(durationMs: 500.0) == .notChecked(durationMs: 500.0))
    }

    @Test("Disabling carries a loud, unambiguous warning for callers to surface")
    func disabledWarningIsLoud() {
        let w = CacheDetectionPolicy.disabledWarning
        #expect(w.contains("DISABLED"))
        #expect(w.contains("NOT been checked"))
        #expect(w.contains("Do not treat it as verified"))
    }
}
