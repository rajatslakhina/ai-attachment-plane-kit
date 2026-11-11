import Foundation

/// Every limit the plane enforces, in one value the app owns. Fields are
/// immutable and clamped on init, so a bad remote config cannot produce a
/// negative budget, a NaN safety factor or a zero-attempt retry loop, and no
/// caller can bypass the clamping by assigning a field afterwards.
public struct AttachmentLimits: Sendable, Equatable {
    /// Largest single file the plane will upload.
    public let maxFileBytes: Int
    /// Most attachments one request may carry (the Messages API caps images per request).
    public let maxAttachmentsPerRequest: Int
    /// A remote file is only reused if it outlives "now" by more than this, so a
    /// reference cannot expire between `prepare` and the request landing.
    public let reuseSafetyMargin: TimeInterval
    /// How long a file with no owners survives before garbage collection deletes it.
    public let orphanGracePeriod: TimeInterval
    /// Registry entries kept for dedup. Unreferenced entries beyond this are evicted (LRU)
    /// and their remote files queued for deletion.
    public let maxRegistryEntries: Int
    /// Remote deletions queued but not yet performed. Beyond this the oldest are dropped
    /// and counted as `abandonedRemoteFiles` (for a provider without expiry, such as
    /// Anthropic's Files API, those files then sit against the storage quota).
    public let maxPendingDeletions: Int
    /// Multiplier applied to a heuristic token estimate (never below 1).
    public let estimateSafetyFactor: Double

    public init(maxFileBytes: Int = 500 * 1024 * 1024,
                maxAttachmentsPerRequest: Int = 100,
                reuseSafetyMargin: TimeInterval = 15 * 60,
                orphanGracePeriod: TimeInterval = 24 * 60 * 60,
                maxRegistryEntries: Int = 512,
                maxPendingDeletions: Int = 256,
                estimateSafetyFactor: Double = 1.25) {
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxAttachmentsPerRequest = max(1, maxAttachmentsPerRequest)
        self.reuseSafetyMargin = reuseSafetyMargin.isFinite ? max(0, reuseSafetyMargin) : 0
        self.orphanGracePeriod = orphanGracePeriod.isFinite ? max(0, orphanGracePeriod) : 0
        self.maxRegistryEntries = max(1, maxRegistryEntries)
        self.maxPendingDeletions = max(1, maxPendingDeletions)
        self.estimateSafetyFactor = estimateSafetyFactor.isFinite ? max(1, estimateSafetyFactor) : 1
    }
}

/// Exponential backoff with full jitter, for transient upload failures only.
/// Permanent failures (bad media type, payload too large) are never retried.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    /// Maps a computed delay `d` to the delay actually slept; the result is
    /// clamped to `0...d`. Injected so tests are deterministic.
    public let jitter: @Sendable (TimeInterval) -> TimeInterval

    public init(maxAttempts: Int = 4, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8,
                jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { d in d > 0 ? Double.random(in: 0...d) : 0 }) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay.isFinite ? max(0, baseDelay) : 0
        self.maxDelay = maxDelay.isFinite ? max(0, maxDelay) : 0
        self.jitter = jitter
    }

    /// Delay before retry number `attempt` (1-based: the delay after the first failure is attempt 1).
    public func delay(beforeRetry attempt: Int) -> TimeInterval {
        // `max(attempt, 1) - 1` cannot overflow, even for Int.min.
        let exponent = Double(min(max(attempt, 1) - 1, 30)) // 2^30 × base is already far past any cap
        let raw = min(baseDelay * pow(2, exponent), maxDelay)
        let jittered = jitter(raw)
        guard jittered.isFinite else { return raw }
        return min(max(jittered, 0), raw)
    }
}

/// How many input tokens an attachment will cost. The heuristic is the
/// fallback; the exact count comes from the provider's token-counting endpoint.
public protocol TokenEstimating: Sendable {
    func estimate(_ source: AttachmentSource) -> Int
}

/// Image: Anthropic's published approximation, `width × height / 750`, after
/// the long edge is scaled down to 1568 px. Unknown size: a conservative
/// ceiling. PDF: a per-page cost (text plus the page image). Text: 1 token per
/// 3 bytes, rounded up (deliberately pessimistic for English).
public struct HeuristicTokenEstimator: TokenEstimating {
    public var maxLongEdge: Int
    public var unknownImageTokens: Int
    public var tokensPerPDFPage: Int
    public var bytesPerPDFPageGuess: Int

    public init(maxLongEdge: Int = 1568, unknownImageTokens: Int = 1600,
                tokensPerPDFPage: Int = 2300, bytesPerPDFPageGuess: Int = 60_000) {
        self.maxLongEdge = max(1, maxLongEdge)
        self.unknownImageTokens = max(0, unknownImageTokens)
        self.tokensPerPDFPage = max(0, tokensPerPDFPage)
        self.bytesPerPDFPageGuess = max(1, bytesPerPDFPageGuess)
    }

    public func estimate(_ source: AttachmentSource) -> Int {
        switch source.mediaType.kind {
        case .image:
            guard let size = source.pixelSize, size.width > 0, size.height > 0 else { return unknownImageTokens }
            let w = Double(size.width), h = Double(size.height)
            let scale = min(1, Double(max(1, maxLongEdge)) / max(w, h))
            return max(1, Saturating.int(((w * scale) * (h * scale) / 750).rounded(.up)))
        case .document:
            let perPage = max(1, bytesPerPDFPageGuess) // public var: re-clamp, it may have been mutated
            let pages: Int
            if let known = source.pageCount, known > 0 {
                pages = known
            } else {
                pages = max(1, Saturating.add(source.bytes.count, perPage - 1) / perPage)
            }
            return Saturating.multiply(pages, max(0, tokensPerPDFPage))
        case .text:
            return Saturating.add(source.bytes.count, 2) / 3
        }
    }
}

/// The exact count, usually a call to `POST /v1/messages/count_tokens`.
public protocol TokenCounting: Sendable {
    func countTokens(for sources: [AttachmentSource]) async throws -> Int
}

public struct CostReport: Sendable, Equatable {
    public enum Basis: String, Sendable {
        /// The provider counted the tokens.
        case counted
        /// No counter was configured; heuristic × safety factor.
        case estimated
        /// The counter failed; heuristic × safety factor. Admission still ran.
        case estimatedAfterCounterFailure
    }
    public let inputTokens: Int
    public let basis: Basis
    public let totalBytes: Int
}

public enum AdmissionRefusal: Error, Equatable, Sendable {
    case noAttachments
    case tooManyAttachments(count: Int, limit: Int)
    case fileTooLarge(name: String, bytes: Int, limit: Int)
    case emptyFile(name: String)
    case overTokenBudget(tokens: Int, budget: Int, basis: CostReport.Basis)
}

/// Pure admission: everything that can be decided without the network, then the
/// token budget. Runs before any upload, so a refused request costs nothing.
struct Admission: Sendable {
    let limits: AttachmentLimits
    let estimator: TokenEstimating
    let counter: TokenCounting?

    func structuralCheck(_ sources: [AttachmentSource]) -> AdmissionRefusal? {
        guard !sources.isEmpty else { return .noAttachments }
        guard sources.count <= limits.maxAttachmentsPerRequest else {
            return .tooManyAttachments(count: sources.count, limit: limits.maxAttachmentsPerRequest)
        }
        for source in sources {
            if source.bytes.isEmpty { return .emptyFile(name: source.name) }
            if source.bytes.count > limits.maxFileBytes {
                return .fileTooLarge(name: source.name, bytes: source.bytes.count, limit: limits.maxFileBytes)
            }
        }
        return nil
    }

    func cost(_ sources: [AttachmentSource]) async -> CostReport {
        let bytes = sources.reduce(0) { Saturating.add($0, $1.bytes.count) }
        if let counter {
            do {
                let counted = try await counter.countTokens(for: sources)
                return CostReport(inputTokens: max(0, counted), basis: .counted, totalBytes: bytes)
            } catch {
                return CostReport(inputTokens: padded(sources), basis: .estimatedAfterCounterFailure, totalBytes: bytes)
            }
        }
        return CostReport(inputTokens: padded(sources), basis: .estimated, totalBytes: bytes)
    }

    private func padded(_ sources: [AttachmentSource]) -> Int {
        let raw = sources.reduce(0) { Saturating.add($0, max(0, estimator.estimate($1))) }
        return Saturating.int((Double(raw) * limits.estimateSafetyFactor).rounded(.up))
    }
}
