import Foundation
import Testing
@testable import GATTSnapshotCore

@Suite("Bluetooth UUID normalization")
struct BluetoothUUIDTests {

    @Test("128-bit UUIDs in the Bluetooth base range collapse to short form")
    func collapsesBaseRange() {
        #expect(BluetoothUUID("0000180A-0000-1000-8000-00805F9B34FB").value == "180A")
        #expect(BluetoothUUID("00002902-0000-1000-8000-00805f9b34fb").value == "2902")
        // Lowercase input, base range, 32-bit assigned number.
        #expect(BluetoothUUID("0001180a-0000-1000-8000-00805f9b34fb").value == "0001180A")
    }

    @Test("Vendor UUIDs outside the base range are preserved, uppercased")
    func preservesVendorUUIDs() {
        let vendor = "AAAA0000-9E57-4A5B-9C1D-000000000001"
        #expect(BluetoothUUID(vendor.lowercased()).value == vendor)
    }

    @Test("A CoreBluetooth short form and a BlueZ long form compare equal")
    func crossAdapterEquality() {
        // Without this, every cross-adapter diff would report every standard
        // service as simultaneously removed and added.
        #expect(BluetoothUUID("180A") == BluetoothUUID("0000180a-0000-1000-8000-00805f9b34fb"))
    }

    @Test("Short UUIDs sort before long ones")
    func sortOrder() {
        let sorted = [BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001"),
                      BluetoothUUID("2A29"),
                      BluetoothUUID("180A")].sorted()
        #expect(sorted.map(\.value) == ["180A", "2A29", "AAAA0000-9E57-4A5B-9C1D-000000000001"])
    }

    @Test("GAP and GATT services are recognized")
    func gapGattDetection() {
        #expect(BluetoothUUID("1800").isGAPOrGATTService)
        #expect(BluetoothUUID("1801").isGAPOrGATTService)
        #expect(!BluetoothUUID("180A").isGAPOrGATTService)
    }
}

@Suite("Table normalization")
struct NormalizationTests {

    @Test("Discovery order does not affect the normalized table")
    func orderIndependence() {
        let a = AttributeTable(services: [
            Service(uuid: BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001"), characteristics: [
                Characteristic(uuid: BluetoothUUID("A2A20000-9E57-4A5B-9C1D-000000000012"), properties: [.write]),
                Characteristic(uuid: BluetoothUUID("A1A10000-9E57-4A5B-9C1D-000000000011"), properties: [.read]),
            ]),
            Service(uuid: BluetoothUUID("180A")),
        ])
        let b = AttributeTable(services: [
            Service(uuid: BluetoothUUID("180A")),
            Service(uuid: BluetoothUUID("AAAA0000-9E57-4A5B-9C1D-000000000001"), characteristics: [
                Characteristic(uuid: BluetoothUUID("A1A10000-9E57-4A5B-9C1D-000000000011"), properties: [.read]),
                Characteristic(uuid: BluetoothUUID("A2A20000-9E57-4A5B-9C1D-000000000012"), properties: [.write]),
            ]),
        ])
        #expect(a.normalized() == b.normalized())
        #expect(StructureHash.compute(a) == StructureHash.compute(b))
    }

    @Test("Same-UUID siblings get stable instance ordinals")
    func duplicateUUIDInstances() {
        let uuid = BluetoothUUID("2A37")
        let table = AttributeTable(services: [
            Service(uuid: BluetoothUUID("180D"), characteristics: [
                Characteristic(uuid: uuid, properties: [.notify]),
                Characteristic(uuid: uuid, properties: [.read]),
            ])
        ]).normalized()
        #expect(table.services[0].characteristics.map(\.instance) == [0, 1])
    }

    @Test("Handles stabilize repeated UUID siblings across discovery order")
    func duplicateUUIDHandleOrder() {
        let uuid = BluetoothUUID("2A37")
        let first = Characteristic(
            uuid: uuid, properties: [.notify],
            handles: CharacteristicHandles(declaration: 2, value: 3))
        let second = Characteristic(
            uuid: uuid, properties: [.read],
            handles: CharacteristicHandles(declaration: 5, value: 6))
        let serviceHandles = ServiceHandles(start: 1, end: 6)
        let a = AttributeTable(services: [Service(
            uuid: BluetoothUUID("180D"), handles: serviceHandles,
            characteristics: [first, second])])
        let b = AttributeTable(services: [Service(
            uuid: BluetoothUUID("180D"), handles: serviceHandles,
            characteristics: [second, first])])

        #expect(a.normalized() == b.normalized())
        // Newly constructed snapshots store this normalized order. Raw schema-1
        // tables retain the original discovery-order hash for compatibility.
        #expect(StructureHash.compute(a.normalized()) == StructureHash.compute(b.normalized()))
    }

    @Test("Normalization is idempotent")
    func idempotent() throws {
        let table = try Fixture.snapshot("variant-a").table
        #expect(table.normalized() == table.normalized().normalized())
    }

    @Test("Properties serialize in GATT bit order, not alphabetically")
    func propertyOrdering() {
        let sorted: [CharacteristicProperty] = [.notify, .read, .write, .broadcast].sorted()
        #expect(sorted == [.broadcast, .read, .write, .notify])
    }
}
