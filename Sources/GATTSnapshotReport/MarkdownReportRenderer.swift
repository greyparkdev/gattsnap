import Foundation
import GATTSnapshotCore

/// Markdown, for a GitHub Actions job summary (`$GITHUB_STEP_SUMMARY`) or a
/// pull-request comment.
///
/// This is the complete report. Annotations are capped by GitHub at ten per
/// level and a terminal report is not visible from a pull request at all, so
/// this is the one surface that always carries every finding — which is why the
/// capped-annotation notice points here.
public enum MarkdownReportRenderer {

    public static func render(_ report: DiffReport,
                              baseLabel: String,
                              headLabel: String) -> String {
        var out: [String] = []

        let code = report.exitCode
        out.append("## \(verdictIcon(code)) gattsnap — \(ExitCodeMeaning.describe(code))")
        out.append("")
        out.append("| | |")
        out.append("|---|---|")
        out.append("| base | `\(cell(baseLabel))` · profile `\(cell(report.baseProfile))` |")
        out.append("| head | `\(cell(headLabel))` · profile `\(cell(report.headProfile))` |")
        out.append("| structure hash | `\(cell(report.baseStructureHash))`"
                   + " → `\(cell(report.headStructureHash))` |")
        out.append("| exit code | `\(code)` |")
        out.append("")

        for severity in [Severity.breaking, .additive, .cosmetic] {
            let group = report.changes(severity)
            guard !group.isEmpty else { continue }
            out.append("### \(severity.headline) (\(group.count))")
            out.append("")
            out.append("| Attribute | Change | Detail |")
            out.append("|---|---|---|")
            for change in group {
                out.append("| `\(cell(change.path.description))` | `\(cell(change.kind.rawValue))`"
                           + " | \(cell(change.detail)) |")
            }
            out.append("")

            // Notes are hoisted out of the table and de-duplicated. A single
            // handle shift produces one finding per moved attribute, and all of
            // them carry the same note — repeating sixty words of the most
            // important text in the report across six rows makes the table
            // unreadable and buries the thing it is trying to say.
            for note in distinctNotes(in: group) {
                out.append("> **Why this matters** — \(cell(note))")
                out.append("")
            }
        }

        let suppressed = report.suppressedComparisons
        if !suppressed.isEmpty {
            out.append("### ⚠️ Degraded (\(suppressed.count))")
            out.append("")
            out.append("Findings were **dropped** from this comparison — one side's adapter"
                       + " could see something the other structurally cannot.")
            out.append("")
            for entry in suppressed {
                out.append("- **`\(cell(entry.capability.rawValue))`** — \(cell(entry.detail))")
            }
            out.append("")
        }

        let limitations = report.standingLimitations
        if !limitations.isEmpty {
            // Always shown, never folded into the verdict. A report that omits
            // what it could not check and then says "no changes" is worse than
            // one that says nothing.
            out.append("<details><summary>Not covered — outside what these adapters"
                       + " can observe (\(limitations.count))</summary>")
            out.append("")
            for entry in limitations {
                out.append("- **`\(cell(entry.capability.rawValue))`** — \(cell(entry.detail))")
            }
            out.append("")
            out.append("</details>")
            out.append("")
        }

        if !report.warnings.isEmpty {
            out.append("### Warnings (\(report.warnings.count))")
            out.append("")
            for warning in report.warnings {
                let causes = warning.causes.map(\.rawValue).joined(separator: ", ")
                let label = causes.isEmpty
                    ? warning.kind.rawValue
                    : "\(warning.kind.rawValue) (\(causes))"
                out.append("- **`\(cell(label))`** — \(cell(warning.message))")
            }
            out.append("")
            if !report.failOnWarning {
                out.append("_Warnings did not affect the exit code."
                           + " Pass `--fail-on-warning` to promote them._")
                out.append("")
            }
        }

        if report.changes.isEmpty && !report.isDegraded {
            out.append("No changes to the attribute table.")
            out.append("")
        }

        // Exactly one trailing newline, so appending to a shared job summary is
        // predictable rather than dependent on which section happened to be last.
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// Distinct notes in first-appearance order. `Set` would be shorter and
    /// would also make the output order depend on hashing, which is not stable
    /// across runs.
    static func distinctNotes(in changes: [Change]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for note in changes.compactMap(\.note) where seen.insert(note).inserted {
            ordered.append(note)
        }
        return ordered
    }

    private static func verdictIcon(_ code: Int32) -> String {
        switch code {
        case 0: "✅"
        case 1: "ℹ️"
        case 2: "❌"
        case 3: "⚠️"
        case 4: "⚠️"
        default: "❔"
        }
    }

    /// Escapes what would otherwise break a Markdown table row.
    ///
    /// A pipe from a property list or a newline from a wrapped detail silently
    /// splits a cell and shifts every column after it, which reads as a bug in
    /// the diff rather than in the renderer.
    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
