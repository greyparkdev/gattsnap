#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import GATTSnapshotCore

/// Enumerates advertisers for a fixed window.
///
/// Simpler than `CaptureSession`: no connection, so no connect timeout and no
/// discovery walk. Duplicates are enabled so a device that advertises its name
/// in only some packets is still seen with its name — a scanner that misses the
/// name defeats its own purpose.
final class ScanSession: NSObject, @unchecked Sendable {

    private let options: ScanOptions
    private let queue = DispatchQueue(label: "dev.gattsnap.scan")
    private var central: CBCentralManager!
    private var continuation: CheckedContinuation<[DiscoveredPeripheral], Error>?
    private var finished = false
    private var seen: [UUID: DiscoveredPeripheral] = [:]

    init(options: ScanOptions) {
        self.options = options
        super.init()
    }

    func run() async throws -> [DiscoveredPeripheral] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: true])
                self.after(.seconds(45)) {
                    guard self.central.state != .poweredOn else { return }
                    self.fail(CaptureError.notAuthorized(
                        "Bluetooth did not become available (state "
                        + "\(CaptureSession.describe(self.central.state)), authorization "
                        + "\(CaptureSession.describeAuthorization())). See docs/platform-notes.md §1."))
                }
            }
        }
    }

    private func after(_ duration: Duration, _ work: @escaping @Sendable () -> Void) {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.finished else { return }
            work()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        central.stopScan()
        // Everything seen, sorted. Filtering is the caller's decision.
        let results = seen.values.sorted(by: DiscoveredPeripheral.displayOrder)
        continuation?.resume(returning: results)
        continuation = nil
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        if central?.state == .poweredOn { central.stopScan() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

extension ScanSession: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            // Duplicates on: a peripheral may omit its local name from some
            // advertising packets, and one sighting without a name would leave
            // the user with an unmatchable entry.
            manager.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            after(options.duration) { self.finish() }
        case .unauthorized:
            fail(CaptureError.notAuthorized(
                "not authorized to use Bluetooth (\(CaptureSession.describeAuthorization()))"))
        case .unsupported:
            fail(CaptureError.bluetoothUnavailable("this host has no supported Bluetooth LE controller"))
        case .poweredOff:
            fail(CaptureError.bluetoothUnavailable("Bluetooth is turned off"))
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { BluetoothUUID($0.uuidString) }
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexString

        // CoreBluetooth reports 127 when RSSI is unavailable rather than as a
        // real reading; treating it as a signal would sort such entries first.
        let reading = RSSI.intValue
        let rssi: Int? = (reading == 127 || reading == 0) ? nil : reading

        var entry = seen[peripheral.identifier] ?? DiscoveredPeripheral(
            identifier: peripheral.identifier.uuidString)

        // Merge across sightings: keep the best signal and never lose a name or
        // a service list that only appeared in one packet.
        entry.advertisedLocalName = localName ?? entry.advertisedLocalName
        entry.cachedName = peripheral.name ?? entry.cachedName
        entry.isConnectable = connectable ?? entry.isConnectable
        entry.manufacturerDataHex = manufacturer ?? entry.manufacturerDataHex
        if !services.isEmpty { entry.serviceUUIDs = services }
        if let rssi { entry.rssi = max(rssi, entry.rssi ?? Int.min) }

        seen[peripheral.identifier] = entry
    }
}
#endif
