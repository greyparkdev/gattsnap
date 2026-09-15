import Foundation

public struct DiffOptions: Hashable, Sendable {
    /// Off by default. A handle shift is real and breaking, but it fires on any
    /// additive change too, so it is opt-in rather than noise. See D1.
    public var diffHandles: Bool

    /// Promotes warnings into the verdict.
    ///
    /// CI reads exit codes and swallows stdout, so a well-written warning is
    /// invisible exactly where it matters most. A team that wants a quiet hash
    /// difference or a profile mismatch to stop the build can say so, without
    /// making those conditions failures for everyone else.
    public var failOnWarning: Bool

    public init(diffHandles: Bool = false, failOnWarning: Bool = false) {
        self.diffHandles = diffHandles
        self.failOnWarning = failOnWarning
    }
}

public struct DiffReport: Hashable, Sendable, Codable {
    public var changes: [Change]
    public var unobservable: [Unobservable]
    public var warnings: [DiffWarning]
    public var baseProfile: String
    public var headProfile: String
    public var baseStructureHash: String
    public var headStructureHash: String
    /// Recorded so the report is self-describing: a reader can tell whether an
    /// exit code was influenced by `--fail-on-warning` without the invocation.
    public var failOnWarning: Bool

    public init(changes: [Change], unobservable: [Unobservable], warnings: [DiffWarning],
                baseProfile: String, headProfile: String,
                baseStructureHash: String, headStructureHash: String,
                failOnWarning: Bool = false) {
        self.changes = changes
        self.unobservable = unobservable
        self.warnings = warnings
        self.baseProfile = baseProfile
        self.headProfile = headProfile
        self.baseStructureHash = baseStructureHash
        self.headStructureHash = headStructureHash
        self.failOnWarning = failOnWarning
    }

    enum CodingKeys: String, CodingKey {
        case changes, unobservable, warnings
        case baseProfile = "base_profile"
        case headProfile = "head_profile"
        case baseStructureHash = "base_structure_hash"
        case headStructureHash = "head_structure_hash"
        case failOnWarning = "fail_on_warning"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        changes = try c.decode([Change].self, forKey: .changes)
        unobservable = try c.decode([Unobservable].self, forKey: .unobservable)
        warnings = try c.decode([DiffWarning].self, forKey: .warnings)
        baseProfile = try c.decode(String.self, forKey: .baseProfile)
        headProfile = try c.decode(String.self, forKey: .headProfile)
        baseStructureHash = try c.decode(String.self, forKey: .baseStructureHash)
        headStructureHash = try c.decode(String.self, forKey: .headStructureHash)
        failOnWarning = try c.decodeIfPresent(Bool.self, forKey: .failOnWarning) ?? false
    }

    public var highestSeverity: Severity? { changes.map(\.severity).max() }
    public var hasBreaking: Bool { changes.contains { $0.severity == .breaking } }

    /// Only an actually-suppressed finding degrades a run. A standing platform
    /// limitation is reported in full but does not change the verdict — see
    /// `UnobservableCategory`.
    public var isDegraded: Bool {
        unobservable.contains { $0.category == .suppressedComparison }
    }

    public var suppressedComparisons: [Unobservable] {
        unobservable.filter { $0.category == .suppressedComparison }
    }

    public var standingLimitations: [Unobservable] {
        unobservable.filter { $0.category == .standingLimitation }
    }

    public func changes(_ severity: Severity) -> [Change] {
        changes.filter { $0.severity == severity }
    }

    /// `0` clean · `1` additive or cosmetic · `2` breaking · `3` degraded ·
    /// `4` warnings present under `--fail-on-warning`.
    ///
    /// Ordered by how much a reader should worry, not numerically. Breaking
    /// outranks degraded: CI fails on either, and when both are present the
    /// breaking changes are the headline while the degraded section is still
    /// reported in full. What matters is that a degraded comparison can never
    /// collapse to `0` or `1` and be mistaken for a pass.
    ///
    /// `4` is deliberately its own code rather than reusing `3`. A profile
    /// mismatch is not an unobservable attribute range, and folding it into `3`
    /// would make that code mean two unrelated things.
    public var exitCode: Int32 {
        if hasBreaking { return 2 }
        if isDegraded { return 3 }
        if failOnWarning && !warnings.isEmpty { return 4 }
        return changes.isEmpty ? 0 : 1
    }
}
