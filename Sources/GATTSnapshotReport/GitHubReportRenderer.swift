import Foundation
import GATTSnapshotCore

/// Where GitHub annotations should point.
///
/// `path` must be **relative to the workspace root**. GitHub silently drops an
/// annotation whose file it cannot resolve — no warning, no log line — so an
/// absolute path produces a run that looks like it simply found nothing.
public struct AnnotationTarget: Sendable {
    public var path: String
    public var lineIndex: SnapshotLineIndex
    public var table: AttributeTable

    public init(path: String, lineIndex: SnapshotLineIndex, table: AttributeTable) {
        self.path = path
        self.lineIndex = lineIndex
        self.table = table
    }
}

/// GitHub Actions workflow commands, so findings appear as inline annotations on
/// the snapshot file in the pull request's Files Changed view.
///
/// Levels mirror the JUnit mapping deliberately — the same finding must not be a
/// failure in one CI surface and an informational note in another:
///
/// | finding                          | level    |
/// |----------------------------------|----------|
/// | breaking change                  | `error`  |
/// | suppressed comparison (degrades) | `error`  |
/// | warning, `--fail-on-warning` on  | `error`  |
/// | warning, off                     | `warning`|
/// | additive / cosmetic change       | `notice` |
/// | standing limitation              | `notice` |
///
/// Written as workflow commands rather than through the Checks API on purpose:
/// no token, no network call, no failure mode where the annotations are lost
/// because an API request timed out. The cost is the display cap below.
public enum GitHubReportRenderer {

    /// GitHub renders at most 10 annotations per level per step and discards the
    /// rest without saying so. A tool whose entire premise is never reporting a
    /// blind spot as a fact cannot let that happen quietly, so a capped level
    /// spends its last slot saying how many findings it is not showing and where
    /// to read them.
    static let displayCap = 10

    struct Annotation {
        var level: String
        var title: String
        var message: String
        var line: Int?
    }

    public static func render(_ report: DiffReport,
                              baseLabel: String,
                              headLabel: String,
                              target: AnnotationTarget?) -> String {
        var annotations: [Annotation] = []

        for change in report.changes {
            var message = change.detail
            if let note = change.note { message += "\n\n" + note }
            annotations.append(Annotation(
                level: change.severity == .breaking ? "error" : "notice",
                title: "\(change.severity.rawValue): \(change.kind.rawValue)",
                message: "\(change.path) — \(message)",
                line: target.flatMap { $0.lineIndex.line(for: change.path, in: $0.table) }))
        }

        for entry in report.suppressedComparisons {
            annotations.append(Annotation(
                level: "error",
                title: "degraded: \(entry.capability.rawValue)",
                message: entry.detail,
                line: target?.lineIndex.line(forKeyPath: "adapter")))
        }

        for entry in report.standingLimitations {
            annotations.append(Annotation(
                level: "notice",
                title: "not covered: \(entry.capability.rawValue)",
                message: entry.detail,
                line: target?.lineIndex.line(forKeyPath: "adapter")))
        }

        for warning in report.warnings {
            let causes = warning.causes.map(\.rawValue).joined(separator: ",")
            annotations.append(Annotation(
                level: report.failOnWarning ? "error" : "warning",
                title: causes.isEmpty
                    ? "warning: \(warning.kind.rawValue)"
                    : "warning: \(warning.kind.rawValue) (\(causes))",
                message: warning.message,
                line: target?.lineIndex.line(forKeyPath: "structure_hash")))
        }

        // A clean run must still say something. A step that emits nothing is
        // indistinguishable from a step that failed to run.
        if annotations.isEmpty {
            annotations.append(Annotation(
                level: "notice",
                title: "gattsnap: no changes",
                message: "attribute table unchanged (\(report.baseStructureHash))",
                line: target?.lineIndex.line(forKeyPath: "structure_hash")))
        }

        var lines = capped(annotations).map { command(for: $0, file: target?.path) }
        lines.append(command(for: Annotation(
            level: "notice",
            title: "gattsnap: verdict",
            message: "\(baseLabel) → \(headLabel): exit \(report.exitCode), "
                + ExitCodeMeaning.describe(report.exitCode),
            line: nil), file: nil))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Caps each level independently, because GitHub's limit is per level.
    static func capped(_ annotations: [Annotation]) -> [Annotation] {
        var counts: [String: Int] = [:]
        var kept: [Annotation] = []
        var dropped: [String: Int] = [:]

        for annotation in annotations {
            let seen = counts[annotation.level, default: 0]
            // Reserve the final slot for the "and N more" notice, but only once
            // there is actually more than one finding left to describe.
            if seen < displayCap - 1 {
                kept.append(annotation)
                counts[annotation.level] = seen + 1
            } else {
                dropped[annotation.level, default: 0] += 1
            }
        }

        for (level, count) in dropped.sorted(by: { $0.key < $1.key }) {
            // Exactly one over the reserve: show it rather than a notice saying
            // one thing is hidden, which would occupy the same slot.
            if count == 1, let index = annotations.lastIndex(where: { $0.level == level }) {
                kept.append(annotations[index])
                continue
            }
            kept.append(Annotation(
                level: level,
                title: "gattsnap: \(count) more not shown",
                message: "\(count) further \(level)-level findings are not annotated because "
                    + "GitHub displays at most \(displayCap) per level. The job summary and the "
                    + "JSON report contain every finding.",
                line: nil))
        }
        return kept
    }

    private static func command(for annotation: Annotation, file: String?) -> String {
        var properties: [String] = []
        if let file {
            properties.append("file=\(escapeProperty(file))")
            if let line = annotation.line {
                properties.append("line=\(line)")
            }
        }
        properties.append("title=\(escapeProperty(annotation.title))")
        return "::\(annotation.level) \(properties.joined(separator: ","))"
            + "::\(escapeData(annotation.message))"
    }

    // MARK: - Workflow command escaping
    //
    // Not optional. Diff details carry `:` and `,` from UUID paths and property
    // lists, and an unescaped one truncates the command mid-way — GitHub then
    // renders a mangled annotation, or none, with nothing indicating why.

    static func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    static func escapeProperty(_ text: String) -> String {
        escapeData(text)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }
}
