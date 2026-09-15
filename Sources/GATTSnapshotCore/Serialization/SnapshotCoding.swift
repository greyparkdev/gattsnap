import Foundation

public enum SnapshotCodingError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case unknownAdapter(id: String, version: Int)
    case capabilitiesExceedAdapterDeclaration(id: String, version: Int, extra: [Capability])
    case incompleteHandleCoverage(path: String)
    case structureHashMismatch(recorded: String, computed: String)
    case emptyProfile

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            "snapshot schema version \(found) is not supported (this build reads version \(supported))"
        case .unknownAdapter(let id, let version):
            "unknown adapter '\(id)' at capability version \(version)"
        case .capabilitiesExceedAdapterDeclaration(let id, let version, let extra):
            "snapshot claims capabilities its adapter cannot provide: "
            + "\(extra.map(\.rawValue).sorted().joined(separator: ", ")) "
            + "(adapter '\(id)' capability version \(version))"
        case .incompleteHandleCoverage(let path):
            "snapshot claims complete handle coverage, but \(path) has no handle"
        case .structureHashMismatch(let recorded, let computed):
            "structure_hash does not match the attribute table "
            + "(recorded \(recorded), computed \(computed)) — the file has been edited or truncated"
        case .emptyProfile:
            "profile label must not be empty"
        }
    }
}

public enum SnapshotCoding {
    /// Pretty-printed with sorted keys because these files live in a git repo
    /// and are read in pull-request diffs. Compactness is worth nothing here;
    /// a clean line-by-line diff is worth a lot.
    public static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(snapshot)
        data.append(0x0A) // trailing newline, so the file is POSIX-clean
        return data
    }

    public static func encodeToString(_ snapshot: Snapshot) throws -> String {
        String(decoding: try encode(snapshot), as: UTF8.self)
    }

    /// Decodes and validates. Validation is deliberately strict: a snapshot that
    /// cannot be vouched for should fail loudly rather than produce a diff
    /// someone might trust.
    ///
    /// `validate: false` exists only for the fixture-maintenance path, where a
    /// hand-written table needs decoding before its hash can be recomputed.
    /// Production reads always validate.
    public static func decode(_ data: Data, validate shouldValidate: Bool = true) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        if shouldValidate { try validate(snapshot) }
        return snapshot
    }

    public static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == SchemaVersion.current else {
            throw SnapshotCodingError.unsupportedSchemaVersion(
                found: snapshot.schemaVersion, supported: SchemaVersion.current)
        }
        guard !snapshot.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SnapshotCodingError.emptyProfile
        }

        let id = snapshot.adapter.id
        let version = snapshot.adapter.capabilityVersion
        guard let declared = AdapterRegistry.declaredCapabilities(id: id, version: version) else {
            throw SnapshotCodingError.unknownAdapter(id: id, version: version)
        }
        // Recorded capabilities are declaration ∩ capture options, so a subset
        // is expected; a superset means the file is lying about what it saw.
        let extra = snapshot.adapter.capabilities.observed.subtracting(declared)
        guard extra.isEmpty else {
            throw SnapshotCodingError.capabilitiesExceedAdapterDeclaration(
                id: id, version: version, extra: Array(extra))
        }

        if snapshot.adapter.capabilities.canObserve(.handles),
           let path = snapshot.table.firstMissingHandlePath {
            throw SnapshotCodingError.incompleteHandleCoverage(path: path)
        }

        let computed = StructureHash.compute(snapshot.table)
        guard computed == snapshot.structureHash else {
            throw SnapshotCodingError.structureHashMismatch(
                recorded: snapshot.structureHash, computed: computed)
        }
    }
}
