import Foundation
import GATTSnapshotCore

/// JUnit XML, for CI systems that render test results.
///
/// The shape is deliberate. CI reads exit codes and swallows stdout, so anything
/// that only exists as prose is invisible where it matters most. Every finding
/// therefore becomes its own `<testcase>` — a named row in the CI UI — rather
/// than being summarised into one case's message body:
///
/// | finding                            | element                       |
/// |------------------------------------|-------------------------------|
/// | breaking change                    | `<failure>`                   |
/// | additive / cosmetic change         | passing case + `<system-out>` |
/// | suppressed comparison (degrades)   | `<failure>`                   |
/// | standing limitation                | `<skipped>`                   |
/// | warning, `--fail-on-warning` on    | `<failure>`                   |
/// | warning, off                       | `<skipped>`                   |
///
/// Warnings get their own cases in both states (D5): a warning that only showed
/// up when it also failed the build would be useless for the case the flag
/// exists to serve.
public enum JUnitReportRenderer {

    public static func render(_ report: DiffReport,
                              baseLabel: String,
                              headLabel: String) -> String {
        var cases: [String] = []
        var failures = 0
        var skipped = 0

        for change in report.changes {
            let name = "\(change.severity.rawValue): \(change.path) \(change.kind.rawValue)"
            if change.severity == .breaking {
                failures += 1
                var body = change.detail
                if let note = change.note { body += "\n\n" + note }
                cases.append(testcase(
                    name: name, classname: "gattsnap.breaking",
                    inner: element("failure", attributes: [
                        "type": change.kind.rawValue,
                        "message": change.detail,
                    ], text: body)))
            } else {
                cases.append(testcase(
                    name: name, classname: "gattsnap.\(change.severity.rawValue)",
                    inner: element("system-out", attributes: [:], text: change.detail)))
            }
        }

        for entry in report.suppressedComparisons {
            failures += 1
            cases.append(testcase(
                name: "degraded: \(entry.capability.rawValue)",
                classname: "gattsnap.degraded",
                inner: element("failure", attributes: [
                    "type": "suppressed_comparison",
                    "message": entry.detail,
                ], text: entry.detail)))
        }

        for entry in report.standingLimitations {
            skipped += 1
            cases.append(testcase(
                name: "not covered: \(entry.capability.rawValue)",
                classname: "gattsnap.not-covered",
                inner: element("skipped", attributes: ["message": entry.detail], text: nil)))
        }

        // Warnings are first-class cases whether or not they fail the build.
        for warning in report.warnings {
            let causes = warning.causes.map(\.rawValue).joined(separator: ",")
            let name = causes.isEmpty
                ? "warning: \(warning.kind.rawValue)"
                : "warning: \(warning.kind.rawValue) (\(causes))"
            if report.failOnWarning {
                failures += 1
                cases.append(testcase(
                    name: name, classname: "gattsnap.warning",
                    inner: element("failure", attributes: [
                        "type": warning.kind.rawValue,
                        "message": warning.message,
                    ], text: warning.message)))
            } else {
                skipped += 1
                cases.append(testcase(
                    name: name, classname: "gattsnap.warning",
                    inner: element("skipped", attributes: ["message": warning.message], text: nil)))
            }
        }

        // A completely clean run still needs one case, or CI reports "no tests
        // ran" and a green result becomes indistinguishable from a broken job.
        if cases.isEmpty {
            cases.append(testcase(
                name: "no changes", classname: "gattsnap",
                inner: element("system-out", attributes: [:],
                               text: "attribute table unchanged (\(report.baseStructureHash))")))
        }

        let properties = element("properties", attributes: [:], text: nil, children: [
            property("base", baseLabel),
            property("head", headLabel),
            property("base_profile", report.baseProfile),
            property("head_profile", report.headProfile),
            property("base_structure_hash", report.baseStructureHash),
            property("head_structure_hash", report.headStructureHash),
            property("exit_code", "\(report.exitCode)"),
            property("exit_meaning", ExitCodeMeaning.describe(report.exitCode)),
            property("degraded", "\(report.isDegraded)"),
            property("fail_on_warning", "\(report.failOnWarning)"),
        ])

        let suite = element("testsuite", attributes: [
            "name": "gattsnap.diff",
            "tests": "\(cases.count)",
            "failures": "\(failures)",
            "errors": "0",
            "skipped": "\(skipped)",
        ], text: nil, children: [properties] + cases)

        let suites = element("testsuites", attributes: [
            "name": "gattsnap",
            "tests": "\(cases.count)",
            "failures": "\(failures)",
            "errors": "0",
            "skipped": "\(skipped)",
        ], text: nil, children: [suite])

        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + suites + "\n"
    }

    // MARK: - XML assembly

    private static func property(_ name: String, _ value: String) -> String {
        element("property", attributes: ["name": name, "value": value], text: nil)
    }

    private static func testcase(name: String, classname: String, inner: String) -> String {
        element("testcase", attributes: ["name": name, "classname": classname],
                text: nil, children: [inner])
    }

    private static func element(_ tag: String,
                                attributes: [String: String],
                                text: String?,
                                children: [String] = []) -> String {
        let rendered = attributes.keys.sorted()
            .map { " \($0)=\"\(escape(attributes[$0]!, inAttribute: true))\"" }
            .joined()
        if text == nil && children.isEmpty {
            return "<\(tag)\(rendered)/>"
        }
        var body = ""
        if let text { body += escape(text, inAttribute: false) }
        body += children.joined(separator: "\n")
        return "<\(tag)\(rendered)>\n\(indent(body))\n</\(tag)>"
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }
            .joined(separator: "\n")
    }

    /// XML escaping. Diff details carry `<`, `&` and quotes from UUIDs, property
    /// lists and device strings, and one unescaped character makes the whole
    /// report unparseable — which CI reports as an infrastructure error rather
    /// than as the finding it was trying to show.
    static func escape(_ text: String, inAttribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += inAttribute ? "&quot;" : "\""
            case "'": out += inAttribute ? "&apos;" : "'"
            case "\n": out += inAttribute ? "&#10;" : "\n"
            case "\r": out += "&#13;"
            case "\t": out += inAttribute ? "&#9;" : "\t"
            default:
                // XML 1.0 forbids most control characters outright; dropping
                // them beats emitting a document no parser will accept.
                if character.value < 0x20 { continue }
                out.unicodeScalars.append(character)
            }
        }
        return out
    }
}
