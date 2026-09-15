import Foundation
import Testing
@testable import GATTSnapshotCore

@Suite("Serialization")
struct SerializationTests {

    @Test("Every fixture decodes and validates", arguments: Fixture.all)
    func fixturesAreValid(name: String) throws {
        let snapshot = try Fixture.snapshot(name)
        #expect(snapshot.schemaVersion == SchemaVersion.current)
        #expect(!snapshot.profile.isEmpty)
    }

    @Test("Recorded structure_hash matches the table", arguments: Fixture.all)
    func fixtureHashesAreCorrect(name: String) throws {
        let snapshot = try Fixture.snapshot(name)
        #expect(snapshot.structureHash == StructureHash.compute(snapshot.table))
        #expect(snapshot.structureHash.hasPrefix("sha256:"))
    }

    @Test("Round-trips byte-for-byte", arguments: Fixture.all)
    func roundTrip(name: String) throws {
        let snapshot = try Fixture.snapshot(name)
        let encoded = try SnapshotCoding.encode(snapshot)
        let decoded = try SnapshotCoding.decode(encoded)
        #expect(decoded == snapshot)
        #expect(try SnapshotCoding.encode(decoded) == encoded)
    }

    @Test("Encoding is deterministic and diff-friendly")
    func encodingIsStable() throws {
        let snapshot = try Fixture.snapshot("variant-a")
        let a = try SnapshotCoding.encodeToString(snapshot)
        let b = try SnapshotCoding.encodeToString(snapshot)
        #expect(a == b)
        // Pretty-printed and newline-terminated, because these files are read
        // in pull-request diffs.
        #expect(a.contains("\n"))
        #expect(a.hasSuffix("\n"))
    }

    @Test("Rejects an unknown schema version")
    func rejectsFutureSchema() throws {
        var raw = try Fixture.text("variant-a")
        raw = raw.replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 99")
        #expect(throws: SnapshotCodingError.unsupportedSchemaVersion(found: 99, supported: 1)) {
            try SnapshotCoding.decode(Data(raw.utf8))
        }
    }

    @Test("Rejects an unknown adapter")
    func rejectsUnknownAdapter() throws {
        let raw = try Fixture.text("variant-a")
            .replacingOccurrences(of: "\"corebluetooth\"", with: "\"telepathy\"")
        #expect(throws: SnapshotCodingError.unknownAdapter(id: "telepathy", version: 1)) {
            try SnapshotCoding.decode(Data(raw.utf8))
        }
    }

    @Test("Rejects a snapshot claiming capabilities its adapter cannot provide")
    func rejectsForgedCapabilities() throws {
        // CoreBluetooth cannot see MAC addresses; a snapshot saying otherwise
        // has been hand-edited and must not be trusted.
        let raw = try Fixture.text("variant-a")
            .replacingOccurrences(of: "\"mac_address\" : false", with: "\"mac_address\" : true")
        #expect(throws: SnapshotCodingError.self) {
            try SnapshotCoding.decode(Data(raw.utf8))
        }
    }

    @Test("Recording fewer capabilities than declared is allowed")
    func opdOutCapabilitiesAreValid() throws {
        // variant-a records handles:false even though CoreBluetooth *can* read
        // them — the user simply did not pass --include-handles. Declaration ∩
        // options, so a subset is expected.
        let snapshot = try Fixture.snapshot("variant-a")
        #expect(!snapshot.adapter.capabilities.canObserve(.handles))
        let declared = AdapterRegistry.declaredCapabilities(id: "corebluetooth", version: 1)
        #expect(declared?.contains(.handles) == true)
    }

    @Test("Rejects a snapshot claiming handles when one attribute lacks one")
    func rejectsIncompleteHandleCoverage() throws {
        let original = try Fixture.snapshot("variant-a-handles")
        var table = original.table
        table.services[0].characteristics[0].handles = nil
        let snapshot = Snapshot(
            profile: original.profile,
            adapter: original.adapter,
            captureMetadata: original.captureMetadata,
            table: table)

        #expect(throws: SnapshotCodingError.incompleteHandleCoverage(
            path: "180A/2A24")) {
            try SnapshotCoding.validate(snapshot)
        }
    }

    @Test("Rejects a snapshot claiming handles when all handles are absent")
    func rejectsEmptyClaimedHandleCoverage() throws {
        let original = try Fixture.snapshot("variant-a")
        let lyingAdapter = AdapterIdentity(
            id: original.adapter.id,
            capabilityVersion: original.adapter.capabilityVersion,
            capabilities: AdapterCapabilities([.handles]))
        let snapshot = Snapshot(
            profile: original.profile,
            adapter: lyingAdapter,
            captureMetadata: original.captureMetadata,
            table: original.table)

        #expect(throws: SnapshotCodingError.incompleteHandleCoverage(path: "180A")) {
            try SnapshotCoding.validate(snapshot)
        }
    }

    @Test("Rejects a tampered attribute table")
    func rejectsHashMismatch() throws {
        // Drop a characteristic without updating the hash — exactly what an
        // edited-by-hand snapshot looks like.
        let raw = try Fixture.text("variant-a").replacingOccurrences(
            of: """
                          {
                            "uuid" : "A2A20000-9E57-4A5B-9C1D-000000000012",
                            "instance" : 0,
                            "properties" : [ "write" ],
                            "descriptors" : []
                          }
                """,
            with: "")
        #expect(throws: SnapshotCodingError.self) {
            try SnapshotCoding.decode(Data(raw.utf8))
        }
    }

    @Test("Rejects an empty profile label")
    func rejectsEmptyProfile() throws {
        let raw = try Fixture.text("variant-a")
            .replacingOccurrences(of: "\"profile\" : \"gattsnap-spike\"", with: "\"profile\" : \"  \"")
        #expect(throws: SnapshotCodingError.emptyProfile) {
            try SnapshotCoding.decode(Data(raw.utf8))
        }
    }

    @Test("structure_hash ignores capture metadata entirely")
    func hashIgnoresMetadata() throws {
        var snapshot = try Fixture.snapshot("variant-a")
        let before = StructureHash.compute(snapshot.table)
        snapshot.captureMetadata.rssi = -99
        snapshot.captureMetadata.capturedAt = "2030-01-01T00:00:00Z"
        snapshot.captureMetadata.host = "somewhere-else"
        snapshot.captureMetadata.peripheralIdentifier = "00000000-0000-0000-0000-000000000000"
        #expect(StructureHash.compute(snapshot.table) == before)
    }

    @Test("Two hosts capturing the same device produce the same structure hash")
    func hostIndependence() throws {
        // The whole point of D2: peripheral.identifier is host-scoped, so it
        // must not influence anything the diff or the hash sees.
        let a = try Fixture.snapshot("variant-a")
        var b = a
        b.captureMetadata.peripheralIdentifier = "FFFFFFFF-1111-2222-3333-444444444444"
        b.captureMetadata.host = "another-mac"
        #expect(a.structureHash == StructureHash.compute(b.table))
    }
}
