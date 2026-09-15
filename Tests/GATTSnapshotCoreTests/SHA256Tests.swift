import Foundation
import Testing
@testable import GATTSnapshotCore

/// The hash is hand-rolled so Core can build on Linux without CryptoKit or a
/// swift-crypto dependency. That makes verifying it against the published
/// vectors non-optional — a wrong hash would silently invalidate every
/// committed snapshot.
@Suite("SHA-256")
struct SHA256Tests {

    @Test("NIST and RFC test vectors", arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ("The quick brown fox jumps over the lazy dog",
         "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
    ])
    func knownVectors(input: String, expected: String) {
        #expect(SHA256.hexDigest(input) == expected)
    }

    @Test("Exercises every message-padding boundary")
    func paddingBoundaries() {
        // 55/56/57 and 63/64/65 bytes straddle the single/double block split,
        // which is where a padding bug hides.
        let expectations: [Int: String] = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            57: "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6",
            63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
        ]
        for (length, expected) in expectations {
            #expect(SHA256.hexDigest(String(repeating: "a", count: length)) == expected,
                    "length \(length)")
        }
    }
}
