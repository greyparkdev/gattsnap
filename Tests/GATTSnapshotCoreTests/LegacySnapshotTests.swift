import Foundation
import Testing
@testable import GATTSnapshotCore

@Suite("Schema-1 snapshot compatibility")
struct LegacySnapshotTests {
    // Written by the actual Core implementation at fecf23a, not by the current
    // encoder. Deliberately excluded from Fixture.all's hash regeneration.
    private let fixture = "legacy-v1-duplicate-handles"

    @Test("Previously written snapshots validate and retain their exact bytes")
    func originalFileRoundTrips() throws {
        let data = try Fixture.data(fixture)
        let original = try SnapshotCoding.decode(data)
        #expect(original.schemaVersion == 1)
        #expect(original.structureHash ==
            "sha256:f5964d0718173fa82f7f1757b49fb7a69e1ceec7a1aa525514ba52fdff43e984")
        #expect(original.table.services[0].characteristics.map { $0.handles?.declaration } == [5, 2])
        #expect(try SnapshotCoding.encode(original) == data)
        #expect(DiffEngine.compare(base: original, head: original,
                                  options: DiffOptions(diffHandles: true)).exitCode == 0)
    }

    @Test("Old and newly ordered snapshots compare without false changes", arguments: [false, true])
    func compareToNewSnapshot(diffHandles: Bool) throws {
        let original = try Fixture.snapshot(fixture)
        let current = Snapshot(profile: original.profile, adapter: original.adapter,
                               captureMetadata: original.captureMetadata, table: original.table)
        try SnapshotCoding.validate(current)
        #expect(current.schemaVersion == 1)
        #expect(current.table.services[0].characteristics.map { $0.handles?.declaration } == [2, 5])
        #expect(current.structureHash != original.structureHash)
        let report = DiffEngine.compare(base: original, head: current,
                                        options: DiffOptions(diffHandles: diffHandles))
        #expect(report.changes.isEmpty)
        #expect(report.exitCode == 0)
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.causes == [.storedOrderDiffers])
        #expect(!report.warnings.contains { $0.kind == .ambiguousIdentity })

        let strict = DiffEngine.compare(base: original, head: current,
            options: DiffOptions(diffHandles: diffHandles, failOnWarning: true))
        #expect(strict.exitCode == 4)
    }

    @Test("Compatibility never accepts changed data with an old hash")
    func rejectsTampering() throws {
        var original = try Fixture.snapshot(fixture)
        original.table.services[0].characteristics[0].properties = [.write]
        let encoded = try SnapshotCoding.encode(original)
        #expect(throws: SnapshotCodingError.structureHashMismatch(
            recorded: original.structureHash,
            computed: StructureHash.compute(original.table))) {
            try SnapshotCoding.decode(encoded)
        }
    }

    @Test("A real change still surfaces when comparing an old baseline")
    func catchesHandleChange() throws {
        let original = try Fixture.snapshot(fixture)
        var table = original.table
        table.services[0].characteristics[0].handles?.value = 7
        let current = Snapshot(profile: original.profile, adapter: original.adapter,
                               captureMetadata: original.captureMetadata, table: table)
        try SnapshotCoding.validate(current)
        let report = DiffEngine.compare(base: original, head: current,
                                        options: DiffOptions(diffHandles: true))
        #expect(report.exitCode == 2)
        #expect(report.changes.count == 1)
        #expect(report.changes.first?.kind == .handleShift)
        #expect(report.warnings.isEmpty)
    }
}
