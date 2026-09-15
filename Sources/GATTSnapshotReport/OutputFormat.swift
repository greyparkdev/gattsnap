import Foundation
import GATTSnapshotCore

/// How a `DiffReport` is rendered.
///
/// Rendering lives here rather than in `GATTSnapshotCore` so the model, schema
/// and diff engine stay free of presentation concerns, and rather than in the
/// executable so every format can be unit tested. JUnit XML and workflow
/// commands in particular are exactly the kind of string assembly that rots
/// silently without tests.
public enum OutputFormat: String, CaseIterable, Sendable {
    case human
    case json
    case junit
    /// GitHub Actions workflow commands — inline annotations on the snapshot file.
    case github
    /// Markdown, for a job summary or a pull-request comment.
    case markdown

    public static func parse(_ raw: String) -> OutputFormat? {
        OutputFormat(rawValue: raw.lowercased())
    }

    public static var allNames: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

public enum ReportRenderer {
    /// - Parameter target: where GitHub annotations should point. Only the
    ///   `github` format reads it, and it stays optional so that format still
    ///   produces log-visible annotations when there is no file to attach them
    ///   to — a diff of two snapshots outside the workspace, for instance.
    public static func render(_ report: DiffReport,
                              format: OutputFormat,
                              baseLabel: String,
                              headLabel: String,
                              useColor: Bool,
                              target: AnnotationTarget? = nil) throws -> String {
        switch format {
        case .human:
            HumanReportRenderer(useColor: useColor)
                .render(report, baseLabel: baseLabel, headLabel: headLabel)
        case .json:
            try JSONReportRenderer.render(report, baseLabel: baseLabel, headLabel: headLabel)
        case .junit:
            JUnitReportRenderer.render(report, baseLabel: baseLabel, headLabel: headLabel)
        case .github:
            GitHubReportRenderer.render(report, baseLabel: baseLabel, headLabel: headLabel,
                                        target: target)
        case .markdown:
            MarkdownReportRenderer.render(report, baseLabel: baseLabel, headLabel: headLabel)
        }
    }
}

/// Shared vocabulary so the three renderers cannot drift on what a code means.
public enum ExitCodeMeaning {
    public static func describe(_ code: Int32) -> String {
        switch code {
        case 0: "no changes"
        case 1: "additive or cosmetic changes only"
        case 2: "breaking changes present"
        case 3: "degraded — findings were dropped from an unobservable range"
        case 4: "warnings present, and --fail-on-warning was set"
        default: "unknown"
        }
    }
}

extension Severity {
    var headline: String {
        switch self {
        case .breaking: "BREAKING"
        case .additive: "ADDITIVE"
        case .cosmetic: "COSMETIC"
        }
    }
}

func wrapText(_ text: String, width: Int, indent: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count <= width {
            current += " " + word
        } else {
            lines.append(indent + current)
            current = String(word)
        }
    }
    if !current.isEmpty { lines.append(indent + current) }
    return lines
}
