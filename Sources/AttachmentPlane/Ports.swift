import Foundation

/// Failures a file service reports. The classification is the contract: the
/// plane retries `.transient`, never retries `.permanent`, and treats
/// `.notFound` as "the provider no longer has this file".
public enum FileServiceError: Error, Equatable, Sendable {
    case transient(String)
    case permanent(String)
    case notFound(fileID: String)
}

/// The provider's file store (for Claude, the Files API: `POST /v1/files`,
/// `DELETE /v1/files/{id}`). The only side-effecting port.
public protocol FileService: Sendable {
    func upload(_ bytes: [UInt8], mediaType: MediaType, digest: ContentDigest, name: String) async throws -> RemoteFile
    func delete(fileID: String) async throws
}

/// Time, injected. `sleep` is used only for retry backoff.
public protocol PlaneClock: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: PlaneClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        guard seconds.isFinite, seconds > 0 else { return }
        // Clamped before converting: `UInt64(Double)` traps out of range.
        let nanos = min(seconds, 3600) * 1_000_000_000
        try await Task.sleep(nanoseconds: UInt64(nanos))
    }
}

/// A clock the caller advances by hand. `sleep` advances it instead of waiting,
/// so retry schedules are observable and tests take no wall time.
public final class ManualClock: PlaneClock, @unchecked Sendable {
    // @unchecked: every access to `current` and `slept` goes through `lock`,
    // and the lock is only taken in synchronous helpers (never across an await).
    private let lock = NSLock()
    private var current: Date
    private var slept: [TimeInterval] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    public var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    public var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return slept }

    public func advance(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    public func sleep(seconds: TimeInterval) async throws {
        recordSleep(seconds)
        await Task.yield()
    }

    private func recordSleep(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        slept.append(seconds)
        if seconds.isFinite, seconds > 0 { current = current.addingTimeInterval(seconds) }
    }
}

/// Where the registry survives relaunch. Synchronous on purpose: snapshots are
/// small (one row per distinct file) and written on the plane's actor.
public protocol RegistryStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public final class InMemoryRegistryStore: RegistryStore, @unchecked Sendable {
    // @unchecked: `data` is only touched under `lock`, never across an await.
    private let lock = NSLock()
    private var data: Data?
    public init(initial: Data? = nil) { data = initial }
    public func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    public func save(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; self.data = data }
}
