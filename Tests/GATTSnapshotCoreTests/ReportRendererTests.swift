import Foundation
// On Linux, swift-corelibs-foundation splits XMLParser into its own module.
// Parsing the generated XML with a real parser is the only assertion that
// actually proves the document is well-formed, so it is worth the import dance.
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import GATTSnapshotCore
@testable import GATTSnapshotReport

private func breakingReport() throws -> DiffReport {
    DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                       head: try Fixture.snapshot("variant-b"))
}

private func cleanReport() throws -> DiffReport {
    let a = try Fixture.snapshot("variant-a")
    return DiffEngine.compare(base: a, head: a)
}

private func degradedReport() throws -> DiffReport {
    DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                       head: try Fixture.snapshot("variant-a"))
}

@Suite("Human renderer")
struct HumanRendererTests {

    @Test("Reports every severity group with counts")
    func rendersSeverityGroups() throws {
        let text = HumanReportRenderer(useColor: false)
            .render(try breakingReport(), baseLabel: "a.json", headLabel: "b.json")
        #expect(text.contains("BREAKING (3)"))
        #expect(text.contains("ADDITIVE (2)"))
        #expect(text.contains("exit 2"))
        #expect(text.contains("breaking changes present"))
    }

    @Test("Emits no escape codes when colour is off")
    func noColorMeansNoEscapes() throws {
        for report in [try breakingReport(), try cleanReport(), try degradedReport()] {
            let text = HumanReportRenderer(useColor: false)
                .render(report, baseLabel: "a", headLabel: "b")
            #expect(!text.contains("\u{001B}["), "escape codes leaked into uncoloured output")
        }
    }

    @Test("Colourises when asked")
    func colorWhenEnabled() throws {
        let text = HumanReportRenderer(useColor: true)
            .render(try breakingReport(), baseLabel: "a", headLabel: "b")
        #expect(text.contains("\u{001B}["))
        // Every sequence opened must be closed, or the user's terminal stays red.
        let opens = text.components(separatedBy: "\u{001B}[").count - 1
        let resets = text.components(separatedBy: "\u{001B}[0m").count - 1
        #expect(resets > 0)
        #expect(opens > resets)
    }

    @Test("A clean run says so plainly")
    func cleanRun() throws {
        let text = HumanReportRenderer(useColor: false)
            .render(try cleanReport(), baseLabel: "a", headLabel: "a")
        #expect(text.contains("No changes."))
        #expect(text.contains("exit 0"))
        #expect(text.contains("structure_hash identical"))
    }

    @Test("Standing limitations are always shown, degraded or not")
    func limitationsAlwaysVisible() throws {
        let clean = HumanReportRenderer(useColor: false)
            .render(try cleanReport(), baseLabel: "a", headLabel: "a")
        #expect(clean.contains("NOT COVERED"))

        let degraded = HumanReportRenderer(useColor: false)
            .render(try degradedReport(), baseLabel: "a", headLabel: "b")
        #expect(degraded.contains("DEGRADED"))
        #expect(degraded.contains("dropped"))
    }

    @Test("Handle shifts carry their bonded-client explanation")
    func handleNoteRendered() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"),
                                        options: DiffOptions(diffHandles: true))
        let text = HumanReportRenderer(useColor: false)
            .render(report, baseLabel: "a", headLabel: "b")
        #expect(text.contains("bonded"))
        #expect(text.contains("Service Changed"))
    }
}

@Suite("JSON renderer")
struct JSONRendererTests {

    @Test("Produces parseable JSON carrying the verdict")
    func parseableWithVerdict() throws {
        let json = try JSONReportRenderer.render(try breakingReport(),
                                                 baseLabel: "a.json", headLabel: "b.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        #expect(object["tool"] as? String == "gattsnap")
        #expect(object["base"] as? String == "a.json")
        #expect(object["head"] as? String == "b.json")
        // A consumer must not have to re-derive the verdict from the parts.
        #expect(object["exit_code"] as? Int == 2)
        #expect((object["exit_meaning"] as? String)?.contains("breaking") == true)

        let summary = try #require(object["summary"] as? [String: Any])
        #expect(summary["breaking"] as? Int == 3)
        #expect(summary["additive"] as? Int == 2)
        #expect(summary["degraded"] as? Bool == false)
    }

    @Test("Carries the full report, not just the summary")
    func includesFullReport() throws {
        let json = try JSONReportRenderer.render(try breakingReport(),
                                                 baseLabel: "a", headLabel: "b")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let report = try #require(object["report"] as? [String: Any])
        let changes = try #require(report["changes"] as? [[String: Any]])
        #expect(changes.count == 5)
        #expect(changes.allSatisfy { $0["kind"] != nil && $0["severity"] != nil })
    }

    @Test("Degraded runs expose the suppression")
    func degradedInJSON() throws {
        let json = try JSONReportRenderer.render(try degradedReport(), baseLabel: "a", headLabel: "b")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["exit_code"] as? Int == 3)
        let summary = try #require(object["summary"] as? [String: Any])
        #expect(summary["degraded"] as? Bool == true)
        #expect((summary["suppressed"] as? Int ?? 0) > 0)
    }

    @Test("Output is deterministic")
    func deterministic() throws {
        let report = try breakingReport()
        let first = try JSONReportRenderer.render(report, baseLabel: "a", headLabel: "b")
        let second = try JSONReportRenderer.render(report, baseLabel: "a", headLabel: "b")
        #expect(first == second)
    }
}

@Suite("JUnit renderer")
struct JUnitRendererTests {

    @Test("Is well-formed XML")
    func wellFormed() throws {
        for report in [try breakingReport(), try cleanReport(), try degradedReport()] {
            let xml = JUnitReportRenderer.render(report, baseLabel: "a", headLabel: "b")
            #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
            // XMLParser is the real check: a malformed report reads to CI as an
            // infrastructure error, not as the finding it was trying to show.
            let parser = XMLParser(data: Data(xml.utf8))
            #expect(parser.parse(), "XMLParser rejected the document: \(parser.parserError as Any)")
        }
    }

    @Test("Breaking changes become failures, additive ones do not")
    func failuresCountedCorrectly() throws {
        let xml = JUnitReportRenderer.render(try breakingReport(), baseLabel: "a", headLabel: "b")
        #expect(xml.contains("failures=\"3\""))
        #expect(xml.contains("<failure"))
        #expect(xml.contains("classname=\"gattsnap.breaking\""))
        #expect(xml.contains("classname=\"gattsnap.additive\""))
    }

    @Test("Every finding is its own testcase, not one lumped message")
    func findingsAreSeparateCases() throws {
        let xml = JUnitReportRenderer.render(try breakingReport(), baseLabel: "a", headLabel: "b")
        let cases = xml.components(separatedBy: "<testcase ").count - 1
        // 3 breaking + 2 additive + standing limitations.
        #expect(cases >= 5)
    }

    /// The D5 obligation. CI reads exit codes and swallows stdout, so a warning
    /// that only exists as prose inside a message body is invisible exactly
    /// where it matters most.
    @Test("Warnings are visible elements even when they do not fail the build")
    func warningsVisibleWithoutFailing() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"))
        #expect(!report.warnings.isEmpty)
        #expect(report.exitCode == 0)

        let xml = JUnitReportRenderer.render(report, baseLabel: "a", headLabel: "b")
        #expect(xml.contains("classname=\"gattsnap.warning\""))
        #expect(xml.contains("warning: quiet_hash_difference"))
        // Named by cause, so the CI row itself is informative.
        #expect(xml.contains("handles_not_diffed"))
        #expect(xml.contains("<skipped"))
        #expect(xml.contains("failures=\"0\""))
    }

    @Test("Under --fail-on-warning a warning becomes a failure")
    func warningsFailWhenAsked() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"),
                                        options: DiffOptions(failOnWarning: true))
        let xml = JUnitReportRenderer.render(report, baseLabel: "a", headLabel: "b")
        #expect(xml.contains("classname=\"gattsnap.warning\""))
        #expect(xml.contains("failures=\"1\""))
        #expect(xml.contains("fail_on_warning\" value=\"true\""))
    }

    @Test("Suppressed comparisons are failures; standing limitations are skips")
    func degradedMapping() throws {
        let xml = JUnitReportRenderer.render(try degradedReport(), baseLabel: "a", headLabel: "b")
        #expect(xml.contains("classname=\"gattsnap.degraded\""))
        #expect(xml.contains("type=\"suppressed_comparison\""))
        #expect(xml.contains("classname=\"gattsnap.not-covered\""))
        #expect(xml.contains("exit_code\" value=\"3\""))
    }

    @Test("A report with nothing at all still emits a testcase")
    func emptyReportHasACase() throws {
        // BlueZ against itself: no changes, and no standing limitations either,
        // so nothing would otherwise be emitted. Without the fallback CI reports
        // "no tests ran", and green becomes indistinguishable from a broken job.
        let bluez = try Fixture.snapshot("variant-a-bluez")
        let report = DiffEngine.compare(base: bluez, head: bluez)
        #expect(report.changes.isEmpty)
        #expect(report.unobservable.isEmpty)

        let xml = JUnitReportRenderer.render(report, baseLabel: "a", headLabel: "a")
        #expect(xml.contains("name=\"no changes\""))
        #expect(xml.contains("tests=\"1\""))
        #expect(xml.contains("failures=\"0\""))
    }

    @Test("A clean CoreBluetooth run reports its blind spots as skipped cases")
    func cleanRunKeepsLimitations() throws {
        let xml = JUnitReportRenderer.render(try cleanReport(), baseLabel: "a", headLabel: "a")
        #expect(xml.contains("classname=\"gattsnap.not-covered\""))
        #expect(xml.contains("failures=\"0\""))
        #expect(xml.contains("skipped=\"2\""))
        #expect(xml.contains("exit_code\" value=\"0\""))
        // Not the fallback: real limitation cases were emitted instead.
        #expect(!xml.contains("name=\"no changes\""))
    }

    @Test("Hostile characters are escaped in both attributes and text")
    func escaping() {
        let nasty = "a & b < c > d \" e ' f"
        let attribute = JUnitReportRenderer.escape(nasty, inAttribute: true)
        #expect(attribute.contains("&amp;"))
        #expect(attribute.contains("&lt;"))
        #expect(attribute.contains("&quot;"))
        #expect(attribute.contains("&apos;"))
        #expect(!attribute.contains(" & "))

        let text = JUnitReportRenderer.escape(nasty, inAttribute: false)
        #expect(text.contains("&amp;"))
        #expect(text.contains("\""), "quotes need no escaping in element text")

        // XML 1.0 forbids most control characters; dropping beats emitting a
        // document no parser will accept.
        #expect(!JUnitReportRenderer.escape("a\u{0007}b", inAttribute: false).contains("\u{0007}"))
    }

    @Test("A report containing XML metacharacters still parses")
    func metacharactersSurviveRoundTrip() throws {
        var head = try Fixture.snapshot("variant-a")
        head.profile = "acme <sensor> & \"friends\""
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"), head: head)
        let xml = JUnitReportRenderer.render(report, baseLabel: "a<b", headLabel: "c&d")
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "\(parser.parserError as Any)")
    }
}
