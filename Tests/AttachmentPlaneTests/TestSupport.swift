import Foundation
import XCTest
@testable import AttachmentPlane

/// Deterministic bytes of a given length; `seed` makes different "files".
func bytes(_ count: Int, seed: UInt8 = 0) -> [UInt8] {
    (0..<max(0, count)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7) }
}

func image(_ name: String, seed: UInt8, count: Int = 4096) -> AttachmentSource {
    AttachmentSource(name: name, bytes: bytes(count, seed: seed), mediaType: .jpeg,
                     pixelSize: PixelSize(width: 1000, height: 750))
}

func pdf(_ name: String, seed: UInt8, count: Int = 8192, pages: Int? = 3) -> AttachmentSource {
    AttachmentSource(name: name, bytes: bytes(count, seed: seed), mediaType: .pdf, pageCount: pages)
}

/// Identity jitter, so backoff delays are exact.
let noJitter = RetryPolicy(maxAttempts: 4, baseDelay: 0.5, maxDelay: 8, jitter: { $0 })

/// Polls `condition` until it holds; fails the test after ~2 s instead of hanging.
func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for: \(what)", file: file, line: line)
}

/// Collects events from the plane's observer.
final class EventLog: @unchecked Sendable {
    // @unchecked: `events` is only touched under `lock`.
    private let lock = NSLock()
    private var events: [PlaneEvent] = []
    func append(_ event: PlaneEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [PlaneEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

/// A file service whose uploads and deletes can be held at a gate, so tests
/// can interleave operations at exact suspension points instead of hoping a
/// scheduler does it. Also fails uploads by attachment name.
actor GatedFileService: FileService {
    let inner: SimulatedFileService
    private var holdUploads = false
    private var holdDeletes = false
    private var uploadWaiters: [CheckedContinuation<Void, Never>] = []
    private var deleteWaiters: [CheckedContinuation<Void, Never>] = []
    private var rejectNames: Set<String> = []
    private var holdNames: Set<String> = []
    private var transientDeleteFailures = 0
    private(set) var deletesAttempted: [String] = []

    init(inner: SimulatedFileService) { self.inner = inner }

    func holdUploadsAtGate() { holdUploads = true }
    func holdDeletesAtGate() { holdDeletes = true }
    func reject(name: String) { rejectNames.insert(name) }
    /// Holds only uploads with this name at the gate (the others proceed).
    func holdUpload(named name: String) { holdNames.insert(name) }
    func failNextDeletesTransiently(_ count: Int) { transientDeleteFailures = count }
    var waitingUploads: Int { uploadWaiters.count }
    var waitingDeletes: Int { deleteWaiters.count }

    func openUploadGate() {
        holdUploads = false
        holdNames.removeAll()
        let waiters = uploadWaiters
        uploadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func openDeleteGate() {
        holdDeletes = false
        let waiters = deleteWaiters
        deleteWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func upload(_ bytes: [UInt8], mediaType: MediaType, digest: ContentDigest, name: String) async throws -> RemoteFile {
        if rejectNames.contains(name) { throw FileServiceError.permanent("rejected \(name)") }
        if holdUploads || holdNames.contains(name) { await withCheckedContinuation { uploadWaiters.append($0) } }
        // A real network call honours cancellation; so does this one, so a plane
        // that cancelled the shared upload task would be caught.
        try Task.checkCancellation()
        return try await inner.upload(bytes, mediaType: mediaType, digest: digest, name: name)
    }

    func delete(fileID: String) async throws {
        deletesAttempted.append(fileID)
        if holdDeletes { await withCheckedContinuation { deleteWaiters.append($0) } }
        if transientDeleteFailures > 0 {
            transientDeleteFailures -= 1
            throw FileServiceError.transient("delete timed out")
        }
        try await inner.delete(fileID: fileID)
    }
}

struct FixedCounter: TokenCounting {
    let value: Int
    func countTokens(for sources: [AttachmentSource]) async throws -> Int { value }
}

struct FailingCounter: TokenCounting {
    func countTokens(for sources: [AttachmentSource]) async throws -> Int {
        throw FileServiceError.transient("count_tokens 529 overloaded")
    }
}

struct ThrowingStore: RegistryStore {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw FileServiceError.permanent("disk full") }
}
