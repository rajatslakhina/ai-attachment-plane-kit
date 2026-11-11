import Foundation
import XCTest
@testable import AttachmentPlane

final class ContentDigestTests: XCTestCase {
    // FIPS 180-2 Appendix B vectors.
    func testKnownVectors() {
        XCTAssertEqual(ContentDigest.sha256([]).hex,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ContentDigest.sha256(Array("abc".utf8)).hex,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ContentDigest.sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).hex,
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testOneMillionA() {
        XCTAssertEqual(ContentDigest.sha256([UInt8](repeating: 0x61, count: 1_000_000)).hex,
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Lengths around the 55/56/64-byte padding boundaries, where a padding bug
    /// shows up. Expected values come from Python's hashlib over `i % 251`.
    func testPaddingBoundaries() {
        let expected: [Int: String] = [
            55: "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59",
            56: "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562",
            63: "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488",
            64: "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108",
            65: "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781",
            119: "da18797ed7c3a777f0847f429724a2d8cd5138e6ed2895c3fa1a6d39d18f7ec6",
            120: "f52b23db1fbb6ded89ef42a23ce0c8922c45f25c50b568a93bf1c075420bbb7c",
            1000: "4e4c294b331f7a2099a379bec34b9f9fc03dc46ab465d998f4d683da53487e6d",
        ]
        for (length, hex) in expected {
            let input = (0..<length).map { UInt8($0 % 251) }
            XCTAssertEqual(ContentDigest.sha256(input).hex, hex, "length \(length)")
        }
    }

    func testValidatingInitializer() {
        let valid = String(repeating: "aB", count: 32)
        XCTAssertEqual(ContentDigest(hex: valid)?.hex, valid.lowercased())
        XCTAssertNil(ContentDigest(hex: ""))
        XCTAssertNil(ContentDigest(hex: String(repeating: "a", count: 63)))
        XCTAssertNil(ContentDigest(hex: String(repeating: "g", count: 64)))
        XCTAssertNil(ContentDigest(hex: String(repeating: "é", count: 64)))
    }

    func testCodableRoundTripAndCorruptionIsRejected() throws {
        let digest = ContentDigest.sha256(Array("hello".utf8))
        let data = try JSONEncoder().encode([digest])
        XCTAssertEqual(try JSONDecoder().decode([ContentDigest].self, from: data), [digest])
        XCTAssertThrowsError(try JSONDecoder().decode([ContentDigest].self, from: Data("[\"nope\"]".utf8)))
    }

    func testShortFormIsForDisplayOnly() {
        let digest = ContentDigest.sha256([1, 2, 3])
        XCTAssertEqual(digest.short.count, 10)
        XCTAssertTrue(digest.hex.hasPrefix(digest.short))
        XCTAssertTrue(digest.description.hasPrefix("sha256:"))
    }
}
