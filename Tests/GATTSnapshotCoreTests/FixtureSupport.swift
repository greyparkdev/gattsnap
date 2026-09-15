import Foundation
import Testing
@testable import GATTSnapshotCore

/// Fixtures are read from the source tree rather than a resource bundle so the
/// maintenance path below can write corrected hashes back to the real files.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    /// Loads and fully validates — so every test that touches a fixture also
    /// asserts that fixture is internally consistent.
    static func snapshot(_ name: String) throws -> Snapshot {
        try SnapshotCoding.decode(try data(name))
    }

    static let all = [
        "variant-a",
        "variant-b",
        "variant-a-cosmetic",
        "variant-a-bluez",
        "variant-a-handles",
        "variant-a-handles-shifted",
    ]
}

/// `structure_hash` is a derived field, so hand-written fixtures cannot carry it
/// by hand. This rewrites it in place, preserving the hand-written formatting of
/// everything else.
///
/// Run with: GATTSNAP_REGENERATE_FIXTURES=1 swift test
/// It is a no-op otherwise, and `fixtureHashesAreCorrect` is what guards them in
/// normal runs.
@Test func regenerateFixtureHashes() throws {
    guard ProcessInfo.processInfo.environment["GATTSNAP_REGENERATE_FIXTURES"] == "1" else { return }

    for name in Fixture.all {
        let raw = try Fixture.text(name)
        let snapshot = try SnapshotCoding.decode(Data(raw.utf8), validate: false)
        let correct = StructureHash.compute(snapshot.table)

        guard let range = raw.range(of: #""structure_hash" : "[^"]*""#, options: .regularExpression) else {
            Issue.record("fixture \(name) has no structure_hash field")
            continue
        }
        let updated = raw.replacingCharacters(
            in: range, with: "\"structure_hash\" : \"\(correct)\"")
        try updated.write(to: Fixture.url(name), atomically: true, encoding: .utf8)
    }
}
