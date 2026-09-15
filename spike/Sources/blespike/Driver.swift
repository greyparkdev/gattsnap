import Foundation
import CoreBluetooth
import CryptoKit

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func propertyNames(_ p: CBCharacteristicProperties) -> [String] {
    var out: [String] = []
    if p.contains(.broadcast) { out.append("broadcast") }
    if p.contains(.read) { out.append("read") }
    if p.contains(.writeWithoutResponse) { out.append("writeWithoutResponse") }
    if p.contains(.write) { out.append("write") }
    if p.contains(.notify) { out.append("notify") }
    if p.contains(.indicate) { out.append("indicate") }
    if p.contains(.authenticatedSignedWrites) { out.append("authenticatedSignedWrites") }
    if p.contains(.extendedProperties) { out.append("extendedProperties") }
    if p.contains(.notifyEncryptionRequired) { out.append("notifyEncryptionRequired") }
    if p.contains(.indicateEncryptionRequired) { out.append("indicateEncryptionRequired") }
    return out
}

/// One flattened row of the discovered attribute table.
struct Row {
    var service: String
    var isPrimary: Bool
    var included: [String] = []
    var characteristic: String?
    var props: [String] = []
    var descriptors: [(uuid: String, value: String?)] = []
    var handles: [String: String] = [:]
}

final class Spike: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum Command {
        case permission(seconds: Double)
        case scan(seconds: Double)
        case dump(match: Match, seconds: Double)
        case cache(match: Match, rounds: Int, seconds: Double)
    }

    enum Match {
        case name(String)
        case id(UUID)

        func matches(_ p: CBPeripheral, advName: String?) -> Bool {
            switch self {
            case .name(let n):
                let candidates = [p.name, advName].compactMap { $0 }
                return candidates.contains { $0.localizedCaseInsensitiveContains(n) }
            case .id(let u):
                return p.identifier == u
            }
        }
    }

    private var central: CBCentralManager!
    private let command: Command
    private var stateHistory: [String] = []
    private var seen: [UUID: (CBPeripheral, [String: Any], NSNumber)] = [:]
    private var target: CBPeripheral?
    private var rows: [Row] = []
    private var pendingCharDiscovery = 0
    private var pendingDescriptorDiscovery = 0
    private var pendingDescriptorReads = 0
    private var pendingIncluded = 0
    private var round = 0
    private var fingerprints: [String] = []
    private var discoveryStart = Date()
    private var discoveryMillis: [Double] = []
    private var didSecondDiscovery = false
    private var firstDiscoveryMs: Double = 0
    private var didProbeClasses = false

    init(command: Command) {
        self.command = command
        super.init()
    }

    func run() {
        log("== blespike ==")
        log("pid \(getpid())  binary \(CommandLine.arguments[0])")
        dumpEmbeddedPlistStatus()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])

        let deadline: Double
        switch command {
        case .permission(let s), .scan(let s): deadline = s + 2
        case .dump(_, let s): deadline = s + 5
        case .cache(_, let r, let s): deadline = Double(r) * (s + 6) + 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            log("!! global deadline hit after \(deadline)s")
            self.finish(code: 3)
        }
        RunLoop.main.run()
    }

    private func dumpEmbeddedPlistStatus() {
        // Did the -sectcreate trick actually land an Info.plist in this Mach-O?
        let path = CommandLine.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        task.arguments = ["-P", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let s = String(data: d, encoding: .utf8) ?? ""
            log("embedded __TEXT,__info_plist present: \(s.contains("NSBluetoothAlwaysUsageDescription"))")
        } catch {
            log("otool probe failed: \(error)")
        }
        log("Bundle.main.infoDictionary keys: \((Bundle.main.infoDictionary?.keys.sorted() ?? []).joined(separator: ", "))")
        log("Bundle.main.bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "<nil>")")
    }

    // MARK: - Central delegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let name: String
        switch c.state {
        case .unknown: name = "unknown"
        case .resetting: name = "resetting"
        case .unsupported: name = "unsupported"
        case .unauthorized: name = "unauthorized"
        case .poweredOff: name = "poweredOff"
        case .poweredOn: name = "poweredOn"
        @unknown default: name = "future(\(c.state.rawValue))"
        }
        stateHistory.append(name)
        log("state -> \(name)  (authorization = \(authString()))")

        guard c.state == .poweredOn else { return }

        switch command {
        case .permission(let s):
            log("reached poweredOn; holding \(s)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { self.finish(code: 0) }
        case .scan(let s):
            startScan()
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                self.central.stopScan()
                self.reportScan()
                self.finish(code: 0)
            }
        case .dump(_, let s), .cache(_, _, let s):
            startScan()
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                if self.target == nil {
                    self.central.stopScan()
                    log("!! no peripheral matched within \(s)s")
                    self.reportScan()
                    self.finish(code: 4)
                }
            }
        }
    }

    private func authString() -> String {
        switch CBManager.authorization {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "future"
        }
    }

    private func startScan() {
        log("scanning (allowDuplicates=false)…")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        seen[p.identifier] = (p, advertisementData, RSSI)

        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        switch command {
        case .dump(let m, _), .cache(let m, _, _):
            guard target == nil, m.matches(p, advName: advName) else { return }
            c.stopScan()
            target = p
            p.delegate = self
            log("--> matched \(p.name ?? advName ?? "?") id=\(p.identifier)")
            dumpAdvertisement(advertisementData, RSSI: RSSI, peripheral: p)
            log("connecting… (round \(round + 1))")
            c.connect(p, options: nil)
        default:
            return
        }
    }

    private func dumpAdvertisement(_ ad: [String: Any], RSSI: NSNumber, peripheral: CBPeripheral) {
        log("  advertisement keys: \(ad.keys.sorted().joined(separator: ", "))")
        for k in ad.keys.sorted() {
            let v = ad[k]!
            if let d = v as? Data {
                log("    \(k) = <\(d.hex)>")
            } else if let dict = v as? [CBUUID: Data] {
                for (u, d) in dict { log("    \(k)[\(u.uuidString)] = <\(d.hex)>") }
            } else {
                log("    \(k) = \(v)")
            }
        }
        log("  RSSI \(RSSI)")
        log("  peripheral.identifier = \(peripheral.identifier)  (host-scoped UUID, not a MAC)")
        // Probe for any address-bearing ivar the framework might expose.
        if let (k, v) = Introspect.firstValue(peripheral, keys:
            ["address", "_address", "addressString", "identifierString", "_identifier", "UUID", "_UUID"]) {
            log("  peripheral private key '\(k)' = \(v)")
        } else {
            log("  no address-bearing key found on CBPeripheral")
        }
    }

    private func reportScan() {
        log("")
        log("== scan results: \(seen.count) peripherals ==")
        for (_, entry) in seen.sorted(by: { ($0.value.0.name ?? "") < ($1.value.0.name ?? "") }) {
            let (p, ad, rssi) = entry
            let advName = ad[CBAdvertisementDataLocalNameKey] as? String
            let connectable = (ad[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
            log("- \(p.name ?? advName ?? "<no name>")  id=\(p.identifier)  rssi=\(rssi) connectable=\(connectable.map(String.init) ?? "?")")
            log("    adv keys: \(ad.keys.sorted().joined(separator: ", "))")
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected. discovering services (nil filter)…")
        rows = []
        if !didProbeClasses {
            didProbeClasses = true
            probeClassSurface()
        }
        probePeripheralDetail(p)
        didSecondDiscovery = false
        discoveryStart = Date()
        p.discoverServices(nil)
    }

    /// Read every interesting private property CBPeripheral actually declares.
    private func probePeripheralDetail(_ p: CBPeripheral) {
        log("== CBPeripheral private property values (connected) ==")
        let keys = ["BDAddress", "stableIdentifier", "mtuLength", "appearance",
                    "isLinkEncrypted", "pairingState", "deviceType", "role",
                    "connectedTransport", "hostState", "name", "attributes",
                    "isConnectedToSystem", "visibleInSettings"]
        for k in keys {
            if let v = Introspect.safeValue(p, forKey: k) {
                if let d = v as? Data {
                    log("   \(k) = Data<\(d.hex)>")
                } else if let arr = v as? [Any] {
                    log("   \(k) = [\(arr.count) items] \(arr.prefix(4).map { "\(type(of: $0))" }.joined(separator: ", "))")
                } else {
                    log("   \(k) = \(v)  (\(type(of: v)))")
                }
            } else {
                log("   \(k) = <not readable>")
            }
        }
        log("")
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("!! didFailToConnect: \(error?.localizedDescription ?? "nil")")
        finish(code: 5)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected (error: \(error?.localizedDescription ?? "none"))")
        if case .cache(_, let rounds, _) = command, round < rounds {
            log("reconnecting for round \(round + 1)…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                c.connect(p, options: nil)
            }
        }
    }

    // MARK: - Peripheral delegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let ms = (Date().timeIntervalSince(discoveryStart) * 1000).rounded()
        if let error { log("!! didDiscoverServices error: \(error)") }

        // Methodological control: immediately re-run discovery on the SAME live
        // connection. That result can only come from CoreBluetooth's in-memory
        // cache, so it calibrates what "cache hit" looks like in milliseconds
        // against the first (post-connect) discovery on the same device.
        if !didSecondDiscovery {
            didSecondDiscovery = true
            firstDiscoveryMs = ms
            log("discovery #1 (after fresh connect): \(ms) ms")
            discoveryStart = Date()
            p.discoverServices(nil)
            return
        }
        log("discovery #2 (same connection, must be cached): \(ms) ms")
        log("  ==> first/second ratio = \(firstDiscoveryMs > 0 ? (firstDiscoveryMs / max(ms, 0.001)) : 0)")
        discoveryMillis.append(firstDiscoveryMs)
        let services = p.services ?? []
        log("services: \(services.count)")
        pendingIncluded = services.count
        pendingCharDiscovery = services.count
        if services.isEmpty { finishRound(p); return }
        for s in services {
            p.discoverIncludedServices(nil, for: s)
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        pendingIncluded -= 1
        if let inc = service.includedServices, !inc.isEmpty {
            log("  \(service.uuid.uuidString) includes: \(inc.map { $0.uuid.uuidString }.joined(separator: ", "))")
        }
        maybeFinishRound(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingCharDiscovery -= 1
        if let error { log("!! didDiscoverCharacteristics error for \(service.uuid): \(error)") }
        let chars = service.characteristics ?? []
        if chars.isEmpty {
            rows.append(Row(service: service.uuid.uuidString, isPrimary: service.isPrimary,
                            handles: handleProbe(service)))
        }
        pendingDescriptorDiscovery += chars.count
        for ch in chars {
            p.discoverDescriptors(for: ch)
        }
        maybeFinishRound(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        pendingDescriptorDiscovery -= 1
        if let error { log("!! didDiscoverDescriptors error for \(ch.uuid): \(error)") }
        let descs = ch.descriptors ?? []
        var row = Row(service: ch.service?.uuid.uuidString ?? "?",
                      isPrimary: ch.service?.isPrimary ?? false,
                      characteristic: ch.uuid.uuidString,
                      props: propertyNames(ch.properties),
                      descriptors: descs.map { ($0.uuid.uuidString, nil) })
        row.handles = handleProbe(ch)
        rows.append(row)

        // Try to actually read every descriptor value.
        for d in descs {
            pendingDescriptorReads += 1
            p.readValue(for: d)
        }
        maybeFinishRound(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        pendingDescriptorReads -= 1
        let owner = d.characteristic?.uuid.uuidString ?? "?"
        if let error {
            log("  desc \(owner)/\(d.uuid.uuidString) READ FAILED: \(error.localizedDescription)")
        } else {
            log("  desc \(owner)/\(d.uuid.uuidString) = \(describeDescriptorValue(d.value))")
        }
        if let i = rows.firstIndex(where: { $0.characteristic == owner }) {
            if let j = rows[i].descriptors.firstIndex(where: { $0.uuid == d.uuid.uuidString }) {
                rows[i].descriptors[j].value = error == nil ? describeDescriptorValue(d.value) : "ERR"
            }
        }
        maybeFinishRound(p)
    }

    private func describeDescriptorValue(_ v: Any?) -> String {
        switch v {
        case let d as Data: return "<\(d.hex)>"
        case let n as NSNumber: return "num \(n)"
        case let s as NSString: return "str \"\(s)\""
        case .none: return "<nil>"
        case .some(let other): return "\(type(of: other)) \(other)"
        }
    }

    // MARK: - Handle probing

    private func handleProbe(_ obj: NSObject) -> [String: String] {
        var out: [String: String] = [:]
        let keys = ["handle", "_handle", "startHandle", "_startHandle", "endHandle", "_endHandle",
                    "valueHandle", "_valueHandle", "attributeHandle", "_attributeHandle"]
        for k in keys {
            if let v = Introspect.safeValue(obj, forKey: k) {
                out[k.hasPrefix("_") ? String(k.dropFirst()) : k] = "\(v)"
            }
        }
        return out
    }

    private func probeClassSurface() {
        log("")
        log("== ObjC runtime surface of CoreBluetooth model classes ==")
        for cls in [CBService.self, CBCharacteristic.self, CBDescriptor.self, CBPeripheral.self] as [AnyClass] {
            log("-- \(NSStringFromClass(cls))")
            for (k, v) in Introspect.surface(of: cls).sorted(by: { $0.key < $1.key }) {
                log("   [\(k)] \(v.joined(separator: ", "))")
            }
        }
        log("")
    }

    // MARK: - Round completion

    private func maybeFinishRound(_ p: CBPeripheral) {
        if pendingIncluded == 0 && pendingCharDiscovery == 0
            && pendingDescriptorDiscovery == 0 && pendingDescriptorReads == 0 {
            finishRound(p)
        }
    }

    private var roundFinished = false
    private func finishRound(_ p: CBPeripheral) {
        guard !roundFinished else { return }
        roundFinished = true
        round += 1

        let fp = report(p)
        fingerprints.append(fp)

        switch command {
        case .cache(_, let rounds, _):
            if round >= rounds {
                log("")
                log("== fingerprints across \(rounds) rounds ==")
                for (i, f) in fingerprints.enumerated() {
                    let t = i < discoveryMillis.count ? "\(discoveryMillis[i]) ms" : "?"
                    log("  round \(i + 1): \(f)  discovery=\(t)")
                }
                log("  identical across rounds: \(Set(fingerprints).count == 1)")
                finish(code: 0)
            } else {
                roundFinished = false
                log("cancelling connection to force a fresh discovery…")
                central.cancelPeripheralConnection(p)
            }
        default:
            finish(code: 0)
        }
    }

    private func report(_ p: CBPeripheral) -> String {
        let sorted = rows.sorted {
            ($0.service, $0.characteristic ?? "") < ($1.service, $1.characteristic ?? "")
        }
        log("")
        log("== attribute table (round \(round)) ==")
        var canonical = ""
        for r in sorted {
            let h = r.handles.isEmpty ? "" : "  handles=\(r.handles.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: ","))"
            if let c = r.characteristic {
                log("  \(r.service) / \(c)  [\(r.props.joined(separator: "|"))]\(h)")
                canonical += "\(r.service)|\(c)|\(r.props.sorted().joined(separator: ","))"
                for d in r.descriptors.sorted(by: { $0.uuid < $1.uuid }) {
                    log("      desc \(d.uuid) = \(d.value ?? "<unread>")")
                    canonical += "|d:\(d.uuid)"
                }
                canonical += "\n"
            } else {
                log("  \(r.service)  (no characteristics)\(h)")
                canonical += "\(r.service)|-\n"
            }
        }
        let fp = SHA256.hash(data: Data(canonical.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        log("  structure fingerprint: \(fp)")
        log("  1800 (GAP) present in discovery: \(sorted.contains { $0.service == "1800" })")
        log("  1801 (GATT/Service Changed) present in discovery: \(sorted.contains { $0.service == "1801" })")
        return fp
    }

    private func finish(code: Int32) {
        log("")
        log("state history: \(stateHistory.joined(separator: " -> "))")
        log("final authorization: \(authString())")
        exit(code)
    }
}
