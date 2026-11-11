import Foundation

/// Media types the plane admits. Anything else cannot be expressed, so it is
/// refused at the type level before a byte is hashed or uploaded.
public enum MediaType: String, Codable, Sendable, CaseIterable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webp = "image/webp"
    case pdf = "application/pdf"
    case plainText = "text/plain"

    public enum Kind: String, Sendable { case image, document, text }

    public var kind: Kind {
        switch self {
        case .png, .jpeg, .gif, .webp: return .image
        case .pdf: return .document
        case .plainText: return .text
        }
    }
}

public struct PixelSize: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One thing the user attached. `name` is presentation only; identity is the
/// SHA-256 of `bytes` (see `ContentDigest`).
public struct AttachmentSource: Sendable {
    public let name: String
    public let bytes: [UInt8]
    public let mediaType: MediaType
    /// Known pixel size of an image, if the picker reported it.
    public let pixelSize: PixelSize?
    /// Known page count of a PDF, if the picker reported it.
    public let pageCount: Int?

    public init(name: String, bytes: [UInt8], mediaType: MediaType,
                pixelSize: PixelSize? = nil, pageCount: Int? = nil) {
        self.name = name
        self.bytes = bytes
        self.mediaType = mediaType
        self.pixelSize = pixelSize
        self.pageCount = pageCount
    }
}

/// What the plane hands to the message composer: a remote file id to put in a
/// `{"type": "image" | "document", "source": {"type": "file", "file_id": ...}}`
/// content block, never the bytes again.
public struct AttachmentReference: Hashable, Sendable {
    public let name: String
    public let digest: ContentDigest
    public let fileID: String
    public let mediaType: MediaType
    /// How this reference was obtained; the demo and the metrics read it.
    public let resolution: Resolution

    public enum Resolution: String, Sendable {
        /// Bytes were uploaded by this call.
        case uploaded
        /// A live remote file with the same digest was reused.
        case reused
        /// Another call was already uploading these bytes; this call joined it.
        case joinedInFlight
        /// The same bytes appeared twice in one batch; the second rides the first.
        case duplicateInBatch
    }
}

/// A remote file as the file service reports it.
public struct RemoteFile: Hashable, Codable, Sendable {
    public let id: String
    /// When the provider will delete it on its own; `nil` means no expiry.
    public let expiresAt: Date?
    public init(id: String, expiresAt: Date?) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

/// Saturating integer arithmetic, so no size or token sum reachable from the
/// public API can trap on overflow.
enum Saturating {
    static func add(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.max : Int.min) : value
    }

    static func multiply(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return value }
        return (a < 0) == (b < 0) ? Int.max : Int.min
    }

    /// `Int(double)` traps on NaN, infinity and out-of-range values. This does not.
    /// The ceiling is derived from `Int.max` (`Double(Int.max)` rounds up to the
    /// first value that would trap), so it is right on 32-bit platforms too.
    static func int(_ value: Double) -> Int {
        guard value.isFinite else { return value.isNaN ? 0 : (value > 0 ? Int.max : Int.min) }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
}
