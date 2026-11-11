import Foundation

/// One distinct piece of content the plane knows about.
public struct RegistryEntry: Codable, Sendable, Equatable {
    public var digest: ContentDigest
    /// `nil` after the provider told us it lost the file: the owners are kept
    /// (they still mean it), but the next `prepare` must upload again.
    public var remote: RemoteFile?
    public var mediaType: MediaType
    public var byteCount: Int
    public var lastUsed: Date
    /// Conversations (or drafts) that currently reference this content.
    public var owners: Set<String>
    /// Since when the entry has had no owners; `nil` while owned. A fresh
    /// upload starts orphaned (its `prepare` pins it until it retains an
    /// owner), so an upload whose batch failed, or a crash before retain, can
    /// never leave an entry that garbage collection would skip forever.
    public var orphanedAt: Date?
}

/// The dedup index: digest → remote file + owners. A plain value type with no
/// I/O and no concurrency, so every rule in it is unit-testable directly; the
/// `AttachmentPlane` actor is what makes it safe to share.
struct FileRegistry: Sendable, Equatable {
    static let snapshotVersion = 1
    private(set) var entries: [ContentDigest: RegistryEntry] = [:]

    init() {}

    var count: Int { entries.count }
    func entry(_ digest: ContentDigest) -> RegistryEntry? { entries[digest] }

    /// A remote file is reusable only if it outlives `now` by more than `margin`.
    func usable(_ digest: ContentDigest, now: Date, margin: TimeInterval) -> RemoteFile? {
        guard let remote = entries[digest]?.remote else { return nil }
        if let expiry = remote.expiresAt, expiry.timeIntervalSince(now) <= margin { return nil }
        return remote
    }

    /// Records a fresh upload. Existing owners are kept: they referenced the
    /// content, not the old file id. A replaced, about-to-expire file is not
    /// deleted here, because a request sent inside the safety margin may still
    /// be using it, and it only exists when the provider expires files, so the
    /// provider's expiry reclaims it.
    mutating func record(_ digest: ContentDigest, remote: RemoteFile, mediaType: MediaType,
                         byteCount: Int, now: Date) {
        if var existing = entries[digest] {
            existing.remote = remote
            existing.lastUsed = now
            entries[digest] = existing
        } else {
            entries[digest] = RegistryEntry(digest: digest, remote: remote, mediaType: mediaType,
                                            byteCount: byteCount, lastUsed: now, owners: [], orphanedAt: now)
        }
    }

    mutating func touch(_ digest: ContentDigest, now: Date) {
        entries[digest]?.lastUsed = now
    }

    mutating func retain(_ digest: ContentDigest, owner: String) {
        guard var entry = entries[digest] else { return }
        entry.owners.insert(owner)
        entry.orphanedAt = nil
        entries[digest] = entry
    }

    /// Returns how many entries the owner was removed from.
    @discardableResult
    mutating func release(owner: String, now: Date) -> Int {
        var released = 0
        for digest in Array(entries.keys) {
            guard var entry = entries[digest], entry.owners.remove(owner) != nil else { continue }
            released += 1
            if entry.owners.isEmpty { entry.orphanedAt = now }
            entries[digest] = entry
        }
        return released
    }

    /// Compare-and-invalidate: only the entry *currently* mapped to `fileID` is
    /// touched. If a newer upload already replaced it, this is a no-op.
    @discardableResult
    mutating func invalidate(fileID: String) -> Bool {
        for (digest, entry) in entries where entry.remote?.id == fileID {
            entries[digest]?.remote = nil
            return true
        }
        return false
    }

    /// Orphaned entries past their grace period, excluding pinned digests.
    /// With `remove: true` they leave the index *before* the caller awaits any
    /// deletion, so a concurrent `prepare` uploads fresh instead of reusing a
    /// file that is being deleted.
    mutating func collectible(now: Date, grace: TimeInterval, excluding pinned: Set<ContentDigest>,
                              remove: Bool) -> [RegistryEntry] {
        let due = entries.values.filter { entry in
            guard entry.owners.isEmpty, let orphaned = entry.orphanedAt, !pinned.contains(entry.digest) else { return false }
            return now.timeIntervalSince(orphaned) >= grace
        }.sorted { $0.digest < $1.digest }
        if remove { for entry in due { entries[entry.digest] = nil } }
        return due
    }

    /// Removes the digest only if the index still holds exactly that unowned mapping.
    mutating func removeIfUnchanged(_ entry: RegistryEntry) {
        if let current = entries[entry.digest], current.remote == entry.remote, current.owners.isEmpty {
            entries[entry.digest] = nil
        }
    }

    /// Puts back an entry whose deletion failed, unless the digest was
    /// re-recorded meanwhile. Returns false when the slot is taken.
    mutating func restore(_ entry: RegistryEntry) -> Bool {
        guard entries[entry.digest] == nil else { return false }
        entries[entry.digest] = entry
        return true
    }

    /// LRU eviction of unreferenced, unpinned entries down to `limit`. Owned
    /// entries are never evicted: dropping them would orphan a live remote file
    /// with nobody left to delete it. Returns what was evicted.
    mutating func evictOverflow(limit: Int, excluding pinned: Set<ContentDigest>) -> [RegistryEntry] {
        guard entries.count > limit else { return [] }
        let candidates = entries.values
            .filter { $0.owners.isEmpty && !pinned.contains($0.digest) }
            .sorted { ($0.lastUsed, $0.digest) < ($1.lastUsed, $1.digest) }
        var evicted: [RegistryEntry] = []
        for entry in candidates where entries.count > limit {
            entries[entry.digest] = nil
            evicted.append(entry)
        }
        return evicted
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var version: Int
        var entries: [RegistryEntry]
        /// Remote files owed a delete, including ones a GC pass was deleting
        /// when the app died. Persisted so a crash cannot leak them.
        var pendingDeletions: [String]
    }

    func snapshot(pendingDeletions: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let ordered = entries.values.sorted { $0.digest < $1.digest }
        return try encoder.encode(Snapshot(version: Self.snapshotVersion, entries: ordered,
                                           pendingDeletions: pendingDeletions))
    }

    /// `nil` for corrupt data or an unknown version: the plane starts empty and
    /// re-uploads, which costs bandwidth but is always correct.
    static func restore(from data: Data) -> (registry: FileRegistry, pendingDeletions: [String])? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode(Snapshot.self, from: data),
              decoded.version == Self.snapshotVersion else { return nil }
        var registry = FileRegistry()
        for entry in decoded.entries { registry.entries[entry.digest] = entry }
        return (registry, decoded.pendingDeletions)
    }
}
