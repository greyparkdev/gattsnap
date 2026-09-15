import Foundation
import Testing
@testable import GATTSnapshotCore
@testable import GATTSnapshotReport

private let desk = DiscoveredPeripheral(
    identifier: "11111111-2222-3333-4444-555555555555",
    advertisedLocalName: "acme-sensor-a1b2",
    cachedName: "acme-sensor-a1b2",
    rssi: -37, isConnectable: true,
    serviceUUIDs: [BluetoothUUID("180D"), BluetoothUUID("180F")])

private let acrossTheRoom = DiscoveredPeripheral(
    identifier: "AAAAAAAA-0000-0000-0000-000000000001",
    advertisedLocalName: "ESP32", rssi: -90, isConnectable: true)

private let anonymous = DiscoveredPeripheral(
    identifier: "BBBBBBBB-0000-0000-0000-000000000002",
    rssi: -60, isConnectable: true)

private let beacon = DiscoveredPeripheral(
    identifier: "CCCCCCCC-0000-0000-0000-000000000003",
    rssi: -45, isConnectable: false)

private let renamed = DiscoveredPeripheral(
    identifier: "DDDDDDDD-0000-0000-0000-000000000004",
    advertisedLocalName: "acme-sensor-v3",
    cachedName: "acme-sensor-v2",
    rssi: -50, isConnectable: true)

@Suite("Scan ordering")
struct ScanOrderingTests {

    @Test("Strongest signal first — the device on your desk")
    func strongestFirst() {
        let sorted = [acrossTheRoom, desk, anonymous].sorted(by: DiscoveredPeripheral.displayOrder)
        #expect(sorted.map(\.identifier) == [desk, anonymous, acrossTheRoom].map(\.identifier))
    }

    @Test("Unknown signal sorts last, never first")
    func unknownSignalLast() {
        // CoreBluetooth reports 127 for "unavailable"; treating that as a real
        // reading would put unmeasurable devices at the top of the list.
        let unknown = DiscoveredPeripheral(identifier: "E", rssi: nil, isConnectable: true)
        let sorted = [unknown, acrossTheRoom].sorted(by: DiscoveredPeripheral.displayOrder)
        #expect(sorted.first?.identifier == acrossTheRoom.identifier)
    }

    @Test("Ordering is total and stable")
    func stableOrdering() {
        let all = [desk, acrossTheRoom, anonymous, beacon, renamed]
        #expect(all.sorted(by: DiscoveredPeripheral.displayOrder).map(\.identifier)
                == all.reversed().sorted(by: DiscoveredPeripheral.displayOrder).map(\.identifier))
    }

    @Test("Only connectable devices are capturable; unknown counts as maybe")
    func capturability() {
        #expect(desk.isCapturable)
        #expect(!beacon.isCapturable)
        // Absence of the flag is not a "no" — plenty of devices simply omit it.
        #expect(DiscoveredPeripheral(identifier: "X", isConnectable: nil).isCapturable)
    }
}

@Suite("Scan rendering")
struct ScanRenderingTests {

    @Test("Lists devices with signal, name and identifier")
    func listsEssentials() {
        let text = ScanRenderer.human([desk, acrossTheRoom], hiddenCount: 0, useColor: false)
        #expect(text.contains("acme-sensor-a1b2"))
        #expect(text.contains("-37"))
        #expect(text.contains("11111111-2222-3333-4444-555555555555"))
        #expect(text.contains("RSSI"))
    }

    /// The whole reason the command exists: you cannot capture a device whose
    /// name you do not know, and this is the only place to learn it.
    @Test("Ends with a runnable identifier-based capture command for the strongest match")
    func suggestsCaptureCommand() {
        let text = ScanRenderer.human([desk, acrossTheRoom], hiddenCount: 0, useColor: false)
        #expect(text.contains("gattsnap capture --id '11111111-2222-3333-4444-555555555555'"))
        #expect(text.contains("--profile"))
    }

    @Test("Falls back to --id when the strongest match has no name")
    func suggestsIdentifierWhenUnnamed() {
        let text = ScanRenderer.human([anonymous], hiddenCount: 0, useColor: false)
        #expect(text.contains("gattsnap capture --id 'BBBBBBBB-0000-0000-0000-000000000002'"))
        #expect(!text.contains("--name"))
    }

    /// platform-notes §4: the OS remembers an old name, so a user searching for
    /// what the device *used* to be called finds nothing and assumes it is gone.
    @Test("Warns when the OS-cached name differs from the advertised one")
    func flagsStaleCachedName() {
        let text = ScanRenderer.human([renamed], hiddenCount: 0, useColor: false)
        #expect(text.contains("acme-sensor-v3"))
        #expect(text.contains("OS-cached name differs"))
        #expect(text.contains("acme-sensor-v2"))
        // The suggested command uses the exact identifier, so neither name can
        // accidentally select a different similarly named advertiser.
        #expect(text.contains("--id 'DDDDDDDD-0000-0000-0000-000000000004'"))
    }

    @Test("Says nothing about cached names when they agree")
    func quietWhenNamesMatch() {
        let text = ScanRenderer.human([desk], hiddenCount: 0, useColor: false)
        #expect(!text.contains("OS-cached"))
    }

    @Test("Reports how many entries were withheld")
    func reportsHiddenCount() {
        // Otherwise a user whose beacon is missing has no idea why.
        let text = ScanRenderer.human([desk], hiddenCount: 12, useColor: false)
        #expect(text.contains("12 non-connectable"))
        #expect(text.contains("--all"))
    }

    @Test("An empty result explains what to check")
    func emptyResultIsHelpful() {
        let text = ScanRenderer.human([], hiddenCount: 0, useColor: false)
        #expect(text.contains("No connectable peripherals found"))
        #expect(text.contains("powered"))
        #expect(!text.contains("gattsnap capture"), "must not suggest capturing nothing")
    }

    @Test("An empty result still mentions what was withheld")
    func emptyButFiltered() {
        let text = ScanRenderer.human([], hiddenCount: 5, useColor: false)
        #expect(text.contains("5 non-connectable"))
    }

    @Test("Marks non-connectable entries when they are shown")
    func marksNonConnectable() {
        let text = ScanRenderer.human([beacon], hiddenCount: 0, useColor: false)
        #expect(text.contains("[not connectable]"))
    }

    @Test("Shows advertised service UUIDs when present")
    func showsServices() {
        let text = ScanRenderer.human([desk], hiddenCount: 0, useColor: false)
        #expect(text.contains("180D"))
        #expect(text.contains("180F"))
    }

    @Test("Emits no escape codes when colour is off")
    func noEscapesWithoutColor() {
        let text = ScanRenderer.human([desk, beacon, renamed, anonymous],
                                      hiddenCount: 3, useColor: false)
        #expect(!text.contains("\u{001B}["))
    }

    @Test("Long names are truncated rather than breaking the columns")
    func truncatesLongNames() {
        let long = DiscoveredPeripheral(
            identifier: "F", advertisedLocalName: String(repeating: "x", count: 80),
            rssi: -40, isConnectable: true)
        let text = ScanRenderer.human([long], hiddenCount: 0, useColor: false)
        #expect(text.contains("…"))
        #expect(text.contains("--id 'F'"))
    }

    @Test("Radio-supplied control and shell syntax cannot enter the command")
    func hostileNameIsSafe() throws {
        let hostile = DiscoveredPeripheral(
            identifier: "SAFE-ID",
            advertisedLocalName: "sensor\n\u{001B}[31m$(touch /tmp/pwned)'\"",
            rssi: -40, isConnectable: true)
        let text = ScanRenderer.human([hostile], hiddenCount: 0, useColor: false)
        let command = try #require(text.split(separator: "\n")
            .first(where: { $0.contains("gattsnap capture") }).map(String.init))

        #expect(!text.contains("sensor\n"))
        #expect(!text.contains("\u{001B}"))
        #expect(command.contains("--id 'SAFE-ID'"))
        #expect(!command.contains("touch"))
    }
}

@Suite("Scan JSON")
struct ScanJSONTests {

    @Test("Produces parseable JSON")
    func parseable() throws {
        let json = try ScanRenderer.json([desk, beacon], hiddenCount: 4)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["tool"] as? String == "gattsnap")
        #expect(object["count"] as? Int == 2)
        #expect(object["hidden_non_connectable"] as? Int == 4)

        let peripherals = try #require(object["peripherals"] as? [[String: Any]])
        #expect(peripherals.first?["advertised_local_name"] as? String == "acme-sensor-a1b2")
        #expect(peripherals.first?["rssi"] as? Int == -37)
        #expect(peripherals.first?["service_uuids"] as? [String] == ["180D", "180F"])
    }

    @Test("Round-trips through the model")
    func roundTrips() throws {
        let json = try ScanRenderer.json([desk, renamed, anonymous])
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let raw = try JSONSerialization.data(withJSONObject: object["peripherals"]!)
        let decoded = try JSONDecoder().decode([DiscoveredPeripheral].self, from: raw)
        #expect(decoded == [desk, renamed, anonymous])
    }

    /// Regression: `render` originally dropped `hiddenCount` on the JSON path,
    /// so human output said "19 hidden" while JSON said 0. Found by running the
    /// two formats back to back against real hardware.
    @Test("The dispatcher carries hiddenCount into every format")
    func dispatcherPreservesHiddenCount() throws {
        let json = try ScanRenderer.render([desk], format: .json,
                                           hiddenCount: 19, useColor: false)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["hidden_non_connectable"] as? Int == 19)

        let human = try ScanRenderer.render([desk], format: .human,
                                            hiddenCount: 19, useColor: false)
        #expect(human.contains("19 non-connectable"))
    }

    @Test("An empty scan is still valid JSON")
    func emptyIsValid() throws {
        let json = try ScanRenderer.json([])
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["count"] as? Int == 0)
    }
}
