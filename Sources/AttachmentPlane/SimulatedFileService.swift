import Foundation

/// An in-memory stand-in for a provider's Files API, with scripted faults.
/// Used by the demo app and by tests; it is not a mock of the plane, it is a
/// second implementation of the `FileService` contract.
public actor SimulatedFileService: FileService {
    private struct StoredFile {
        let digest: ContentDigest
        let byteCount: Int
        let expiresAt: Date?
    }

    private let clock: PlaneClock
    private let ttl: TimeInterval?
    private let latency: TimeInterval
    private var files: [String: StoredFile] = [:]
    private var nextID = 0
    private var uploadFaults: [FileServiceError] = []
    private var deleteFaults: [FileServiceError] = []

    public private(set) var uploadCalls = 0
    public private(set) var deleteCalls = 0
    public private(set) var bytesReceived = 0

    /// - Parameters:
    ///   - ttl: how long an uploaded file lives (`nil`: forever).
    ///   - latency: real wall-clock seconds each upload takes (capped at 60), so
    ///     concurrent callers visibly overlap in the demo. Tests use 0.
    public init(clock: PlaneClock, ttl: TimeInterval? = 30 * 24 * 60 * 60, latency: TimeInterval = 0) {
        self.clock = clock
        self.ttl = ttl
        self.latency = latency.isFinite ? min(max(0, latency), 60) : 0
    }

    public func upload(_ bytes: [UInt8], mediaType: MediaType, digest: ContentDigest, name: String) async throws -> RemoteFile {
        uploadCalls += 1
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if !uploadFaults.isEmpty { throw uploadFaults.removeFirst() }
        nextID += 1
        let id = "file_\(String(nextID, radix: 36))"
        let expiry = ttl.map { clock.now.addingTimeInterval($0) }
        files[id] = StoredFile(digest: digest, byteCount: bytes.count, expiresAt: expiry)
        bytesReceived = Saturating.add(bytesReceived, bytes.count)
        return RemoteFile(id: id, expiresAt: expiry)
    }

    public func delete(fileID: String) async throws {
        deleteCalls += 1
        if !deleteFaults.isEmpty { throw deleteFaults.removeFirst() }
        guard files.removeValue(forKey: fileID) != nil else { throw FileServiceError.notFound(fileID: fileID) }
    }

    // MARK: Fault injection and inspection

    public func failNextUploads(_ errors: [FileServiceError]) { uploadFaults.append(contentsOf: errors) }
    public func failNextDeletes(_ errors: [FileServiceError]) { deleteFaults.append(contentsOf: errors) }

    /// The provider loses a file (an operator purge, a region failover).
    public func forget(fileID: String) { files[fileID] = nil }

    /// Ids the provider would still serve right now (unexpired).
    public func liveFileIDs() -> [String] {
        let now = clock.now
        return files.filter { $0.value.expiresAt.map { $0 > now } ?? true }.keys.sorted()
    }

    /// Stand-in for "send the message": throws `MissingRemoteFiles` naming every
    /// referenced id the provider no longer has, exactly as a real 404 would.
    public func validate(_ fileIDs: [String]) throws {
        let live = Set(liveFileIDs())
        let missing = fileIDs.filter { !live.contains($0) }
        if !missing.isEmpty { throw MissingRemoteFiles(fileIDs: missing) }
    }
}
