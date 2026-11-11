#if canImport(SwiftUI)
import Foundation
import Observation
import AttachmentPlane

/// The compiled-in configuration the host app owns and hands to the console.
public struct ConsoleConfiguration: Sendable {
    public var limits: AttachmentLimits
    /// How long the simulated provider keeps a file.
    public var fileTTL: TimeInterval
    /// Real seconds each simulated upload takes, so concurrent callers overlap visibly.
    public var uploadLatency: TimeInterval
    /// Input-token budget applied to every request the console makes.
    public var tokenBudget: Int

    public init(limits: AttachmentLimits, fileTTL: TimeInterval, uploadLatency: TimeInterval, tokenBudget: Int) {
        self.limits = limits
        self.fileTTL = fileTTL
        self.uploadLatency = uploadLatency
        self.tokenBudget = tokenBudget
    }
}

/// The scripted situations the console can drive. Each one exercises one of
/// the plane's guarantees against the simulated provider.
public enum ConsoleScenario: String, CaseIterable, Sendable, Identifiable {
    case sharePhoto, burst, expiry, providerLoss, flakyNetwork, overBudget, collect

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sharePhoto: return "Share one photo in 3 chats"
        case .burst: return "5 chats attach the same PDF at once"
        case .expiry: return "Jump 30 days, share the photo again"
        case .providerLoss: return "Provider loses the photo, then send"
        case .flakyNetwork: return "Upload over a flaky network"
        case .overBudget: return "Attach a 40-page PDF over budget"
        case .collect: return "Close every chat, wait, collect"
        }
    }

    public var guarantee: String {
        switch self {
        case .sharePhoto: return "Upload once per content"
        case .burst: return "Single flight"
        case .expiry: return "No near-dead references"
        case .providerLoss: return "Self-healing send"
        case .flakyNetwork: return "Transient-only retry with backoff"
        case .overBudget: return "Refuse before spending"
        case .collect: return "Owner-counted garbage collection"
        }
    }

    public var symbol: String {
        switch self {
        case .sharePhoto: return "photo.on.rectangle.angled"
        case .burst: return "arrow.triangle.merge"
        case .expiry: return "hourglass"
        case .providerLoss: return "bandage"
        case .flakyNetwork: return "wifi.exclamationmark"
        case .overBudget: return "gauge.with.needle"
        case .collect: return "trash"
        }
    }
}

public struct ConsoleLogLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let symbol: String
    public let text: String
}

@MainActor
@Observable
public final class AttachmentConsoleModel {
    public private(set) var metrics = PlaneMetrics()
    public private(set) var entries: [RegistryEntry] = []
    public private(set) var liveRemoteFiles = 0
    public private(set) var log: [ConsoleLogLine] = []
    public private(set) var busy = false
    public private(set) var lastOutcome = "Pick a scenario. Every number below comes from the real AttachmentPlane actor running against a simulated Files API."
    public private(set) var elapsedDays = 0.0
    public let configuration: ConsoleConfiguration

    private let clock = ManualClock()
    private let start: Date
    private let service: SimulatedFileService
    private let plane: AttachmentPlane
    private var owners: Set<String> = []
    private var nextLine = 0
    private var names: [ContentDigest: String] = [:]
    private var flakyRuns = 0
    private static let maxLogLines = 200

    // Synthetic but deterministic content: the plane only cares about bytes.
    private let photo = AttachmentSource(name: "IMG_4120.jpg", bytes: AttachmentConsoleModel.content(480_000, seed: 1),
                                         mediaType: .jpeg, pixelSize: PixelSize(width: 4032, height: 3024))
    private let contract = AttachmentSource(name: "lease-agreement.pdf", bytes: AttachmentConsoleModel.content(320_000, seed: 2),
                                            mediaType: .pdf, pageCount: 6)
    private let screenshot = AttachmentSource(name: "crash-screenshot.png", bytes: AttachmentConsoleModel.content(150_000, seed: 3),
                                              mediaType: .png, pixelSize: PixelSize(width: 1179, height: 2556))
    private let longPDF = AttachmentSource(name: "annual-report.pdf", bytes: AttachmentConsoleModel.content(90_000, seed: 4),
                                           mediaType: .pdf, pageCount: 40)

    public init(configuration: ConsoleConfiguration) {
        self.configuration = configuration
        start = clock.now
        service = SimulatedFileService(clock: clock, ttl: configuration.fileTTL, latency: configuration.uploadLatency)
        let (stream, continuation) = AsyncStream<PlaneEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        plane = AttachmentPlane(fileService: service, clock: clock, limits: configuration.limits,
                                retry: RetryPolicy(maxAttempts: 4, baseDelay: 0.5, maxDelay: 8),
                                observer: { continuation.yield($0) })
        for source in [photo, contract, screenshot, longPDF] {
            names[ContentDigest.sha256(source.bytes)] = source.name
        }
        Task { [weak self] in
            for await event in stream { self?.record(event) }
        }
    }

    public func run(_ scenario: ConsoleScenario) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let budget = configuration.tokenBudget
        let before = await plane.currentMetrics()
        do {
            switch scenario {
            case .sharePhoto:
                for chat in ["chat-A", "chat-B", "chat-C"] {
                    let prepared = try await plane.prepare([photo], owner: chat, tokenBudget: budget)
                    owners.insert(chat)
                    if let ref = prepared.references.first { note("arrow.right", "\(chat): \(ref.fileID) (\(ref.resolution.rawValue))") }
                }
                let after = await plane.currentMetrics()
                lastOutcome = "Three chats: \(after.uploads - before.uploads) upload(s), \(after.reuses - before.reuses) reuse(s) of the same file id."
            case .burst:
                let chats = (1...5).map { "team-\($0)" }
                let source = contract
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for chat in chats {
                        group.addTask { [plane] in _ = try await plane.prepare([source], owner: chat, tokenBudget: budget) }
                    }
                    try await group.waitForAll()
                }
                owners.formUnion(chats)
                let after = await plane.currentMetrics()
                lastOutcome = "Five concurrent callers: \(after.uploads - before.uploads) upload(s), \(after.joinedInFlight - before.joinedInFlight) joined in flight, \(after.reuses - before.reuses) reused a live file."
            case .expiry:
                let replacedBefore = before.expiringReplaced
                clock.advance(by: 30 * 86_400)
                let prepared = try await plane.prepare([photo], owner: "chat-D", tokenBudget: budget)
                owners.insert("chat-D")
                let replaced = await plane.currentMetrics().expiringReplaced > replacedBefore
                switch (replaced, prepared.references.first?.resolution) {
                case (true, _):
                    lastOutcome = "The photo's file expires inside the safety margin, so the plane uploaded a fresh one instead of handing out a near-dead id."
                case (false, .some(.reused)):
                    lastOutcome = "The photo's file was still comfortably alive, so it was reused."
                default:
                    lastOutcome = "The photo was not known yet, so it was uploaded. Share it first, then jump again to see the expiry rule."
                }
            case .providerLoss:
                let current = try await plane.prepare([photo], owner: "chat-A", tokenBudget: budget)
                owners.insert("chat-A")
                if let id = current.references.first?.fileID {
                    await service.forget(fileID: id)
                    note("exclamationmark.triangle", "provider purged \(id)")
                }
                let service = self.service
                let used = try await plane.send([photo], owner: "chat-A", tokenBudget: budget) { refs in
                    try await service.validate(refs.map(\.fileID))
                    return refs.map(\.fileID)
                }
                let after = await plane.currentMetrics()
                lastOutcome = after.heals > before.heals
                    ? "The send hit a 404, the plane invalidated that id, re-uploaded and the retry used \(used.joined(separator: ", "))."
                    : "The send succeeded without healing, using \(used.joined(separator: ", "))."
            case .flakyNetwork:
                // Fresh bytes every run, so the two scripted faults are always
                // consumed by this upload and never leak into a later scenario.
                flakyRuns += 1
                let shot = AttachmentSource(name: "crash-screenshot-\(flakyRuns).png",
                                            bytes: Self.content(150_000, seed: UInt32(truncatingIfNeeded: 1_000 &+ flakyRuns)),
                                            mediaType: .png, pixelSize: screenshot.pixelSize)
                names[ContentDigest.sha256(shot.bytes)] = shot.name
                await service.failNextUploads([.transient("HTTP 503"), .transient("connection reset")])
                let prepared = try await plane.prepare([shot], owner: "bug-report", tokenBudget: budget)
                owners.insert("bug-report")
                let after = await plane.currentMetrics()
                lastOutcome = "\(after.retries - before.retries) transient failure(s) retried with backoff; \(prepared.references.first?.fileID ?? "?") landed."
            case .overBudget:
                _ = try await plane.prepare([longPDF], owner: "chat-B", tokenBudget: budget)
                owners.insert("chat-B")
                lastOutcome = "Admitted: the budget is large enough for this PDF."
            case .collect:
                for owner in owners.sorted() { await plane.release(owner: owner) }
                owners.removeAll()
                clock.advance(by: configuration.limits.orphanGracePeriod + 1)
                let report = await plane.collectGarbage()
                lastOutcome = "Released every chat, waited out the grace period: deleted \(report.deleted), already gone \(report.alreadyGone), failed \(report.failed)."
            }
        } catch let error as AttachmentPlaneError {
            lastOutcome = Self.describe(error)
        } catch {
            lastOutcome = "Failed: \(error)"
        }
        await refresh()
    }

    public func refresh() async {
        // Let the event stream drain so the log and the counters agree.
        for _ in 0..<3 { await Task.yield() }
        metrics = await plane.currentMetrics()
        entries = await plane.entries()
        liveRemoteFiles = await service.liveFileIDs().count
        elapsedDays = clock.now.timeIntervalSince(start) / 86_400
    }

    public func displayName(for digest: ContentDigest) -> String { names[digest] ?? digest.description }

    public func expiryText(for entry: RegistryEntry) -> String {
        guard let remote = entry.remote else { return "lost by provider" }
        guard let expiry = remote.expiresAt else { return "no expiry" }
        let remaining = expiry.timeIntervalSince(clock.now)
        if remaining <= 0 { return "expired" }
        let days = remaining / 86_400
        return days >= 1 ? String(format: "%.0f d left", days) : String(format: "%.1f h left", remaining / 3600)
    }

    // MARK: Event log

    private func record(_ event: PlaneEvent) {
        switch event {
        case .admitted(let cost):
            note("checkmark.seal", "admitted: \(cost.inputTokens) tokens (\(cost.basis.rawValue)), \(Self.bytes(cost.totalBytes))")
        case .refused(let refusal):
            note("hand.raised", "refused before upload: \(Self.describe(refusal))")
        case .uploaded(let name, _, let fileID, let attempts):
            note("icloud.and.arrow.up", "uploaded \(name) → \(fileID)" + (attempts > 1 ? " on attempt \(attempts)" : ""))
        case .retrying(let name, let attempt, let delay, let reason):
            note("arrow.clockwise", "\(name): \(reason), retry \(attempt) after \(String(format: "%.2f", delay)) s")
        case .reused(let name, let fileID):
            note("arrow.triangle.2.circlepath", "reused \(fileID) for \(name)")
        case .joinedInFlight(let name, _):
            note("arrow.triangle.merge", "joined the upload already in flight for \(name)")
        case .duplicateInBatch(let name):
            note("doc.on.doc", "\(name) appears twice in one request; sent once")
        case .replacingExpiring(let digest, let oldFileID):
            note("hourglass", "\(oldFileID) for \(displayName(for: digest)) is inside the safety margin; uploading fresh")
        case .invalidated(let fileID):
            note("xmark.octagon", "provider no longer has \(fileID); mapping invalidated")
        case .healed(let fileIDs):
            note("bandage", "healed after missing \(fileIDs.joined(separator: ", "))")
        case .collected(let fileID):
            note("trash", "deleted orphaned \(fileID)")
        case .evicted(let digest):
            note("tray.and.arrow.up", "evicted \(displayName(for: digest)) from the index (LRU)")
        case .snapshotDiscarded:
            note("exclamationmark.triangle", "stored registry was unreadable; started empty")
        }
    }

    private func note(_ symbol: String, _ text: String) {
        nextLine += 1
        log.insert(ConsoleLogLine(id: nextLine, symbol: symbol, text: text), at: 0)
        if log.count > Self.maxLogLines { log.removeLast(log.count - Self.maxLogLines) }
    }

    private static func describe(_ error: AttachmentPlaneError) -> String {
        switch error {
        case .refused(let refusal): return "Refused before any upload: \(describe(refusal))."
        case .uploadFailed(let name, let error, let attempts): return "Upload of \(name) failed after \(attempts) attempt(s): \(error)."
        }
    }

    private static func describe(_ refusal: AdmissionRefusal) -> String {
        switch refusal {
        case .noAttachments: return "no attachments"
        case .tooManyAttachments(let count, let limit): return "\(count) attachments, limit \(limit)"
        case .fileTooLarge(let name, let size, let limit): return "\(name) is \(bytes(size)), limit \(bytes(limit))"
        case .emptyFile(let name): return "\(name) is empty"
        case .overTokenBudget(let tokens, let budget, let basis):
            return "\(tokens) input tokens (\(basis.rawValue)) exceeds the \(budget)-token budget"
        }
    }

    static func bytes(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1f MB", Double(count) / 1_000_000)
            : String(format: "%.0f KB", Double(count) / 1_000)
    }

    private static func content(_ count: Int, seed: UInt32) -> [UInt8] {
        var state = seed &* 2_654_435_761 | 1
        return (0..<count).map { _ in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        }
    }
}
#endif
