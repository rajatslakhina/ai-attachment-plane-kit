import Foundation

public enum AttachmentPlaneError: Error, Equatable, Sendable {
    case refused(AdmissionRefusal)
    case uploadFailed(name: String, error: FileServiceError, attempts: Int)
}

/// Thrown by a `send` operation to say the provider no longer has these files
/// (for Claude: a 404 / `not_found_error` naming a `file_id`).
public struct MissingRemoteFiles: Error, Equatable, Sendable {
    public let fileIDs: [String]
    public init(fileIDs: [String]) { self.fileIDs = fileIDs }
}

public struct PreparedAttachments: Sendable {
    public let references: [AttachmentReference]
    public let cost: CostReport
}

public struct GarbageCollectionReport: Sendable, Equatable {
    public var deleted = 0
    public var alreadyGone = 0
    public var failed = 0
    public init() {}
}

public enum PlaneEvent: Sendable, Equatable {
    case admitted(CostReport)
    case refused(AdmissionRefusal)
    case uploaded(name: String, digest: ContentDigest, fileID: String, attempts: Int)
    case retrying(name: String, attempt: Int, delay: TimeInterval, reason: String)
    case reused(name: String, fileID: String)
    case joinedInFlight(name: String, digest: ContentDigest)
    case duplicateInBatch(name: String)
    case replacingExpiring(digest: ContentDigest, oldFileID: String)
    case invalidated(fileID: String)
    case healed(fileIDs: [String])
    case collected(fileID: String)
    case evicted(digest: ContentDigest)
    case snapshotDiscarded
}

public struct PlaneMetrics: Sendable, Equatable {
    public var uploads = 0
    public var uploadAttempts = 0
    public var retries = 0
    public var reuses = 0
    public var joinedInFlight = 0
    public var duplicatesInBatch = 0
    public var expiringReplaced = 0
    public var heals = 0
    public var refusals = 0
    public var counterFailures = 0
    public var collected = 0
    public var evictions = 0
    public var abandonedRemoteFiles = 0
    public var persistFailures = 0
    public var bytesUploaded = 0
    /// Bytes a naive "upload every attachment" client would have sent and this one did not.
    public var bytesNotUploaded = 0
    public init() {}
}

/// Content-addressed attachment plane for multimodal AI requests.
///
/// System guarantees (each has a test, and the load-bearing ones a mutation in
/// `scripts/mutation-check.sh`):
/// 1. **Upload once per content.** Identical bytes, across conversations and
///    within one batch, map to one remote file while it is live.
/// 2. **Single flight.** Concurrent `prepare` calls for the same bytes share one
///    upload, including its retries.
/// 3. **No near-dead references.** A file is only reused if it outlives now by
///    more than `reuseSafetyMargin`; otherwise it is uploaded again.
/// 4. **Refuse before spending.** Size, count and token-budget admission run
///    before any byte is uploaded.
/// 5. **Self-healing sends.** If the provider lost a file, `send` invalidates
///    exactly that mapping, re-uploads and retries once.
/// 6. **GC never races reuse.** Entries leave the index before their deletion is
///    awaited, and a failed deletion never overwrites a newer mapping.
/// 7. **Bounded state.** The index (for unowned entries) and the deletion queue
///    are capped; overflow costs dedup or is counted as `abandonedRemoteFiles`,
///    never correctness.
/// 8. **No leak across a crash.** Fresh uploads start orphaned until retained,
///    and owed deletions (including in-progress ones) are persisted.
public actor AttachmentPlane {
    private let fileService: FileService
    private let clock: PlaneClock
    private let limits: AttachmentLimits
    private let retry: RetryPolicy
    private let admission: Admission
    private let store: RegistryStore?
    private let observer: (@Sendable (PlaneEvent) -> Void)?

    private var registry = FileRegistry()
    private var inFlight: [ContentDigest: (token: UInt64, task: Task<RemoteFile, Error>)] = [:]
    private var nextToken: UInt64 = 0
    /// Digests a `prepare` is between deciding and retaining. GC and eviction skip them.
    private var pins: [ContentDigest: Int] = [:]
    private var pendingDeletions: [String] = []
    /// Remote files any GC pass is deleting right now (passes may overlap; their
    /// ids are disjoint). Persisted with the queue, so a crash between "left the
    /// index or the queue" and "delete confirmed" cannot leak them.
    private var deleting: Set<String> = []
    private var metrics = PlaneMetrics()

    public init(fileService: FileService,
                clock: PlaneClock = SystemClock(),
                limits: AttachmentLimits = AttachmentLimits(),
                retry: RetryPolicy = RetryPolicy(),
                estimator: TokenEstimating = HeuristicTokenEstimator(),
                tokenCounter: TokenCounting? = nil,
                store: RegistryStore? = nil,
                observer: (@Sendable (PlaneEvent) -> Void)? = nil) {
        self.fileService = fileService
        self.clock = clock
        self.limits = limits
        self.retry = retry
        self.admission = Admission(limits: limits, estimator: estimator, counter: tokenCounter)
        self.store = store
        self.observer = observer
        if let store, let data = try? store.load() {
            if let restored = FileRegistry.restore(from: data) {
                registry = restored.registry
                // Capped like any other enqueue (see `enqueueDeletion`); the cap is >= 1.
                let owed = restored.pendingDeletions
                pendingDeletions = Array(owed.suffix(limits.maxPendingDeletions))
                metrics.abandonedRemoteFiles = owed.count - pendingDeletions.count
            } else {
                observer?(.snapshotDiscarded)
            }
        }
    }

    // MARK: Public API

    /// Admits, hashes and resolves `sources` to remote file references owned by
    /// `owner`. Hashing runs off the actor (this method is `nonisolated`), so a
    /// large PDF never blocks other conversations' lookups.
    public nonisolated func prepare(_ sources: [AttachmentSource], owner: String,
                                    tokenBudget: Int? = nil) async throws -> PreparedAttachments {
        if let refusal = admission.structuralCheck(sources) {
            await noteRefusal(refusal)
            throw AttachmentPlaneError.refused(refusal)
        }
        let cost = await admission.cost(sources)
        if let budget = tokenBudget, cost.inputTokens > max(0, budget) {
            let refusal = AdmissionRefusal.overTokenBudget(tokens: cost.inputTokens, budget: max(0, budget), basis: cost.basis)
            await noteRefusal(refusal)
            throw AttachmentPlaneError.refused(refusal)
        }
        let digests = sources.map { ContentDigest.sha256($0.bytes) }
        let references = try await resolve(sources, digests: digests, owner: owner, cost: cost)
        return PreparedAttachments(references: references, cost: cost)
    }

    /// Prepares, runs `operation` with the references, and if the operation
    /// reports `MissingRemoteFiles`, heals exactly those mappings and retries
    /// once. A second miss propagates: looping would hide a provider outage.
    public nonisolated func send<T: Sendable>(
        _ sources: [AttachmentSource], owner: String, tokenBudget: Int? = nil,
        operation: @Sendable ([AttachmentReference]) async throws -> T
    ) async throws -> T {
        let first = try await prepare(sources, owner: owner, tokenBudget: tokenBudget)
        do {
            return try await operation(first.references)
        } catch let missing as MissingRemoteFiles {
            await invalidate(fileIDs: missing.fileIDs)
            let second = try await prepare(sources, owner: owner, tokenBudget: tokenBudget)
            let result = try await operation(second.references)
            await noteHeal(missing.fileIDs) // counted only when the retry succeeded
            return result
        }
    }

    /// The conversation closed or the draft was discarded.
    ///
    /// Known v1 limitation: a `release` that lands while a `prepare` for the
    /// same owner is still awaiting an upload is undone when that `prepare`
    /// retains. Release again (or on next launch) to reclaim.
    public func release(owner: String) {
        registry.release(owner: owner, now: clock.now)
        persist() // release: the orphan timestamp must survive a relaunch
    }

    /// Deletes remote files orphaned past the grace period, then drains the
    /// eviction queue. Safe to run concurrently with `prepare`.
    @discardableResult
    public func collectGarbage() async -> GarbageCollectionReport {
        var report = GarbageCollectionReport()
        let protected = Set(pins.keys).union(inFlight.keys)
        let due = registry.collectible(now: clock.now, grace: limits.orphanGracePeriod,
                                       excluding: protected, remove: true)
        deleting.formUnion(due.compactMap { $0.remote?.id })
        persist()
        for entry in due {
            guard let remote = entry.remote else { continue } // lost by the provider: nothing to delete
            defer { deleting.remove(remote.id) }
            do {
                try await fileService.delete(fileID: remote.id)
                report.deleted += 1
                metrics.collected += 1
                emit(.collected(fileID: remote.id))
                registry.removeIfUnchanged(entry)
            } catch FileServiceError.notFound {
                report.alreadyGone += 1
                registry.removeIfUnchanged(entry)
            } catch {
                report.failed += 1
                // Re-checked after the await. If the digest was re-uploaded
                // meanwhile, or an upload for it is still in flight (it will
                // overwrite whatever we restore), keep the newer mapping and
                // queue the old file instead.
                if inFlight[entry.digest] != nil || !registry.restore(entry) { enqueueDeletion(remote.id) }
            }
        }
        let queued = pendingDeletions
        pendingDeletions.removeAll()
        deleting.formUnion(queued)
        persist()
        for fileID in queued {
            defer { deleting.remove(fileID) }
            do {
                try await fileService.delete(fileID: fileID)
                report.deleted += 1
                metrics.collected += 1
                emit(.collected(fileID: fileID))
            } catch FileServiceError.notFound {
                report.alreadyGone += 1
            } catch {
                report.failed += 1
                enqueueDeletion(fileID)
            }
        }
        persist()
        return report
    }

    public func currentMetrics() -> PlaneMetrics { metrics }
    public func entries() -> [RegistryEntry] { registry.entries.values.sorted { $0.digest < $1.digest } }
    public func pendingDeletionCount() -> Int { pendingDeletions.count }
    public func inFlightCount() -> Int { inFlight.count }
    /// Test hook: how many in-progress `prepare` calls have pinned `digest`.
    func pinCount(_ digest: ContentDigest) -> Int { pins[digest] ?? 0 }

    // MARK: Resolution

    private enum Pending {
        case ready(RemoteFile)
        case waiting(Task<RemoteFile, Error>)
    }

    private func resolve(_ sources: [AttachmentSource], digests: [ContentDigest], owner: String,
                         cost: CostReport) async throws -> [AttachmentReference] {
        if cost.basis == .estimatedAfterCounterFailure { metrics.counterFailures += 1 }
        emit(.admitted(cost))
        let now = clock.now
        var resolution: [AttachmentReference.Resolution] = []
        var pending: [ContentDigest: Pending] = [:]
        var order: [ContentDigest] = []

        // Decide synchronously (no suspension point in this loop), so every
        // decision sees one consistent snapshot of the index, then pin every
        // digest before the first await.
        for (index, source) in sources.enumerated() {
            guard index < digests.count else { break } // equal by construction (`map`)
            let digest = digests[index]
            if pending[digest] != nil {
                resolution.append(.duplicateInBatch)
                continue
            }
            order.append(digest)
            if let remote = registry.usable(digest, now: now, margin: limits.reuseSafetyMargin) {
                registry.touch(digest, now: now)
                pending[digest] = .ready(remote)
                resolution.append(.reused)
            } else if let flight = inFlight[digest] {
                pending[digest] = .waiting(flight.task)
                resolution.append(.joinedInFlight)
            } else {
                if let stale = registry.entry(digest)?.remote {
                    metrics.expiringReplaced += 1
                    emit(.replacingExpiring(digest: digest, oldFileID: stale.id))
                }
                pending[digest] = .waiting(startUpload(source, digest: digest))
                resolution.append(.uploaded)
            }
        }
        for digest in order { pins[digest, default: 0] += 1 }
        defer { for digest in order { unpin(digest) } }

        var remotes: [ContentDigest: RemoteFile] = [:]
        do {
            for digest in order {
                switch pending[digest] {
                case .ready(let remote): remotes[digest] = remote
                case .waiting(let task): remotes[digest] = try await task.value
                case nil: break
                }
            }
        } catch {
            // All-or-nothing: nothing is retained. Every upload this batch
            // started, finished or still in flight, was (or will be) recorded
            // already orphaned (`FileRegistry.record`), so GC reclaims it once
            // the pins drop.
            // Upload tasks only ever throw `AttachmentPlaneError` (see `startUpload`).
            if let planeError = error as? AttachmentPlaneError { throw planeError }
            throw AttachmentPlaneError.uploadFailed(name: "(unknown)", error: .permanent(String(describing: error)), attempts: 0)
        }

        var references: [AttachmentReference] = []
        for (index, source) in sources.enumerated() {
            guard index < digests.count, index < resolution.count, let remote = remotes[digests[index]] else { continue }
            let kind = resolution[index]
            switch kind {
            case .uploaded: break
            case .reused:
                metrics.reuses += 1
                emit(.reused(name: source.name, fileID: remote.id))
            case .joinedInFlight:
                metrics.joinedInFlight += 1
                emit(.joinedInFlight(name: source.name, digest: digests[index]))
            case .duplicateInBatch:
                metrics.duplicatesInBatch += 1
                emit(.duplicateInBatch(name: source.name))
            }
            if kind != .uploaded {
                metrics.bytesNotUploaded = Saturating.add(metrics.bytesNotUploaded, source.bytes.count)
            }
            references.append(AttachmentReference(name: source.name, digest: digests[index], fileID: remote.id,
                                                  mediaType: source.mediaType, resolution: kind))
        }
        for digest in order { registry.retain(digest, owner: owner) }
        evictOverflow()
        persist()
        return references
    }

    /// Starts the one upload for `digest`. The task runs on this actor between
    /// its awaits, records its own result, and is shared by every joiner. It is
    /// an unstructured task, so cancelling one caller does not cancel the
    /// upload the others wait on (v1 callers are not cancellable mid-await;
    /// a cancelled caller still receives its references). An upload failure is
    /// reported to every joiner with the uploading attachment's name.
    private func startUpload(_ source: AttachmentSource, digest: ContentDigest) -> Task<RemoteFile, Error> {
        nextToken &+= 1
        let token = nextToken
        let task = Task<RemoteFile, Error> {
            var attempt = 0
            while true {
                attempt += 1
                self.metrics.uploadAttempts += 1
                do {
                    let remote = try await self.fileService.upload(source.bytes, mediaType: source.mediaType,
                                                                   digest: digest, name: source.name)
                    self.finishUpload(source, digest: digest, token: token, remote: remote, attempts: attempt)
                    return remote
                } catch let error as FileServiceError {
                    guard case .transient(let reason) = error, attempt < self.retry.maxAttempts else {
                        self.clearInFlight(digest, token: token)
                        throw AttachmentPlaneError.uploadFailed(name: source.name, error: error, attempts: attempt)
                    }
                    let delay = self.retry.delay(beforeRetry: attempt)
                    self.metrics.retries += 1
                    self.emit(.retrying(name: source.name, attempt: attempt, delay: delay, reason: reason))
                    do {
                        try await self.clock.sleep(seconds: delay)
                    } catch {
                        self.clearInFlight(digest, token: token)
                        throw AttachmentPlaneError.uploadFailed(name: source.name, error: .transient("backoff cancelled"), attempts: attempt)
                    }
                } catch {
                    self.clearInFlight(digest, token: token)
                    throw AttachmentPlaneError.uploadFailed(name: source.name, error: .permanent(String(describing: error)), attempts: attempt)
                }
            }
        }
        // The task cannot run before this synchronous method returns (it needs
        // the actor), so the entry is always in place before it can finish.
        inFlight[digest] = (token, task)
        return task
    }

    private func finishUpload(_ source: AttachmentSource, digest: ContentDigest, token: UInt64,
                              remote: RemoteFile, attempts: Int) {
        registry.record(digest, remote: remote, mediaType: source.mediaType,
                        byteCount: source.bytes.count, now: clock.now)
        clearInFlight(digest, token: token)
        metrics.uploads += 1
        metrics.bytesUploaded = Saturating.add(metrics.bytesUploaded, source.bytes.count)
        emit(.uploaded(name: source.name, digest: digest, fileID: remote.id, attempts: attempts))
        persist() // finishUpload: a fresh upload is durable before any caller retains it
    }

    private func clearInFlight(_ digest: ContentDigest, token: UInt64) {
        if inFlight[digest]?.token == token { inFlight[digest] = nil }
    }

    private func unpin(_ digest: ContentDigest) {
        let remaining = (pins[digest] ?? 1) - 1
        pins[digest] = remaining > 0 ? remaining : nil
    }

    // MARK: Healing, eviction, persistence

    private func invalidate(fileIDs: [String]) {
        for fileID in fileIDs where registry.invalidate(fileID: fileID) {
            emit(.invalidated(fileID: fileID))
        }
        persist()
    }

    private func noteHeal(_ fileIDs: [String]) {
        metrics.heals += 1
        emit(.healed(fileIDs: fileIDs))
    }

    private func noteRefusal(_ refusal: AdmissionRefusal) {
        metrics.refusals += 1
        emit(.refused(refusal))
    }

    private func evictOverflow() {
        let protected = Set(pins.keys).union(inFlight.keys)
        for entry in registry.evictOverflow(limit: limits.maxRegistryEntries, excluding: protected) {
            metrics.evictions += 1
            emit(.evicted(digest: entry.digest))
            if let remote = entry.remote { enqueueDeletion(remote.id) }
        }
    }

    private func enqueueDeletion(_ fileID: String) {
        pendingDeletions.append(fileID)
        while pendingDeletions.count > limits.maxPendingDeletions {
            pendingDeletions.removeFirst()
            metrics.abandonedRemoteFiles += 1
        }
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(registry.snapshot(pendingDeletions: deleting.sorted() + pendingDeletions))
        } catch {
            metrics.persistFailures += 1
        }
    }

    private func emit(_ event: PlaneEvent) { observer?(event) }
}
