import Foundation
import CoreBluetooth

// `blespike serve --variant a|b` publishes a GATT table we fully control, so
// the caching question can be answered against a *real structural mutation*
// rather than inferred from timing. Run this on a second Mac (a Mac cannot
// discover its own advertisements), then run `blespike cache` from this one.
//
// Variant B differs from A by:
//   - A1 loses `notify`            -> breaking (property dropped, CCCD gone)
//   - A2 removed entirely          -> breaking (characteristic removed)
//   - A3 added                     -> additive
//   - service BBBB added           -> additive

let svcA = CBUUID(string: "AAAA0000-9E57-4A5B-9C1D-000000000001")
let svcB = CBUUID(string: "BBBB0000-9E57-4A5B-9C1D-000000000002")
let chA1 = CBUUID(string: "A1A10000-9E57-4A5B-9C1D-000000000011")
let chA2 = CBUUID(string: "A2A20000-9E57-4A5B-9C1D-000000000012")
let chA3 = CBUUID(string: "A3A30000-9E57-4A5B-9C1D-000000000013")
let chB1 = CBUUID(string: "B1B10000-9E57-4A5B-9C1D-000000000021")

final class Server: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private let variant: String
    private let localName: String

    init(variant: String, localName: String) {
        self.variant = variant.lowercased()
        self.localName = localName
        super.init()
    }

    func run() {
        log("== blespike serve — variant \(variant.uppercased()), advertising as '\(localName)' ==")
        manager = CBPeripheralManager(delegate: self, queue: .main)
        RunLoop.main.run()
    }

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        log("peripheral manager state = \(m.state.rawValue) (5 == poweredOn)")
        guard m.state == .poweredOn else { return }
        m.removeAllServices()

        var services: [CBMutableService] = []

        let a = CBMutableService(type: svcA, primary: true)
        if variant == "a" {
            // notify implies a CCCD; CoreBluetooth adds 0x2902 itself.
            let c1 = CBMutableCharacteristic(type: chA1, properties: [.read, .notify],
                                             value: nil, permissions: [.readable])
            let c2 = CBMutableCharacteristic(type: chA2, properties: [.write],
                                             value: nil, permissions: [.writeable])
            a.characteristics = [c1, c2]
        } else {
            let c1 = CBMutableCharacteristic(type: chA1, properties: [.read],
                                             value: nil, permissions: [.readable])
            let c3 = CBMutableCharacteristic(type: chA3, properties: [.read, .write],
                                             value: nil, permissions: [.readable, .writeable])
            a.characteristics = [c1, c3]
        }
        services.append(a)

        if variant != "a" {
            let b = CBMutableService(type: svcB, primary: true)
            b.characteristics = [CBMutableCharacteristic(type: chB1, properties: [.read],
                                                        value: Data([0x42]), permissions: [.readable])]
            services.append(b)
        }

        for s in services { m.add(s) }

        m.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [svcA],
        ])
        log("advertising. structure:")
        for s in services {
            log("  service \(s.uuid.uuidString)")
            for c in s.characteristics ?? [] {
                log("    char \(c.uuid.uuidString) props=\(propertyNames(c.properties).joined(separator: "|"))")
            }
        }
        log("Ctrl-C to stop; relaunch with the other --variant to mutate the table.")
    }

    func peripheralManager(_ m: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { log("!! didAdd \(service.uuid) error: \(error)") }
    }

    func peripheralManagerDidStartAdvertising(_ m: CBPeripheralManager, error: Error?) {
        if let error { log("!! advertising error: \(error)") }
    }
}
