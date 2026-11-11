/// The identity of an attachment is its bytes, not its file name, its picker
/// URL or the conversation it was first attached to. Two attachments with the
/// same SHA-256 are the same remote file.
///
/// SHA-256 is implemented here in pure Swift (rather than CryptoKit) so the
/// core builds and is tested on Linux with no third-party dependency. It is
/// verified against the FIPS 180-2 vectors in `ContentDigestTests`.
public struct ContentDigest: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// 64 lowercase hex characters.
    public let hex: String

    /// Validating initializer for digests that arrive from storage.
    public init?(hex: String) {
        let lowered = hex.lowercased()
        guard lowered.utf8.count == 64,
              lowered.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else { return nil }
        self.hex = lowered
    }

    private init(trustedHex: String) { self.hex = trustedHex }

    public static func sha256(_ bytes: [UInt8]) -> ContentDigest {
        let table: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(64)
        for byte in SHA256.hash(bytes) {
            // `>> 4` and `& 0x0f` are both in 0...15, so both indexes are in range.
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0f)])
        }
        return ContentDigest(trustedHex: out)
    }

    /// First 10 hex characters; for logs and UI only, never for identity.
    public var short: String { String(hex.prefix(10)) }
    public var description: String { "sha256:\(short)…" }
    public static func < (lhs: ContentDigest, rhs: ContentDigest) -> Bool { lhs.hex < rhs.hex }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = ContentDigest(hex: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a SHA-256 hex digest"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// FIPS 180-4 SHA-256. All arithmetic is explicitly wrapping (`&+`), which is
/// what the specification requires, so nothing here can trap.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 &- n))
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        // Message length in bits, modulo 2^64 as the spec defines it.
        let bitLength = UInt64(truncatingIfNeeded: message.count) &* 8
        var data = message
        data.reserveCapacity(message.count + 72)
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        // From here `data.count` is a multiple of 64, so every index below
        // (`chunk + 63` at most) is in range.
        var w = [UInt32](repeating: 0, count: 64)
        var chunk = 0
        while chunk + 64 <= data.count {
            for t in 0..<16 {
                let b = chunk + t * 4
                w[t] = UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16
                    | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ bigS1 &+ ch &+ k[t] &+ w[t]
                let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = bigS0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            chunk += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }
}
