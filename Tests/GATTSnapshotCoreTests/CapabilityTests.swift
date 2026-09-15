import Foundation
import Testing
@testable import GATTSnapshotCore

/// The failure mode these guard against is the worst one this tool has: a
/// cross-adapter diff that quietly drops findings and prints "no changes", so
/// the user reads a clean result and ships. See docs/schema-decisions.md D3.
@Suite("Capabilities — cross-adapter comparison")
struct CapabilityTests {

    @Test("CoreBluetooth's blind spots are declared honestly")
    func coreBluetoothDeclaration() throws {
        let declared = try #require(AdapterRegistry.declaredCapabilities(id: "corebluetooth", version: 1))
        #expect(declared.contains(.handles))          // private API, but real
        #expect(!declared.contains(.macAddress))      // BDAddress returns nil
        #expect(!declared.contains(.gapGattServices)) // filtered from discovery
        #expect(!declared.contains(.advertisingParameters))
    }

    @Test("Comparing a CoreBluetooth snapshot against a BlueZ one is degraded, not clean")
    func crossAdapterIsDegraded() throws {
        // Asymmetric: the BlueZ side carries 0x1800/0x1801 that CoreBluetooth
        // structurally cannot, so findings genuinely get dropped.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a-bluez"))
        #expect(report.isDegraded)
        #expect(report.exitCode == 3)
        #expect(report.exitCode != 0, "a degraded comparison must never look like a pass")
    }

    @Test("GAP/GATT services are reported unobservable, never as removed")
    func gapGattNotReportedAsRemoved() throws {
        // The BlueZ fixture has 0x1800 and 0x1801; the CoreBluetooth one cannot
        // see them. Diffing them must not claim two services disappeared.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                        head: try Fixture.snapshot("variant-a"))

        let removedServices = report.changes.filter { $0.kind == .serviceRemoved }
        #expect(!removedServices.contains { $0.path.service.isGAPOrGATTService })

        let entry = try #require(report.unobservable.first { $0.capability == .gapGattServices })
        #expect(entry.blindAdapters == ["corebluetooth"])
        #expect(entry.detail.contains("0x1800"))
        #expect(entry.detail.contains("corebluetooth"))
    }

    @Test("Suppression is visible in the report, not silent")
    func suppressionIsVisible() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                        head: try Fixture.snapshot("variant-a"))
        // Whatever else it says, it must not be able to claim "no changes".
        #expect(!report.unobservable.isEmpty)
        let capabilities = Set(report.unobservable.map(\.capability))
        #expect(capabilities.contains(.gapGattServices))
        #expect(capabilities.contains(.advertisingParameters))
        // MAC address lives in capture metadata, which the diff cannot see by
        // contract, so it can never suppress a table finding. Listing it would
        // be noise on every single report.
        #expect(!capabilities.contains(.macAddress))
    }

    @Test("Dropped GAP/GATT findings are categorized as a real suppression")
    func droppedFindingsAreSuppression() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"),
                                        head: try Fixture.snapshot("variant-a"))
        let entry = try #require(report.unobservable.first { $0.capability == .gapGattServices })
        #expect(entry.category == .suppressedComparison)
        #expect(entry.detail.contains("dropped from the comparison"))
        #expect(report.isDegraded)
    }

    @Test("Real changes still surface across adapters")
    func realChangesStillReported() throws {
        // Degrading must not swallow findings in ranges both sides *can* see.
        var head = try Fixture.snapshot("variant-a-bluez")
        head.table.services = head.table.services.map { service in
            guard service.uuid == BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001") else { return service }
            var s = service
            s.characteristics = s.characteristics.map { ch in
                var c = ch
                c.properties.remove(.notify)
                return c
            }
            return s
        }
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"), head: head)
        #expect(report.changes.contains { $0.kind == .propertyRemoved })
        #expect(report.hasBreaking)
        #expect(report.exitCode == 2)
        // Both sides are BlueZ here, so nothing was suppressed — the point is
        // that findings in ranges both sides *can* see still surface.
        #expect(!report.isDegraded)
    }

    @Test("Breaking outranks degraded, with the suppressed section still reported")
    func breakingOutranksDegraded() throws {
        var head = try Fixture.snapshot("variant-a")
        head.table.services = head.table.services.filter {
            $0.uuid != BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001")
        }
        // BlueZ base against a CoreBluetooth head: GAP/GATT findings get
        // dropped *and* a real service disappeared.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"), head: head)
        #expect(report.hasBreaking)
        #expect(report.isDegraded)
        #expect(report.exitCode == 2)
        #expect(!report.suppressedComparisons.isEmpty)
    }

    @Test("A shared blind spot is reported, but does not degrade the run")
    func sharedBlindSpotIsStandingLimitation() throws {
        // Both sides are CoreBluetooth, so neither ever saw GAP/GATT and
        // nothing was dropped. Saying so is still the difference between
        // "unchanged" and "unchecked" — but calling it degradation would mark
        // every macOS-to-macOS diff degraded forever, and the signal would
        // rightly be ignored.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a-cosmetic"))
        let entry = try #require(report.unobservable.first { $0.capability == .gapGattServices })
        #expect(entry.category == .standingLimitation)
        #expect(entry.blindAdapters == ["corebluetooth"])
        #expect(entry.detail.contains("neither adapter can observe"))
        #expect(entry.detail.contains("nothing was dropped"))
        #expect(!report.isDegraded)
        #expect(report.exitCode == 1, "a cosmetic change, not a degraded run")
    }

    @Test("Device name is unobservable on CoreBluetooth, not silently unchanged")
    func deviceNameIsUnobservable() throws {
        // 0x2A00 lives in GAP, which CoreBluetooth hides — so a rename cannot
        // be classified cosmetic there. It has to flow through the capability
        // mechanism instead of vanishing from the report.
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a"))
        let entry = try #require(report.unobservable.first { $0.capability == .gapGattServices })
        #expect(entry.detail.contains("device name"))
    }

    @Test("A BlueZ-to-BlueZ comparison is not degraded")
    func fullyCapableComparisonIsClean() throws {
        let a = try Fixture.snapshot("variant-a-bluez")
        let report = DiffEngine.compare(base: a, head: a, options: DiffOptions(diffHandles: true))
        #expect(!report.isDegraded)
        #expect(report.changes.isEmpty)
        #expect(report.exitCode == 0)
    }

    @Test("A BlueZ device-name change is a real, comparable change")
    func bluezSeesDeviceName() throws {
        var head = try Fixture.snapshot("variant-a-bluez")
        head.table.services = head.table.services.map { service in
            guard service.uuid == BluetoothUUID("1800") else { return service }
            var s = service
            s.characteristics = s.characteristics.map { ch in
                var c = ch
                if c.uuid == BluetoothUUID("2A00") { c.valueHex = "72656E616D6564" }
                return c
            }
            return s
        }
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"), head: head)
        // 0x2A00 is not in the Device Information allowlist, so the value change
        // is not currently classified. Recorded here as the known gap it is.
        #expect(!report.isDegraded)
        #expect(report.changes.isEmpty)
    }
}

@Suite("Exit codes")
struct ExitCodeTests {

    @Test("Clean comparison exits 0")
    func cleanIsZero() throws {
        let a = try Fixture.snapshot("variant-a-bluez")
        #expect(DiffEngine.compare(base: a, head: a).exitCode == 0)
    }

    @Test("Cosmetic-only exits 1")
    func cosmeticIsOne() throws {
        var head = try Fixture.snapshot("variant-a-bluez")
        head.table.services = head.table.services.map { service in
            guard service.uuid == BluetoothUUID("180A") else { return service }
            var s = service
            s.characteristics = s.characteristics.map { ch in
                var c = ch
                if c.uuid == BluetoothUUID("2A29") { c.valueHex = "41434D4520436F7270" }
                return c
            }
            return s
        }
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"), head: head)
        #expect(report.changes(.cosmetic).count == 1)
        #expect(report.exitCode == 1)
    }

    @Test("Additive-only exits 1")
    func additiveIsOne() throws {
        var head = try Fixture.snapshot("variant-a-bluez")
        head.table.services.append(
            Service(uuid: BluetoothUUID("BBBB0000-9E57-4A5B-9C1D-000000000002"),
                    handles: ServiceHandles(start: 24, end: 26),
                    characteristics: [
                        Characteristic(uuid: BluetoothUUID("B1B10000-9E57-4A5B-9C1D-000000000021"),
                                       properties: [.read],
                                       handles: CharacteristicHandles(declaration: 25, value: 26))
                    ]))
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a-bluez"), head: head)
        #expect(report.changes(.additive).count == 1)
        #expect(report.exitCode == 1)
    }

    @Test("Breaking exits 2")
    func breakingIsTwo() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-b"))
        #expect(report.exitCode == 2)
    }

    @Test("Degraded exits 3")
    func degradedIsThree() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-a"),
                                        options: DiffOptions(diffHandles: true))
        #expect(report.exitCode == 3)
    }

    @Test("Breaking outranks degraded, and degraded never collapses to a pass")
    func precedence() throws {
        let report = DiffEngine.compare(base: try Fixture.snapshot("variant-a"),
                                        head: try Fixture.snapshot("variant-b"),
                                        options: DiffOptions(diffHandles: true))
        #expect(report.hasBreaking)
        #expect(report.isDegraded)
        #expect(report.exitCode == 2)
        // The invariant that actually matters.
        #expect(report.exitCode != 0)
        #expect(report.exitCode != 1)
    }
}
