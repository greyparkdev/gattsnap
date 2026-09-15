import Foundation
import Testing
@testable import GATTSnapshotCore

@Suite("Diff — severity classification")
struct DiffSeverityTests {

    @Test("A snapshot against itself is clean")
    func identityIsClean() throws {
        let a = try Fixture.snapshot("variant-a")
        let report = DiffEngine.compare(base: a, head: a)
        #expect(report.changes.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.exitCode == 0)
        // CoreBluetooth's standing blind spots are still reported — they just
        // do not make an otherwise-clean run look like a failure.
        #expect(!report.isDegraded)
        #expect(report.standingLimitations.contains { $0.capability == .gapGattServices })
    }

    /// variant-a → variant-b is the mutation `blespike serve` performs, so this
    /// is the same change M3 will exercise against real hardware.
    @Test("The serve A→B mutation classifies as expected")
    func serveMutation() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-b"))

        let kinds = Set(report.changes.map(\.kind))
        // Breaking: A1 lost notify, its CCCD went with it, A2 removed.
        #expect(kinds.contains(.propertyRemoved))
        #expect(kinds.contains(.descriptorRemoved))
        #expect(kinds.contains(.characteristicRemoved))
        // Additive: A3 added, service BBBB added.
        #expect(kinds.contains(.characteristicAdded))
        #expect(kinds.contains(.serviceAdded))

        #expect(report.hasBreaking)
        #expect(report.exitCode == 2)
        #expect(report.changes(.breaking).count == 3)
        #expect(report.changes(.additive).count == 2)
        #expect(report.changes(.cosmetic).isEmpty)
    }

    @Test("Dropping notify is breaking")
    func propertyRemovalIsBreaking() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-b"))
        let change = try #require(report.changes.first { $0.kind == .propertyRemoved })
        #expect(change.severity == .breaking)
        #expect(change.detail.contains("notify"))
        #expect(change.path.characteristic == BluetoothUUID("A1A10000-9E57-4A5B-9C1D-000000000011"))
    }

    @Test("A vanished CCCD is called out for what it breaks")
    func cccdRemovalIsExplicit() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-b"))
        let change = try #require(report.changes.first { $0.kind == .descriptorRemoved })
        #expect(change.severity == .breaking)
        #expect(change.detail.contains("CCCD"))
        #expect(change.detail.contains("subscribe"))
    }

    @Test("Reversing the diff turns removals into additions")
    func reverseDirection() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-b"),
                                        head: try Fixture.snapshot("variant-a"))
        let kinds = Set(report.changes.map(\.kind))
        #expect(kinds.contains(.serviceRemoved))
        #expect(kinds.contains(.propertyAdded))
        #expect(kinds.contains(.descriptorAdded))
        // Going backwards drops service BBBB and characteristic A3, so this
        // direction is breaking too, just for different reasons.
        #expect(report.exitCode == 2)
    }

    @Test("A manufacturer string change is cosmetic, not breaking")
    func manufacturerChangeIsCosmetic() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a-cosmetic"))
        let change = try #require(report.changes.first { $0.kind == .deviceInformationChanged })
        #expect(change.severity == .cosmetic)
        #expect(change.detail.contains("manufacturer_name"))
        // DIS values are UTF-8 in practice, so the message shows them readably.
        #expect(change.detail.contains("\"ACME\""))
        #expect(change.detail.contains("\"ACME Corp\""))
        #expect(!report.hasBreaking)
        #expect(report.exitCode == 1)
    }

    @Test("A changed CCCD value is not a change at all")
    func descriptorValuesAreNotDiffed() throws {
        // variant-a-cosmetic also flips the CCCD value from 0000 to 0100. That
        // is per-connection subscription state, not table structure, and must
        // not show up as a change.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a-cosmetic"))
        #expect(report.changes.count == 1)
        #expect(report.changes[0].kind == .deviceInformationChanged)
    }

    @Test("Output order is stable and most-severe-first")
    func stableOrdering() throws {
        let a = try Fixture.snapshot("variant-a")
        let b = try Fixture.snapshot("variant-b")
        let first = DiffEngine.compare(base: a, head: b).changes
        let second = DiffEngine.compare(base: a, head: b).changes
        #expect(first == second)
        #expect(first.map(\.severity) == first.map(\.severity).sorted(by: >))
    }
}

@Suite("Diff — handles")
struct DiffHandleTests {

    @Test("Handle shifts are invisible by default")
    func handlesIgnoredByDefault() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"))
        #expect(report.changes.isEmpty)
        #expect(report.exitCode == 0)
    }

    @Test("With --diff-handles a shift is breaking and names bonded clients")
    func handleShiftIsBreaking() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"),
                                        options: DiffOptions(diffHandles: true))
        let shifts = report.changes.filter { $0.kind == .handleShift }
        #expect(!shifts.isEmpty)
        #expect(shifts.allSatisfy { $0.severity == .breaking })
        #expect(report.exitCode == 2)

        // The distinct message is the point: this breaks bonded clients in the
        // field while a fresh re-discovery test passes clean.
        let note = try #require(shifts.first?.note)
        #expect(note.contains("bonded"))
        #expect(note.contains("Service Changed"))
        #expect(note.contains("re-discovery"))
    }

    @Test("A handle shift is a distinct kind, not a property change")
    func handleShiftIsItsOwnClass() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"),
                                        options: DiffOptions(diffHandles: true))
        // Nothing structural changed — only the handles moved.
        #expect(report.changes.allSatisfy { $0.kind == .handleShift })
    }

    @Test("structure_hash catches a handle shift")
    func hashCoversHandles() throws {
        // The cheap CI check has to see this, or the case D1 exists for slips
        // through whenever a team only compares hashes.
        let a = try Fixture.snapshot("variant-a-handles")
        let b = try Fixture.snapshot("variant-a-handles-shifted")
        #expect(a.structureHash != b.structureHash)
    }

    @Test("Handles do not degrade a diff when they are not being compared")
    func handlesDoNotDegradeByDefault() throws {
        // variant-a records handles:false. Without --diff-handles that is
        // irrelevant, so the run must not be marked degraded and handles must
        // not even appear in the report.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a"))
        #expect(!report.isDegraded)
        #expect(report.exitCode == 0)
        #expect(!report.unobservable.contains { $0.capability == .handles })
    }

    @Test("Asking for handles the capture did not record degrades the diff")
    func missingHandlesDegrade() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a"),
                                        options: DiffOptions(diffHandles: true))
        #expect(report.isDegraded)
        #expect(report.unobservable.contains { $0.capability == .handles })
        #expect(report.exitCode == 3)
    }

    @Test("A descriptor-only handle move is breaking")
    func descriptorHandleShift() throws {
        let base = try Fixture.snapshot("variant-a-handles")
        var table = base.table
        table.services[1].characteristics[0].descriptors[0].handle = 23
        let head = Snapshot(profile: base.profile, adapter: base.adapter,
                            captureMetadata: base.captureMetadata, table: table)

        let report = DiffEngine.compare(
            base: base, head: head, options: DiffOptions(diffHandles: true))
        let shifts = report.changes.filter { $0.kind == .handleShift }
        #expect(shifts.count == 1)
        #expect(shifts[0].path.descriptor == BluetoothUUID("2902"))
        #expect(shifts[0].detail.contains("0x0014"))
        #expect(shifts[0].detail.contains("0x0017"))
        #expect(report.exitCode == 2)
        #expect(!report.warnings.contains { $0.kind == .quietHashDifference })
    }

    @Test("Incomplete claimed handle coverage degrades the table API")
    func incompleteHandlesDegrade() throws {
        let base = try Fixture.snapshot("variant-a-handles")
        var incomplete = base.table
        incomplete.services[1].characteristics[0].descriptors[0].handle = nil

        let result = DiffEngine.compare(
            base: base.table,
            head: incomplete,
            baseCapabilities: base.adapter.capabilities,
            headCapabilities: base.adapter.capabilities,
            baseAdapterID: "base",
            headAdapterID: "head",
            options: DiffOptions(diffHandles: true))
        let gap = try #require(result.unobservable.first { $0.capability == .handles })
        #expect(gap.category == .suppressedComparison)
        #expect(gap.detail.contains("incomplete coverage"))
    }
}

@Suite("Diff — repeated UUID identity")
struct DuplicateIdentityTests {

    @Test("Repeated UUIDs without handles produce an explicit warning")
    func warnsAboutAmbiguity() throws {
        let original = try Fixture.snapshot("variant-a")
        let duplicateUUID = BluetoothUUID("2A37")
        let table = AttributeTable(services: [Service(
            uuid: BluetoothUUID("180D"),
            characteristics: [
                Characteristic(uuid: duplicateUUID, properties: [.notify]),
                Characteristic(uuid: duplicateUUID, properties: [.read]),
            ])])
        let reversed = AttributeTable(services: [Service(
            uuid: BluetoothUUID("180D"),
            characteristics: Array(table.services[0].characteristics.reversed()))])
        let base = Snapshot(profile: original.profile, adapter: original.adapter,
                            captureMetadata: original.captureMetadata, table: table)
        let head = Snapshot(profile: original.profile, adapter: original.adapter,
                            captureMetadata: original.captureMetadata, table: reversed)

        let report = DiffEngine.compare(base: base, head: head)
        let warning = try #require(report.warnings.first { $0.kind == .ambiguousIdentity })
        #expect(warning.message.contains("180D/2A37"))
        #expect(report.changes.contains { $0.kind == .propertyRemoved })
    }
}

@Suite("Diff — profile labels")
struct DiffProfileTests {

    @Test("Mismatched profile labels warn but never fail")
    func profileMismatchWarns() throws {
        let a = try Fixture.snapshot("variant-a")
        var b = a
        b.profile = "some-other-product"

        let report = DiffEngine.compare(base: a, head: b)
        #expect(report.warnings.count == 1)
        #expect(report.warnings[0].message.contains("gattsnap-spike"))
        #expect(report.warnings[0].message.contains("some-other-product"))
        // A warning must not change the verdict — the label is not the diff key.
        #expect(report.changes.isEmpty)
        #expect(report.exitCode == 0)
    }

    @Test("Matching labels produce no warning")
    func matchingProfilesAreQuiet() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a-cosmetic"))
        #expect(report.warnings.isEmpty)
    }
}

/// `structure_hash` is sold to CI as the cheap "did anything change at all"
/// check. Whenever it fires and the diff does not, the two signals contradict
/// each other — so the report has to say why rather than leave the reader with
/// an unexplained mismatch.
@Suite("Diff — hash and diff disagreeing")
struct HashDisagreementTests {

    @Test("An undiffed handle shift is explained, not left dangling")
    func handleShiftExplained() throws {
        let base = try Fixture.snapshot("variant-a-handles")
        let head = try Fixture.snapshot("variant-a-handles-shifted")
        #expect(base.structureHash != head.structureHash)

        let report = DiffEngine.compare(base: base, head: head)
        #expect(report.changes.isEmpty)

        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.message.contains("--diff-handles"))
        // Option 3: explain, do not change the verdict.
        #expect(report.exitCode == 0)
    }

    @Test("Turning on --diff-handles removes the warning by reporting the changes")
    func warningDisappearsWhenExplained() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-handles"),
                                        head: try Fixture.snapshot("variant-a-handles-shifted"),
                                        options: DiffOptions(diffHandles: true))
        #expect(!report.warnings.contains { $0.kind == .quietHashDifference })
        #expect(report.exitCode == 2)
    }

    @Test("Suppressed ranges are named as a cause too")
    func suppressionExplainsHashDifference() throws {
        // BlueZ against CoreBluetooth: the GAP/GATT services make the hashes
        // differ, and the findings that would have explained it were dropped.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                        head: try Fixture.snapshot("variant-a"))
        #expect(report.changes.isEmpty)
        let warning = try #require(report.warnings.first { $0.kind == .quietHashDifference })
        #expect(warning.message.contains("degraded section"))
    }

    @Test("Matching hashes never produce the warning")
    func identicalHashesAreQuiet() throws {
        let a = try Fixture.snapshot("variant-a")
        let report = DiffEngine.compare(base: a, head: a, options: DiffOptions(diffHandles: true))
        #expect(!report.warnings.contains { $0.kind == .quietHashDifference })
    }

    @Test("A reported change means no warning is needed")
    func realChangesNeedNoExplanation() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-b"))
        #expect(report.baseStructureHash != report.headStructureHash)
        #expect(!report.changes.isEmpty)
        #expect(!report.warnings.contains { $0.kind == .quietHashDifference })
    }
}
