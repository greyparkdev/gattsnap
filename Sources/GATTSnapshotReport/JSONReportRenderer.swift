import Foundation
import GATTSnapshotCore

/// Machine-readable report.
///
/// Wraps `DiffReport` rather than encoding it bare so the output carries the
/// things a consumer needs but the engine has no business knowing: which files
/// were compared, and the resulting exit code. A tool parsing this should not
/// have to re-derive the verdict from the parts.
public enum JSONReportRenderer {

    struct Envelope: Encodable {
        let tool: String
        let toolVersion: String
        let base: String
        let head: String
        let exitCode: Int32
        let exitMeaning: String
        let summary: Summary
        let report: DiffReport

        enum CodingKeys: String, CodingKey {
            case tool, base, head, summary, report
            case toolVersion = "tool_version"
            case exitCode = "exit_code"
            case exitMeaning = "exit_meaning"
        }
    }

    struct Summary: Encodable {
        let breaking: Int
        let additive: Int
        let cosmetic: Int
        let suppressed: Int
        let standingLimitations: Int
        let warnings: Int
        let degraded: Bool

        enum CodingKeys: String, CodingKey {
            case breaking, additive, cosmetic, suppressed, warnings, degraded
            case standingLimitations = "standing_limitations"
        }
    }

    public static func render(_ report: DiffReport,
                              baseLabel: String,
                              headLabel: String,
                              toolVersion: String = "0.1.0") throws -> String {
        let envelope = Envelope(
            tool: "gattsnap",
            toolVersion: toolVersion,
            base: baseLabel,
            head: headLabel,
            exitCode: report.exitCode,
            exitMeaning: ExitCodeMeaning.describe(report.exitCode),
            summary: Summary(
                breaking: report.changes(.breaking).count,
                additive: report.changes(.additive).count,
                cosmetic: report.changes(.cosmetic).count,
                suppressed: report.suppressedComparisons.count,
                standingLimitations: report.standingLimitations.count,
                warnings: report.warnings.count,
                degraded: report.isDegraded),
            report: report)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self) + "\n"
    }
}
