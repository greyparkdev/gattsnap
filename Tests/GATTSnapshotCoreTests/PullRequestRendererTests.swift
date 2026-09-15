import Foundation
import Testing
@testable import GATTSnapshotCore
@testable import GATTSnapshotReport

// MARK: - Shared reports

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

private func handleShiftReport() throws -> DiffReport {
    DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                       head: try Fixture.snapshot("variant-a-handles-shifted"),
                       options: DiffOptions(diffHandles: true))
}

private func target(_ fixture: String) throws -> AnnotationTarget {
    AnnotationTarget(path: "snapshots/\(fixture).json",
                     lineIndex: SnapshotLineIndex(snapshotText: try Fixture.text(fixture)),
                     table: try Fixture.snapshot(fixture).table)
}

/// 1-based line of the first line containing `needle`.
private func lineContaining(_ needle: String, in text: String) -> Int? {
    for (index, line) in text.components(separatedBy: "\n").enumerated()
    where line.contains(needle) {
        return index + 1
    }
    return nil
}

private func synthetic(breakingCount: Int) -> DiffReport {
    let changes = (0..<breakingCount).map { index in
        Change(kind: .characteristicRemoved, severity: .breaking,
               path: AttributePath(service: BluetoothUUID("180D"),
                                   characteristic: BluetoothUUID(String(format: "2A%02X", index))),
               detail: "characteristic \(index) removed")
    }
    return DiffReport(changes: changes, unobservable: [], warnings: [],
                      baseProfile: "p", headProfile: "p",
                      baseStructureHash: "sha256:a", headStructureHash: "sha256:b")
}

// MARK: - Line index

@Suite("Snapshot line index")
struct SnapshotLineIndexTests {

    @Test("Locates a service, characteristic and descriptor at their uuid lines")
    func locatesAttributes() throws {
        let text = try Fixture.text("variant-a")
        let table = try Fixture.snapshot("variant-a").table
        let index = SnapshotLineIndex(snapshotText: text)

        let service = BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001")
        let characteristic = BluetoothUUID("A1A10000-9E57-4A5B-9C1D-000000000011")

        #expect(index.line(for: AttributePath(service: service), in: table)
                == lineContaining("\"\(service)\"", in: text))
        #expect(index.line(for: AttributePath(service: service, characteristic: characteristic),
                           in: table)
                == lineContaining("\"\(characteristic)\"", in: text))
        #expect(index.line(for: AttributePath(service: service, characteristic: characteristic,
                                              descriptor: BluetoothUUID("2902")), in: table)
                == lineContaining("\"2902\"", in: text))
    }

    /// The behaviour the whole type exists for. Roughly half of all findings are
    /// removals, and a removed attribute has no line in the head snapshot.
    @Test("A removed attribute falls back to its nearest surviving ancestor")
    func removalsFallBackOutward() throws {
        let text = try Fixture.text("variant-b")
        let table = try Fixture.snapshot("variant-b").table
        let index = SnapshotLineIndex(snapshotText: text)

        let service = BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001")
        let present = BluetoothUUID("A1A10000-9E57-4A5B-9C1D-000000000011")
        let removed = BluetoothUUID("A2A20000-9E57-4A5B-9C1D-000000000012")

        // Characteristic gone from head -> its service.
        #expect(index.line(for: AttributePath(service: service, characteristic: removed), in: table)
                == lineContaining("\"\(service)\"", in: text))

        // Descriptor gone from head -> its characteristic.
        #expect(index.line(for: AttributePath(service: service, characteristic: present,
                                              descriptor: BluetoothUUID("2902")), in: table)
                == lineContaining("\"\(present)\"", in: text))

        // Service gone from head -> the table itself.
        #expect(index.line(for: AttributePath(service: BluetoothUUID("FFFF")), in: table)
                == lineContaining("\"table\"", in: text))
    }

    @Test("Instance ordinals disambiguate same-UUID siblings")
    func instancesAreDistinguished() throws {
        let text = """
        {
          "table" : {
            "services" : [
              { "uuid" : "180D", "instance" : 0, "characteristics" : [] },
              { "uuid" : "180D", "instance" : 1, "characteristics" : [] }
            ]
          }
        }
        """
        let table = AttributeTable(services: [
            Service(uuid: BluetoothUUID("180D"), instance: 0),
            Service(uuid: BluetoothUUID("180D"), instance: 1),
        ])
        let index = SnapshotLineIndex(snapshotText: text)
        #expect(index.line(for: AttributePath(service: BluetoothUUID("180D"), serviceInstance: 0),
                           in: table) == 4)
        #expect(index.line(for: AttributePath(service: BluetoothUUID("180D"), serviceInstance: 1),
                           in: table) == 5)
    }

    @Test("Newlines and escapes inside strings do not shift the count")
    func stringContentsDoNotShiftLines() {
        // The \\" must not be read as the end of the literal, and the \\n is two
        // characters in the file, not a line break.
        let text = """
        {
          "note" : "a \\"quoted\\" value with a \\n escape",
          "table" : { "services" : [] }
        }
        """
        let index = SnapshotLineIndex(snapshotText: text)
        #expect(index.line(forKeyPath: "table") == 3)
    }

    @Test("A minified snapshot puts everything on line 1")
    func minifiedFile() {
        let index = SnapshotLineIndex(
            snapshotText: #"{"table":{"services":[{"uuid":"180D"}]}}"#)
        #expect(index.line(forKeyPath: "table") == 1)
        #expect(index.line(forKeyPath: "table.services.0.uuid") == 1)
    }

    /// A hand-mangled file must degrade to a coarser annotation, never hang or
    /// crash the diff that produced the findings.
    @Test("Truncated and malformed input terminates with a partial index")
    func malformedInputTerminates() {
        for text in [#"{"table":{"services":[{"uuid":"#,
                     #"{"table": "#,
                     "{{{{[[[[",
                     "",
                     #"{"a" : }"#] {
            let index = SnapshotLineIndex(snapshotText: text)
            _ = index.line(forKeyPath: "table")
        }
    }
}

// MARK: - GitHub workflow commands

@Suite("GitHub annotation renderer")
struct GitHubReportRendererTests {

    private func render(_ report: DiffReport, target: AnnotationTarget? = nil) -> [String] {
        GitHubReportRenderer.render(report, baseLabel: "a.json", headLabel: "b.json",
                                    target: target)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// A raw newline splits one command into a broken command plus a line of
    /// stray log text. The handle-shift note contains a blank line, so this is
    /// the single most likely way for this renderer to fail in production.
    @Test("Every emitted line is one well-formed command")
    func everyLineIsACommand() throws {
        for report in [try breakingReport(), try cleanReport(),
                       try degradedReport(), try handleShiftReport()] {
            for line in render(report, target: try target("variant-b")) {
                #expect(line.hasPrefix("::"), "not a workflow command: \(line)")
                #expect(line.dropFirst(2).contains("::"),
                        "command has no message separator: \(line)")
            }
        }
    }

    @Test("Severity maps onto annotation level the same way JUnit maps onto elements")
    func levelMapping() throws {
        let lines = render(try breakingReport(), target: try target("variant-b"))
        #expect(lines.contains { $0.hasPrefix("::error") && $0.contains("property_removed") })
        #expect(lines.contains { $0.hasPrefix("::notice") && $0.contains("characteristic_added") })
        #expect(lines.contains { $0.hasPrefix("::notice") && $0.contains("not covered") })

        // A suppressed comparison is an error; a standing limitation is not.
        let degraded = render(try degradedReport(), target: try target("variant-a"))
        #expect(degraded.contains { $0.hasPrefix("::error") && $0.contains("degraded") })
        #expect(!degraded.contains { $0.hasPrefix("::error") && $0.contains("not covered") })
    }

    @Test("--fail-on-warning promotes a warning from warning to error")
    func warningPromotion() throws {
        let base = try Fixture.snapshot("variant-a-handles")
        let head = try Fixture.snapshot("variant-a-handles-shifted")

        let quiet = DiffEngine.compare(base: base, head: head)
        #expect(render(quiet).contains { $0.hasPrefix("::warning") })

        let loud = DiffEngine.compare(base: base, head: head,
                                      options: DiffOptions(failOnWarning: true))
        #expect(render(loud).contains { $0.hasPrefix("::error") && $0.contains("warning") })
    }

    @Test("Annotations carry file and line when a target is supplied")
    func fileAndLine() throws {
        let annotated = render(try breakingReport(), target: try target("variant-b"))
            .filter { $0.contains("property_removed") }
        #expect(annotated.count == 1)
        #expect(annotated[0].contains("file=snapshots/variant-b.json"))
        #expect(annotated[0].contains("line="))

        // Without a target there is nothing to attach to, but the finding must
        // still reach the log.
        let bare = render(try breakingReport())
            .filter { $0.contains("property_removed") }
        #expect(bare.count == 1)
        #expect(!bare[0].contains("file="))
        #expect(!bare[0].contains("line="))
    }

    /// `:` and `,` terminate a property; `%` and newlines terminate or corrupt a
    /// message. UUID paths and handle notes contain all four.
    @Test("Property and data escaping")
    func escaping() {
        #expect(GitHubReportRenderer.escapeProperty("a:b,c") == "a%3Ab%2Cc")
        #expect(GitHubReportRenderer.escapeData("100%\ndone") == "100%25%0Adone")
        // % must be escaped first, or the escapes introduced by later
        // replacements get double-escaped.
        #expect(GitHubReportRenderer.escapeData("%0A") == "%250A")
    }

    @Test("A clean run still emits an annotation")
    func cleanRunIsVisible() throws {
        let lines = render(try cleanReport())
        #expect(lines.contains { $0.contains("no changes") })
        #expect(lines.contains { $0.contains("exit 0") })
    }

    @Test("The verdict is always the last line")
    func verdictLast() throws {
        for report in [try breakingReport(), try cleanReport(), try degradedReport()] {
            #expect(render(report).last?.contains("gattsnap%3A verdict") == true)
        }
    }
}

@Suite("GitHub annotation display cap")
struct GitHubDisplayCapTests {

    private func errorLines(_ count: Int) -> [String] {
        GitHubReportRenderer.render(synthetic(breakingCount: count),
                                    baseLabel: "a", headLabel: "b", target: nil)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("::error") }
    }

    @Test("Under the cap, every finding is annotated")
    func underCap() {
        #expect(errorLines(3).count == 3)
        #expect(errorLines(9).count == 9)
    }

    @Test("Exactly at the cap, all ten are shown rather than nine plus a notice")
    func exactlyAtCap() {
        let lines = errorLines(GitHubReportRenderer.displayCap)
        #expect(lines.count == GitHubReportRenderer.displayCap)
        #expect(!lines.contains { $0.contains("not shown") })
    }

    /// GitHub discards annotations past ten without saying so. A tool whose
    /// premise is never reporting a blind spot as a fact has to say so itself.
    @Test("Over the cap, the last slot accounts for what is hidden")
    func overCap() {
        let lines = errorLines(25)
        #expect(lines.count == GitHubReportRenderer.displayCap)
        let notice = lines.filter { $0.contains("not shown") }
        #expect(notice.count == 1)
        #expect(notice[0].contains("16 more"))
        #expect(notice[0].contains("job summary"))
    }
}

// MARK: - Markdown

@Suite("Markdown renderer")
struct MarkdownReportRendererTests {

    private func render(_ report: DiffReport) -> String {
        MarkdownReportRenderer.render(report, baseLabel: "a.json", headLabel: "b.json")
    }

    @Test("Groups changes by severity with counts")
    func severityGroups() throws {
        let text = render(try breakingReport())
        #expect(text.contains("### BREAKING (3)"))
        #expect(text.contains("### ADDITIVE (2)"))
        #expect(text.contains("| exit code | `2` |"))
    }

    /// A pipe from a property list silently splits a cell and shifts every
    /// column after it, which reads as a bug in the diff rather than the
    /// renderer.
    @Test("Cell content that would break a table row is escaped")
    func cellEscaping() throws {
        #expect(MarkdownReportRenderer.cell("read|write") == "read\\|write")
        #expect(MarkdownReportRenderer.cell("one\ntwo") == "one two")
        #expect(MarkdownReportRenderer.cell("a\r\nb") == "a b")

        let text = render(try breakingReport())
        for row in text.components(separatedBy: "\n") where row.hasPrefix("| `") {
            // Three columns means exactly four unescaped delimiters.
            let unescaped = row.replacingOccurrences(of: "\\|", with: "")
            #expect(unescaped.components(separatedBy: "|").count == 5,
                    "row has the wrong column count: \(row)")
        }
    }

    /// One handle shift produces a finding per moved attribute, all carrying the
    /// same sixty-word note. Repeating it per row buries the most important text
    /// in the report.
    @Test("A repeated note is hoisted out of the table and stated once")
    func notesAreDeduplicated() throws {
        let text = render(try handleShiftReport())
        #expect(text.contains("### BREAKING (7)"))
        let occurrences = text.components(separatedBy: "Handles shifted.").count - 1
        #expect(occurrences == 1, "the handle-shift note appears \(occurrences) times")
        #expect(text.contains("> **Why this matters**"))
    }

    @Test("Standing limitations are always present, degraded or not")
    func limitationsAlwaysShown() throws {
        #expect(render(try breakingReport()).contains("Not covered"))
        #expect(render(try degradedReport()).contains("Degraded (1)"))
    }

    @Test("A clean run says so")
    func cleanRun() throws {
        let text = render(try cleanReport())
        #expect(text.contains("No changes to the attribute table."))
        #expect(text.contains("| exit code | `0` |"))
    }

    /// The job summary is a shared append-only file, so a predictable ending
    /// is what keeps two steps' output from running together.
    @Test("Output ends with exactly one newline")
    func singleTrailingNewline() throws {
        for report in [try breakingReport(), try cleanReport(),
                       try degradedReport(), try handleShiftReport()] {
            let text = render(report)
            #expect(text.hasSuffix("\n"))
            #expect(!text.hasSuffix("\n\n"))
        }
    }
}

// MARK: - Format plumbing

@Suite("Output format dispatch")
struct PullRequestFormatTests {

    @Test("The new formats parse and are listed")
    func parsing() {
        #expect(OutputFormat.parse("github") == .github)
        #expect(OutputFormat.parse("MARKDOWN") == .markdown)
        #expect(OutputFormat.allNames.contains("github"))
        #expect(OutputFormat.allNames.contains("markdown"))
    }

    @Test("Every format renders every report without throwing")
    func everyFormatRendersEveryReport() throws {
        let reports = [try breakingReport(), try cleanReport(),
                       try degradedReport(), try handleShiftReport()]
        for format in OutputFormat.allCases {
            for report in reports {
                let text = try ReportRenderer.render(
                    report, format: format, baseLabel: "a", headLabel: "b",
                    useColor: false, target: try target("variant-b"))
                #expect(!text.isEmpty, "\(format) produced nothing")
            }
        }
    }
}
