import Foundation
import GATTSnapshotCore

/// Colour-capable terminal output.
///
/// Colour is a constructor argument rather than something decided here: the
/// decision needs `isatty` and `NO_COLOR`, which belong to the CLI, and keeping
/// it out means every rendering path is testable with colour off.
public struct HumanReportRenderer {
    let useColor: Bool
    private let width = 76

    public init(useColor: Bool) {
        self.useColor = useColor
    }

    // MARK: - ANSI

    private enum Style: String {
        case reset = "\u{001B}[0m"
        case bold = "\u{001B}[1m"
        case dim = "\u{001B}[2m"
        case red = "\u{001B}[31m"
        case green = "\u{001B}[32m"
        case yellow = "\u{001B}[33m"
        case blue = "\u{001B}[34m"
        case magenta = "\u{001B}[35m"
        case cyan = "\u{001B}[36m"
    }

    private func paint(_ text: String, _ styles: Style...) -> String {
        guard useColor, !styles.isEmpty else { return text }
        return styles.map(\.rawValue).joined() + text + Style.reset.rawValue
    }

    private func color(for severity: Severity) -> Style {
        switch severity {
        case .breaking: .red
        case .additive: .yellow
        case .cosmetic: .dim
        }
    }

    // MARK: - Render

    public func render(_ report: DiffReport, baseLabel: String, headLabel: String) -> String {
        var out: [String] = []

        out.append(paint("base", .bold) + "  \(baseLabel)")
        out.append(paint("      profile ", .dim) + "'\(report.baseProfile)'"
                   + paint("  \(report.baseStructureHash)", .dim))
        out.append(paint("head", .bold) + "  \(headLabel)")
        out.append(paint("      profile ", .dim) + "'\(report.headProfile)'"
                   + paint("  \(report.headStructureHash)", .dim))
        out.append("")

        if report.baseStructureHash == report.headStructureHash {
            out.append(paint("structure_hash identical — the attribute table is unchanged.", .dim))
            out.append("")
        }

        out += renderWarnings(report)
        out += renderChanges(report)
        out += renderSuppressed(report)
        out += renderStandingLimitations(report)

        if report.changes.isEmpty && !report.isDegraded {
            out.append(paint("No changes.", .green))
            out.append("")
        }

        let code = report.exitCode
        let summary = "exit \(code)  \(ExitCodeMeaning.describe(code))"
        out.append(paint(summary, code == 0 ? .green : (code == 2 ? .red : .yellow), .bold))

        return out.joined(separator: "\n") + "\n"
    }

    private func renderWarnings(_ report: DiffReport) -> [String] {
        guard !report.warnings.isEmpty else { return [] }
        var out: [String] = []
        for warning in report.warnings {
            let label: String
            switch warning.kind {
            case .profileMismatch:
                label = "WARNING  profile mismatch"
            case .quietHashDifference:
                let causes = warning.causes.map(\.rawValue).joined(separator: ", ")
                label = "WARNING  quiet hash difference (\(causes))"
            case .ambiguousIdentity:
                label = "WARNING  ambiguous repeated UUID identity"
            }
            out.append(paint(label, .magenta, .bold))
            out += wrapText(warning.message, width: width, indent: "  ")
            out.append("")
        }
        return out
    }

    private func renderChanges(_ report: DiffReport) -> [String] {
        var out: [String] = []
        for severity in [Severity.breaking, .additive, .cosmetic] {
            let group = report.changes(severity)
            guard !group.isEmpty else { continue }
            out.append(paint("\(severity.headline) (\(group.count))",
                             color(for: severity), .bold))
            for change in group {
                out.append("  " + paint("\(change.path)", .cyan)
                           + paint("  [\(change.kind.rawValue)]", .dim))
                out += wrapText(change.detail, width: width, indent: "      ")
                if let note = change.note {
                    out += wrapText(note, width: width, indent: "      ").map { paint($0, .dim) }
                }
            }
            out.append("")
        }
        return out
    }

    private func renderSuppressed(_ report: DiffReport) -> [String] {
        let suppressed = report.suppressedComparisons
        guard !suppressed.isEmpty else { return [] }
        var out: [String] = []
        out.append(paint("DEGRADED (\(suppressed.count))  findings were dropped from this comparison",
                         .red, .bold))
        for entry in suppressed {
            out += wrapText(entry.detail, width: width, indent: "  ")
        }
        out.append("")
        return out
    }

    private func renderStandingLimitations(_ report: DiffReport) -> [String] {
        let limitations = report.standingLimitations
        guard !limitations.isEmpty else { return [] }
        var out: [String] = []
        // Always shown. A tool that silently omits what it could not check, then
        // prints "no changes", is worse than one that says nothing at all.
        out.append(paint("NOT COVERED  outside what these adapters can observe", .blue, .bold))
        for entry in limitations {
            out += wrapText(entry.detail, width: width, indent: "  ").map { paint($0, .dim) }
        }
        out.append("")
        return out
    }
}
