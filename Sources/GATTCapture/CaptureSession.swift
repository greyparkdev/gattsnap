#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import GATTSnapshotCore
#if os(macOS)
import GATTHandleProbe
#endif

/// Drives one capture: scan, match, connect, discover, read, disconnect.
///
/// Confined to a single serial queue; every delegate callback and every timeout
/// runs there, so the mutable state needs no further synchronization. The whole
/// run resolves exactly one continuation, guarded by `finished`.
final class CaptureSession: NSObject, @unchecked Sendable {

    private let options: CaptureOptions
    private let queue = DispatchQueue(label: "dev.gattsnap.capture")
    private var central: CBCentralManager!
    private var continuation: CheckedContinuation<Snapshot, Error>?
    private var finished = false

    private var target: CBPeripheral?
    private var advertisedName: String?
    private var advertisementConnectable: Bool?
    private var rssi: Int?
    private var scannedCount = 0

    private var discoveryStart = Date()
    private var discoveryMs: Double = 0

    // Outstanding async work; the walk is complete when all reach zero.
    private var pendingIncluded = 0
    private var pendingCharacteristics = 0
    private var pendingDescriptors = 0
    private var pendingDescriptorReads = 0
    private var pendingValueReads = 0
    private var walkComplete = false

    private var descriptorValues: [ObjectIdentifier: String] = [:]
    private var characteristicValues: [ObjectIdentifier: String] = [:]

    init(options: CaptureOptions) {
        self.options = options
        super.init()
    }

    func run() async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: true])
                self.scheduleAuthorizationTimeout()
            }
        }
    }

    // MARK: - Completion

    private func succeed(_ snapshot: Snapshot) {
        guard !finished else { return }
        finished = true
        if let target { central.cancelPeripheralConnection(target) }
        central.stopScan()
        continuation?.resume(returning: snapshot)
        continuation = nil
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        if let target { central.cancelPeripheralConnection(target) }
        if central?.state == .poweredOn { central.stopScan() }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func after(_ duration: Duration, _ work: @escaping @Sendable () -> Void) {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.finished else { return }
            work()
        }
    }

    /// The state callback never arriving is itself a failure mode: on macOS a
    /// process awaiting a TCC decision sits at `.notDetermined` indefinitely
    /// rather than being told no (platform-notes §1). The window has to be long
    /// enough for a human to answer the permission dialog on a first run.
    private func scheduleAuthorizationTimeout() {
        after(options.authorizationTimeout) {
            guard self.central.state != .poweredOn else { return }
            self.fail(CaptureError.notAuthorized(self.authorizationDiagnosis()))
        }
    }

    /// Names the actual cause rather than listing every possibility. The three
    /// failures look identical from the outside and have completely different
    /// fixes, so guessing wrong sends people down the wrong path.
    private func authorizationDiagnosis() -> String {
        let state = Self.describe(central.state)
        let authorization = Self.describeAuthorization()
        let waited = options.authorizationTimeout

        switch CBManager.authorization {
        case .notDetermined:
            return """
                Bluetooth permission has not been granted or denied yet (state \(state), \
                authorization \(authorization)) after \(waited).

                macOS is almost certainly showing a permission dialog that nobody answered, or \
                suppressed one because this process has no bundle identity. Try:
                  1. Run this again with a person at the keyboard and click Allow.
                  2. Check System Settings > Privacy & Security > Bluetooth.
                  3. Confirm you launched the .app bundle path, not .build/…/gattsnap.
                On a headless CI runner no one can answer: that needs an MDM-deployed PPPC \
                profile. See docs/platform-notes.md §1.
                """
        case .denied, .restricted:
            return """
                Bluetooth access is \(authorization) for gattsnap. Grant it in \
                System Settings > Privacy & Security > Bluetooth, then run again.
                """
        case .allowedAlways:
            return """
                Bluetooth is authorized but the controller never became available \
                (state \(state)) after \(waited). Bluetooth may be turned off, or the \
                controller may be wedged — toggling Bluetooth usually clears it.
                """
        @unknown default:
            return "Bluetooth did not become available after \(waited) "
                 + "(state \(state), authorization \(authorization))."
        }
    }

    // MARK: - Central delegate

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            startScan()
        case .unauthorized:
            fail(CaptureError.notAuthorized(
                "the process is not authorized to use Bluetooth (\(Self.describeAuthorization()))"))
        case .unsupported:
            fail(CaptureError.bluetoothUnavailable("this host has no supported Bluetooth LE controller"))
        case .poweredOff:
            fail(CaptureError.bluetoothUnavailable("Bluetooth is turned off"))
        case .resetting, .unknown:
            break // transient; the authorization timeout is the backstop
        @unknown default:
            break
        }
    }

    private func startScan() {
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        after(options.scanTimeout) {
            guard self.target == nil else { return }
            self.fail(CaptureError.noPeripheralMatched(self.options.target,
                                                       scannedCount: self.scannedCount))
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        scannedCount += 1
        guard target == nil else { return }

        // Match on what is on the air, not on `peripheral.name`: that is
        // system-cached and survives a device rename (platform-notes §4).
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard matches(peripheral, localName: localName) else { return }

        target = peripheral
        advertisedName = localName
        advertisementConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        rssi = RSSI.intValue
        central.stopScan()

        if advertisementConnectable == false {
            fail(CaptureError.peripheralNotConnectable(name: localName ?? peripheral.name ?? "?"))
            return
        }

        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        // CoreBluetooth never times out a connection attempt on its own — a
        // peripheral can match, accept connect, and never call back at all.
        // Reads `self.target` rather than capturing the CBPeripheral, which is
        // not Sendable; everything here is confined to `queue` regardless.
        let displayName = localName ?? peripheral.name ?? "?"
        after(options.connectTimeout) {
            guard let target = self.target, target.state != .connected else { return }
            self.fail(CaptureError.connectTimedOut(
                name: displayName, after: self.options.connectTimeout))
        }
    }

    private func matches(_ peripheral: CBPeripheral, localName: String?) -> Bool {
        switch options.target {
        case .name(let wanted):
            return [localName, peripheral.name].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(wanted) }
        case .identifier(let wanted):
            return peripheral.identifier.uuidString.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        discoveryStart = Date()
        peripheral.discoverServices(nil)
        after(.seconds(30)) {
            self.fail(CaptureError.discoveryFailed("attribute discovery did not complete within 30s"))
        }
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        fail(CaptureError.discoveryFailed(
            "connection failed: \(error?.localizedDescription ?? "no reason given")"))
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard !finished, !walkComplete else { return }
        fail(CaptureError.discoveryFailed(
            "peripheral disconnected mid-capture: \(error?.localizedDescription ?? "no reason given")"))
    }

    // MARK: - Peripheral delegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        discoveryMs = (Date().timeIntervalSince(discoveryStart) * 1000).rounded()

        if let error {
            fail(CaptureError.discoveryFailed("service discovery failed: \(error.localizedDescription)"))
            return
        }

        // Refuse before doing any more work: if this table came from a cache,
        // nothing built on it can be vouched for.
        switch options.cacheDetection.evaluate(durationMs: discoveryMs) {
        case .suspectedCache(let ms, let threshold):
            fail(CaptureError.suspectedCachedTable(durationMs: ms, threshold: threshold))
            return
        case .liveRead, .notChecked:
            break
        }

        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            fail(CaptureError.discoveryFailed("peripheral reported no services"))
            return
        }

        pendingIncluded = services.count
        pendingCharacteristics = services.count
        for service in services {
            peripheral.discoverIncludedServices(nil, for: service)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService,
                    error: Error?) {
        pendingIncluded -= 1
        if let error {
            fail(CaptureError.discoveryFailed(
                "included services of \(service.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        maybeFinish(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        pendingCharacteristics -= 1
        if let error {
            fail(CaptureError.discoveryFailed(
                "characteristics of \(service.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        let characteristics = service.characteristics ?? []
        pendingDescriptors += characteristics.count
        for characteristic in characteristics {
            peripheral.discoverDescriptors(for: characteristic)
            // Only the Device Information allowlist is read. General
            // characteristic reads can have side effects on real firmware, and
            // their values are runtime state the diff ignores anyway.
            if DeviceInformation.isDiffableValue(
                service: BluetoothUUID(service.uuid.uuidString),
                characteristic: BluetoothUUID(characteristic.uuid.uuidString)),
               characteristic.properties.contains(.read) {
                pendingValueReads += 1
                peripheral.readValue(for: characteristic)
            }
        }
        maybeFinish(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        pendingDescriptors -= 1
        if let error {
            fail(CaptureError.discoveryFailed(
                "descriptors of \(characteristic.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        for descriptor in characteristic.descriptors ?? [] {
            pendingDescriptorReads += 1
            peripheral.readValue(for: descriptor)
        }
        maybeFinish(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor,
                    error: Error?) {
        pendingDescriptorReads -= 1
        if error == nil, let hex = Self.hex(fromDescriptorValue: descriptor.value) {
            descriptorValues[ObjectIdentifier(descriptor)] = hex
        }
        maybeFinish(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        pendingValueReads -= 1
        if let error {
            fail(CaptureError.discoveryFailed(
                "value of \(characteristic.uuid.uuidString): \(error.localizedDescription)"))
            return
        }
        guard let data = characteristic.value else {
            fail(CaptureError.discoveryFailed(
                "value of \(characteristic.uuid.uuidString) was absent after a successful read"))
            return
        }
        characteristicValues[ObjectIdentifier(characteristic)] = data.hexString
        maybeFinish(peripheral)
    }

    // MARK: - Assembly

    private func maybeFinish(_ peripheral: CBPeripheral) {
        guard !walkComplete,
              pendingIncluded == 0, pendingCharacteristics == 0,
              pendingDescriptors == 0, pendingDescriptorReads == 0,
              pendingValueReads == 0 else { return }
        walkComplete = true
        buildSnapshot(peripheral)
    }

    private func buildSnapshot(_ peripheral: CBPeripheral) {
        var services: [Service] = []
        for cbService in peripheral.services ?? [] {
            var characteristics: [Characteristic] = []
            for cbCharacteristic in cbService.characteristics ?? [] {
                var descriptors: [Descriptor] = []
                for cbDescriptor in cbCharacteristic.descriptors ?? [] {
                    descriptors.append(Descriptor(
                        uuid: BluetoothUUID(cbDescriptor.uuid.uuidString),
                        handle: handle(forDescriptor: cbDescriptor),
                        valueHex: descriptorValues[ObjectIdentifier(cbDescriptor)]))
                }
                let handles = self.handles(forCharacteristic: cbCharacteristic)
                characteristics.append(Characteristic(
                    uuid: BluetoothUUID(cbCharacteristic.uuid.uuidString),
                    properties: Self.properties(cbCharacteristic.properties),
                    handles: handles,
                    valueHex: characteristicValues[ObjectIdentifier(cbCharacteristic)],
                    descriptors: descriptors))
            }
            services.append(Service(
                uuid: BluetoothUUID(cbService.uuid.uuidString),
                isPrimary: cbService.isPrimary,
                handles: handles(forService: cbService),
                includedServices: (cbService.includedServices ?? [])
                    .map { BluetoothUUID($0.uuid.uuidString) },
                characteristics: characteristics))
        }

        let table = AttributeTable(services: services)
        if options.includeHandles, let path = table.firstMissingHandlePath {
            fail(CaptureError.discoveryFailed(
                "handle capture was incomplete at \(path); refusing to claim handle coverage"))
            return
        }

        let metadata = CaptureMetadata(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            toolVersion: gattsnapVersion,
            host: ProcessInfo.processInfo.hostName,
            advertisedLocalName: advertisedName,
            peripheralIdentifier: peripheral.identifier.uuidString,
            macAddress: nil, // CBPeripheral.BDAddress is nil on Apple platforms
            rssi: rssi,
            mtu: peripheral.maximumWriteValueLength(for: .withoutResponse) + 3,
            discoveryDurationMs: discoveryMs,
            deviceInformation: deviceInformationSummary(services))

        succeed(Snapshot(
            profile: options.profile,
            adapter: CoreBluetoothCaptureAdapter.identity(for: options),
            captureMetadata: metadata,
            table: table))
    }

    private func deviceInformationSummary(_ services: [Service]) -> [String: String]? {
        guard let dis = services.first(where: { $0.uuid == DeviceInformation.serviceUUID })
        else { return nil }
        var out: [String: String] = [:]
        for characteristic in dis.characteristics {
            guard let hex = characteristic.valueHex,
                  let text = String(bytes: hex.bytesFromHex, encoding: .utf8),
                  !text.isEmpty else { continue }
            out[DeviceInformation.label(for: characteristic.uuid)] = text
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Handles (macOS only, opt-in)

    private func handles(forService service: CBService) -> ServiceHandles? {
        #if os(macOS)
        guard options.includeHandles,
              let h = HandleProbe.serviceHandles(service) else { return nil }
        return ServiceHandles(start: h.start, end: h.end)
        #else
        return nil
        #endif
    }

    private func handles(forCharacteristic characteristic: CBCharacteristic) -> CharacteristicHandles? {
        #if os(macOS)
        guard options.includeHandles,
              let h = HandleProbe.characteristicHandles(characteristic) else { return nil }
        return CharacteristicHandles(declaration: h.declaration, value: h.value)
        #else
        return nil
        #endif
    }

    private func handle(forDescriptor descriptor: CBDescriptor) -> UInt16? {
        #if os(macOS)
        guard options.includeHandles else { return nil }
        return HandleProbe.descriptorHandle(descriptor)
        #else
        return nil
        #endif
    }

    // MARK: - Conversions

    static func properties(_ properties: CBCharacteristicProperties) -> Set<CharacteristicProperty> {
        var out: Set<CharacteristicProperty> = []
        if properties.contains(.broadcast) { out.insert(.broadcast) }
        if properties.contains(.read) { out.insert(.read) }
        if properties.contains(.writeWithoutResponse) { out.insert(.writeWithoutResponse) }
        if properties.contains(.write) { out.insert(.write) }
        if properties.contains(.notify) { out.insert(.notify) }
        if properties.contains(.indicate) { out.insert(.indicate) }
        if properties.contains(.authenticatedSignedWrites) { out.insert(.authenticatedSignedWrites) }
        if properties.contains(.extendedProperties) { out.insert(.extendedProperties) }
        return out
    }

    /// Descriptor values come back type-varying: NSNumber for 0x2900/0x2902,
    /// NSString for 0x2901, NSData otherwise (platform-notes §2). Normalizing to
    /// hex keeps the snapshot byte-identical to what a BlueZ adapter would write.
    static func hex(fromDescriptorValue value: Any?) -> String? {
        switch value {
        case let data as Data:
            return data.hexString
        case let number as NSNumber:
            let raw = number.uint16Value
            return Data([UInt8(raw & 0xFF), UInt8(raw >> 8)]).hexString
        case let string as NSString:
            return Data(String(string).utf8).hexString
        default:
            return nil
        }
    }

    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "unrecognized(\(state.rawValue))"
        }
    }

    static func describeAuthorization() -> String {
        switch CBManager.authorization {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .allowedAlways: "allowedAlways"
        @unknown default: "unrecognized"
        }
    }
}

extension CaptureSession: CBCentralManagerDelegate, CBPeripheralDelegate {}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

extension String {
    var bytesFromHex: [UInt8] {
        var out: [UInt8] = []
        var index = startIndex
        while let next = self.index(index, offsetBy: 2, limitedBy: endIndex),
              let byte = UInt8(self[index..<next], radix: 16) {
            out.append(byte)
            index = next
        }
        return out
    }
}
#endif
