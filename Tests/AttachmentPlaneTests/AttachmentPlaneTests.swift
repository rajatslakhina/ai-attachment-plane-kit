import Foundation
import XCTest
@testable import AttachmentPlane

final class AttachmentPlaneTests: XCTestCase {
    private func makePlane(clock: ManualClock = ManualClock(), ttl: TimeInterval? = 3600,
                           limits: AttachmentLimits = AttachmentLimits(),
                           counter: TokenCounting? = nil, store: RegistryStore? = nil,
                           log: EventLog? = nil) -> (AttachmentPlane, SimulatedFileService, ManualClock) {
        let service = SimulatedFileService(clock: clock, ttl: ttl)
        var observer: (@Sendable (PlaneEvent) -> Void)?
        if let log { observer = { log.append($0) } }
        let plane = AttachmentPlane(fileService: service, clock: clock, limits: limits, retry: noJitter,
                                    tokenCounter: counter, store: store, observer: observer)
        return (plane, service, clock)
    }

    // MARK: 1. Upload once per content

    func testSameBytesAcrossConversationsUploadOnce() async throws {
        let (plane, service, _) = makePlane()
        let photo = image("IMG_0001.jpg", seed: 1)
        let a = try await plane.prepare([photo], owner: "chat-A")
        let b = try await plane.prepare([image("renamed-copy.jpg", seed: 1)], owner: "chat-B")
        let c = try await plane.prepare([photo], owner: "chat-C")
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual([a, b, c].compactMap { $0.references.first?.resolution }, [.uploaded, .reused, .reused])
        XCTAssertEqual(Set([a, b, c].compactMap { $0.references.first?.fileID }).count, 1)
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.reuses, 2)
        XCTAssertEqual(metrics.bytesUploaded, 4096)
        XCTAssertEqual(metrics.bytesNotUploaded, 8192)
        let owners = await plane.entries().first?.owners
        XCTAssertEqual(owners, ["chat-A", "chat-B", "chat-C"])
    }

    func testDuplicateInOneBatchRidesTheFirstUpload() async throws {
        let (plane, service, _) = makePlane()
        let prepared = try await plane.prepare([image("a", seed: 1), image("a-again", seed: 1), pdf("b", seed: 2)], owner: "o")
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(prepared.references.map(\.resolution), [.uploaded, .duplicateInBatch, .uploaded])
        XCTAssertEqual(prepared.references.map(\.name), ["a", "a-again", "b"]) // order preserved
        XCTAssertEqual(prepared.references[0].fileID, prepared.references[1].fileID)
    }

    // MARK: 2. Single flight

    func testConcurrentPreparesForSameBytesShareOneUpload() async throws {
        let clock = ManualClock()
        let gated = GatedFileService(inner: SimulatedFileService(clock: clock, ttl: 3600))
        await gated.holdUploadsAtGate()
        let plane = AttachmentPlane(fileService: gated, clock: clock, retry: noJitter)
        let source = pdf("contract.pdf", seed: 9)
        let digest = ContentDigest.sha256(source.bytes)

        let tasks = (0..<5).map { i in
            Task { try await plane.prepare([source], owner: "chat-\(i)") }
        }
        // Every caller has decided and pinned while the one upload is still held.
        await eventually("five callers pinned") { await plane.pinCount(digest) == 5 }
        await eventually("one upload at the gate") { await gated.waitingUploads == 1 }
        await gated.openUploadGate()

        var resolutions: [AttachmentReference.Resolution] = []
        for task in tasks { resolutions += try await task.value.references.map(\.resolution) }
        let uploads = await gated.inner.uploadCalls
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(resolutions.filter { $0 == .uploaded }.count, 1)
        XCTAssertEqual(resolutions.filter { $0 == .joinedInFlight }.count, 4)
        let inFlight = await plane.inFlightCount()
        XCTAssertEqual(inFlight, 0)
    }

    func testJoinersShareTheUploadersRetries() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: 3600)
        await inner.failNextUploads([.transient("503"), .transient("timeout")])
        let gated = GatedFileService(inner: inner)
        await gated.holdUploadsAtGate()
        let plane = AttachmentPlane(fileService: gated, clock: clock, retry: noJitter)
        let source = image("x", seed: 3)
        let digest = ContentDigest.sha256(source.bytes)
        let first = Task { try await plane.prepare([source], owner: "a") }
        let second = Task { try await plane.prepare([source], owner: "b") }
        await eventually("both pinned") { await plane.pinCount(digest) == 2 }
        await gated.openUploadGate()
        let ids = try await [first.value, second.value].compactMap { $0.references.first?.fileID }
        XCTAssertEqual(Set(ids).count, 1)
        let calls = await inner.uploadCalls
        XCTAssertEqual(calls, 3, "one upload, two retries — not one upload per caller")
    }

    func testJoinersReceiveTheLeadersFailureAndALaterPrepareSucceeds() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: 3600)
        await inner.failNextUploads([.permanent("413 too large")])
        let gated = GatedFileService(inner: inner)
        await gated.holdUploadsAtGate()
        let plane = AttachmentPlane(fileService: gated, clock: clock, retry: noJitter)
        let source = pdf("scan.pdf", seed: 4)
        let digest = ContentDigest.sha256(source.bytes)
        let leader = Task { try await plane.prepare([source], owner: "a") }
        let joiner = Task { try await plane.prepare([source], owner: "b") }
        await eventually("both pinned") { await plane.pinCount(digest) == 2 }
        await gated.openUploadGate()
        for task in [leader, joiner] {
            do {
                _ = try await task.value
                XCTFail("expected the shared failure")
            } catch let error as AttachmentPlaneError {
                XCTAssertEqual(error, .uploadFailed(name: "scan.pdf", error: .permanent("413 too large"), attempts: 1))
            }
        }
        let inFlight = await plane.inFlightCount()
        XCTAssertEqual(inFlight, 0)
        let later = try await plane.prepare([source], owner: "c")
        XCTAssertEqual(later.references.first?.resolution, .uploaded)
    }

    // MARK: 3. No near-dead references

    func testFileInsideTheSafetyMarginIsUploadedAgain() async throws {
        let log = EventLog()
        let (plane, service, clock) = makePlane(ttl: 3600, limits: AttachmentLimits(reuseSafetyMargin: 900), log: log)
        let photo = image("p", seed: 4)
        let first = try await plane.prepare([photo], owner: "a")
        clock.advance(by: 2700) // 15 min left == margin: not reusable (strictly more is required)
        let second = try await plane.prepare([photo], owner: "a")
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(second.references.first?.resolution, .uploaded)
        XCTAssertNotEqual(first.references.first?.fileID, second.references.first?.fileID)
        let replaced = log.all.contains { if case .replacingExpiring = $0 { return true }; return false }
        XCTAssertTrue(replaced)
        // The near-dead file is neither deleted nor queued: a request sent a
        // moment ago may still reference it.
        let queued = await plane.pendingDeletionCount()
        XCTAssertEqual(queued, 0)
        let live = await service.liveFileIDs()
        XCTAssertTrue(live.contains(first.references.first?.fileID ?? "-"))
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.expiringReplaced, 1)
    }

    func testFileOutsideTheSafetyMarginIsReused() async throws {
        let (plane, service, clock) = makePlane(ttl: 3600, limits: AttachmentLimits(reuseSafetyMargin: 900))
        let photo = image("p", seed: 4)
        _ = try await plane.prepare([photo], owner: "a")
        clock.advance(by: 2699) // 15 min + 1 s left
        let second = try await plane.prepare([photo], owner: "a")
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(second.references.first?.resolution, .reused)
    }

    func testFilesWithoutExpiryAreAlwaysReusable() async throws {
        let (plane, service, clock) = makePlane(ttl: nil)
        _ = try await plane.prepare([image("p", seed: 4)], owner: "a")
        clock.advance(by: 10 * 365 * 86_400)
        _ = try await plane.prepare([image("p", seed: 4)], owner: "a")
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 1)
    }

    // MARK: Retry classification

    func testTransientFailuresRetryWithBackoffThenSucceed() async throws {
        let log = EventLog()
        let (plane, service, clock) = makePlane(log: log)
        await service.failNextUploads([.transient("502"), .transient("reset")])
        let prepared = try await plane.prepare([image("p", seed: 5)], owner: "a")
        XCTAssertEqual(prepared.references.count, 1)
        XCTAssertEqual(clock.sleeps, [0.5, 1.0])
        let attempts = log.all.compactMap { event -> Int? in
            if case .uploaded(_, _, _, let attempts) = event { return attempts }
            return nil
        }
        XCTAssertEqual(attempts, [3])
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.retries, 2)
        XCTAssertEqual(metrics.uploadAttempts, 3)
    }

    func testPermanentFailureIsNeverRetried() async throws {
        let (plane, service, clock) = makePlane()
        await service.failNextUploads([.permanent("415 unsupported")])
        do {
            _ = try await plane.prepare([image("p", seed: 5)], owner: "a")
            XCTFail("expected failure")
        } catch let error as AttachmentPlaneError {
            XCTAssertEqual(error, .uploadFailed(name: "p", error: .permanent("415 unsupported"), attempts: 1))
        }
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    func testRetriesStopAtMaxAttempts() async throws {
        let (plane, service, clock) = makePlane()
        await service.failNextUploads(Array(repeating: .transient("503"), count: 4))
        do {
            _ = try await plane.prepare([image("p", seed: 5)], owner: "a")
            XCTFail("expected failure")
        } catch let error as AttachmentPlaneError {
            XCTAssertEqual(error, .uploadFailed(name: "p", error: .transient("503"), attempts: 4))
        }
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 4)
        XCTAssertEqual(clock.sleeps, [0.5, 1.0, 2.0])
        let inFlight = await plane.inFlightCount()
        XCTAssertEqual(inFlight, 0, "a failed upload must not stay in flight and poison later calls")
        let retried = try await plane.prepare([image("p", seed: 5)], owner: "a")
        XCTAssertEqual(retried.references.first?.resolution, .uploaded)
    }

    // MARK: 4. Refuse before spending

    func testStructuralRefusalsHappenBeforeAnyUpload() async throws {
        let (plane, service, _) = makePlane(limits: AttachmentLimits(maxFileBytes: 1000, maxAttachmentsPerRequest: 2))
        let cases: [([AttachmentSource], AdmissionRefusal)] = [
            ([], .noAttachments),
            ([image("a", seed: 1, count: 10), image("b", seed: 2, count: 10), image("c", seed: 3, count: 10)],
             .tooManyAttachments(count: 3, limit: 2)),
            ([image("big", seed: 1, count: 1001)], .fileTooLarge(name: "big", bytes: 1001, limit: 1000)),
            ([AttachmentSource(name: "empty", bytes: [], mediaType: .plainText)], .emptyFile(name: "empty")),
        ]
        for (sources, refusal) in cases {
            do {
                _ = try await plane.prepare(sources, owner: "o")
                XCTFail("expected refusal \(refusal)")
            } catch let error as AttachmentPlaneError {
                XCTAssertEqual(error, .refused(refusal))
            }
        }
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 0)
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.refusals, 4)
    }

    func testTokenBudgetUsesTheExactCountWhenAvailable() async throws {
        let (plane, service, _) = makePlane(counter: FixedCounter(value: 5000))
        do {
            _ = try await plane.prepare([image("p", seed: 1)], owner: "o", tokenBudget: 4999)
            XCTFail("expected refusal")
        } catch let error as AttachmentPlaneError {
            XCTAssertEqual(error, .refused(.overTokenBudget(tokens: 5000, budget: 4999, basis: .counted)))
        }
        let uploadsAfterRefusal = await service.uploadCalls
        XCTAssertEqual(uploadsAfterRefusal, 0)
        let ok = try await plane.prepare([image("p", seed: 1)], owner: "o", tokenBudget: 5000)
        XCTAssertEqual(ok.cost, CostReport(inputTokens: 5000, basis: .counted, totalBytes: 4096))
    }

    func testCounterFailureFallsBackToAPaddedEstimateAndStillEnforcesTheBudget() async throws {
        let (plane, _, _) = makePlane(counter: FailingCounter())
        // 1000×750 → 1000 tokens; × 1.25 safety factor → 1250.
        let ok = try await plane.prepare([image("p", seed: 1)], owner: "o", tokenBudget: 1250)
        XCTAssertEqual(ok.cost.inputTokens, 1250)
        XCTAssertEqual(ok.cost.basis, .estimatedAfterCounterFailure)
        do {
            _ = try await plane.prepare([image("q", seed: 2)], owner: "o", tokenBudget: 1249)
            XCTFail("expected refusal")
        } catch let error as AttachmentPlaneError {
            XCTAssertEqual(error, .refused(.overTokenBudget(tokens: 1250, budget: 1249, basis: .estimatedAfterCounterFailure)))
        }
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.counterFailures, 1)
    }

    func testNegativeBudgetRefusesEverything() async throws {
        let (plane, _, _) = makePlane()
        do {
            _ = try await plane.prepare([image("p", seed: 1)], owner: "o", tokenBudget: -10)
            XCTFail("expected refusal")
        } catch AttachmentPlaneError.refused(.overTokenBudget(_, let budget, _)) {
            XCTAssertEqual(budget, 0)
        }
    }

    // MARK: All-or-nothing batches

    func testFailedBatchRetainsNothingAndItsUploadsAreEventuallyCollected() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        await gated.reject(name: "bad.pdf")
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 60), retry: noJitter)
        do {
            _ = try await plane.prepare([image("good.jpg", seed: 1), pdf("bad.pdf", seed: 2)], owner: "chat")
            XCTFail("expected failure")
        } catch AttachmentPlaneError.uploadFailed(let name, _, _) {
            XCTAssertEqual(name, "bad.pdf")
        }
        await eventually("good upload finished") { await inner.uploadCalls == 1 }
        await eventually("good upload recorded") { await plane.entries().count == 1 }
        let entry = await plane.entries().first
        XCTAssertEqual(entry?.owners, [])
        XCTAssertNotNil(entry?.orphanedAt, "unretained upload must start its grace period")
        clock.advance(by: 61)
        let report = await plane.collectGarbage()
        XCTAssertEqual(report.deleted, 1)
        let live = await inner.liveFileIDs()
        XCTAssertEqual(live, [])
    }

    /// The other order: the failing upload throws first while the good one is
    /// still in flight, so the batch gives up before the good upload records.
    /// The late upload must still be collectable.
    func testUploadThatLandsAfterItsBatchFailedIsStillCollected() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        await gated.reject(name: "bad.pdf")
        await gated.holdUploadsAtGate()
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 60), retry: noJitter)
        let batch = Task { try await plane.prepare([pdf("bad.pdf", seed: 2), image("good.jpg", seed: 1)], owner: "chat") }
        await eventually("good upload held") { await gated.waitingUploads == 1 }
        do {
            _ = try await batch.value
            XCTFail("expected failure")
        } catch AttachmentPlaneError.uploadFailed(let name, _, _) {
            XCTAssertEqual(name, "bad.pdf")
        }
        await gated.openUploadGate()
        await eventually("late upload recorded") { await plane.entries().count == 1 }
        let entry = await plane.entries().first
        XCTAssertEqual(entry?.owners, [])
        XCTAssertNotNil(entry?.orphanedAt)
        clock.advance(by: 61)
        let report = await plane.collectGarbage()
        XCTAssertEqual(report.deleted, 1)
        let live = await inner.liveFileIDs()
        XCTAssertEqual(live, [])
    }

    func testCancellingOneCallerDoesNotCancelTheSharedUpload() async throws {
        let clock = ManualClock()
        let gated = GatedFileService(inner: SimulatedFileService(clock: clock, ttl: nil))
        await gated.holdUploadsAtGate()
        let plane = AttachmentPlane(fileService: gated, clock: clock, retry: noJitter)
        let source = image("x", seed: 3)
        let digest = ContentDigest.sha256(source.bytes)
        let cancelled = Task { try await plane.prepare([source], owner: "a") }
        let survivor = Task { try await plane.prepare([source], owner: "b") }
        await eventually("both pinned") { await plane.pinCount(digest) == 2 }
        cancelled.cancel()
        await gated.openUploadGate()
        let refs = try await survivor.value.references
        XCTAssertEqual(refs.count, 1)
        // v1: a cancelled caller is not interrupted; it still gets its references.
        let cancelledRefs = try await cancelled.value.references
        XCTAssertEqual(cancelledRefs.map(\.fileID), refs.map(\.fileID))
        let uploads = await gated.inner.uploadCalls
        XCTAssertEqual(uploads, 1)
    }

    // MARK: 5. Self-healing sends

    func testSendHealsAFileTheProviderLost() async throws {
        let log = EventLog()
        let (plane, service, _) = makePlane(log: log)
        let photo = image("p", seed: 6)
        let original = try await plane.prepare([photo], owner: "chat")
        guard let lostID = original.references.first?.fileID else { return XCTFail("no reference") }
        await service.forget(fileID: lostID)

        let usedIDs = try await plane.send([photo], owner: "chat") { refs in
            try await service.validate(refs.map(\.fileID))
            return refs.map(\.fileID)
        }
        XCTAssertEqual(usedIDs.count, 1)
        XCTAssertNotEqual(usedIDs.first, lostID)
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 2)
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.heals, 1)
        XCTAssertTrue(log.all.contains(.invalidated(fileID: lostID)))
        let owners = await plane.entries().first?.owners
        XCTAssertEqual(owners, ["chat"], "healing keeps the owner")
    }

    func testSecondMissPropagatesInsteadOfLooping() async throws {
        let (plane, service, _) = makePlane()
        var thrown: MissingRemoteFiles?
        do {
            _ = try await plane.send([image("p", seed: 7)], owner: "chat") { refs -> Int in
                throw MissingRemoteFiles(fileIDs: refs.map(\.fileID))
            }
        } catch let missing as MissingRemoteFiles {
            thrown = missing
        }
        XCTAssertNotNil(thrown)
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 2, "exactly one heal attempt")
        let heals = await plane.currentMetrics().heals
        XCTAssertEqual(heals, 0, "a heal that did not work is not counted")
    }

    func testInvalidationIsCompareAndSwap() {
        var registry = FileRegistry()
        let digest = ContentDigest.sha256([1])
        let now = Date(timeIntervalSince1970: 0)
        registry.record(digest, remote: RemoteFile(id: "old", expiresAt: nil), mediaType: .png, byteCount: 1, now: now)
        registry.record(digest, remote: RemoteFile(id: "new", expiresAt: nil), mediaType: .png, byteCount: 1, now: now)
        XCTAssertFalse(registry.invalidate(fileID: "old"), "a stale id must not clobber the newer mapping")
        XCTAssertEqual(registry.entry(digest)?.remote?.id, "new")
        XCTAssertTrue(registry.invalidate(fileID: "new"))
        XCTAssertNil(registry.usable(digest, now: now, margin: 0))
    }

    // MARK: 6. Garbage collection

    func testReleasedContentIsCollectedOnlyAfterGraceAndOnlyWhenUnowned() async throws {
        let (plane, service, clock) = makePlane(ttl: nil, limits: AttachmentLimits(orphanGracePeriod: 3600))
        _ = try await plane.prepare([image("shared", seed: 1)], owner: "chat-A")
        _ = try await plane.prepare([image("shared", seed: 1)], owner: "chat-B")
        _ = try await plane.prepare([pdf("solo", seed: 2)], owner: "chat-A")
        await plane.release(owner: "chat-A")
        clock.advance(by: 3599)
        var report = await plane.collectGarbage()
        XCTAssertEqual(report.deleted, 0, "grace period not over")
        clock.advance(by: 1)
        report = await plane.collectGarbage()
        XCTAssertEqual(report.deleted, 1, "only the PDF; the photo is still owned by chat-B")
        let remaining = await plane.entries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.owners, ["chat-B"])
        let live = await service.liveFileIDs()
        XCTAssertEqual(live.count, 1)
    }

    /// The reentrancy case: while GC awaits a delete, another conversation
    /// attaches the same bytes. It must get a fresh upload, never the id that
    /// is being deleted.
    func testPrepareDuringGarbageCollectionNeverReusesTheFileBeingDeleted() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter)
        let photo = image("p", seed: 8)
        let doomed = try await plane.prepare([photo], owner: "old-chat").references.first?.fileID
        await plane.release(owner: "old-chat")
        await gated.holdDeletesAtGate()
        let gc = Task { await plane.collectGarbage() }
        await eventually("delete held at gate") { await gated.waitingDeletes == 1 }

        let fresh = try await plane.prepare([photo], owner: "new-chat")
        XCTAssertEqual(fresh.references.first?.resolution, .uploaded)
        XCTAssertNotEqual(fresh.references.first?.fileID, doomed)

        await gated.openDeleteGate()
        let report = await gc.value
        XCTAssertEqual(report.deleted, 1)
        let entry = await plane.entries().first
        XCTAssertEqual(entry?.remote?.id, fresh.references.first?.fileID)
        XCTAssertEqual(entry?.owners, ["new-chat"])
        let live = await inner.liveFileIDs()
        XCTAssertEqual(live, fresh.references.map(\.fileID))
    }

    /// A `prepare` that decided to reuse an orphaned file pins it, so a GC pass
    /// that runs while the same `prepare` awaits another upload cannot delete it.
    func testGarbageCollectionSkipsFilesAPrepareHasPinned() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter)
        let photo = image("photo", seed: 1)
        let photoID = try await plane.prepare([photo], owner: "old").references.first?.fileID
        await plane.release(owner: "old")
        await gated.holdUploadsAtGate()
        let newPDF = pdf("new.pdf", seed: 2)
        let pending = Task { try await plane.prepare([photo, newPDF], owner: "new") }
        await eventually("pdf upload held") { await gated.waitingUploads == 1 }
        let report = await plane.collectGarbage()
        XCTAssertEqual(report.deleted, 0, "the photo is pinned by the in-progress prepare")
        await gated.openUploadGate()
        let refs = try await pending.value.references
        XCTAssertEqual(refs.first?.fileID, photoID)
        XCTAssertEqual(refs.first?.resolution, .reused)
        let live = await inner.liveFileIDs()
        XCTAssertTrue(live.contains(photoID ?? "-"))
        let owners = await plane.entries().first { $0.remote?.id == photoID }?.owners
        XCTAssertEqual(owners, ["new"])
    }

    func testFailedDeleteNeverOverwritesANewerMappingAndQueuesTheOldFile() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter)
        let photo = image("p", seed: 8)
        let old = try await plane.prepare([photo], owner: "a").references.first?.fileID
        await plane.release(owner: "a")
        await gated.holdDeletesAtGate()
        await gated.failNextDeletesTransiently(1)
        let gc = Task { await plane.collectGarbage() }
        await eventually("delete held") { await gated.waitingDeletes == 1 }
        let fresh = try await plane.prepare([photo], owner: "b").references.first?.fileID
        await gated.openDeleteGate()
        let report = await gc.value
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.deleted, 1, "the old file was queued and the same pass drained the queue")
        let entry = await plane.entries().first
        XCTAssertEqual(entry?.remote?.id, fresh)
        XCTAssertEqual(entry?.owners, ["b"])
        let pending = await plane.pendingDeletionCount()
        XCTAssertEqual(pending, 0)
        let live = await inner.liveFileIDs()
        XCTAssertFalse(live.contains(old ?? "-"))
        XCTAssertTrue(live.contains(fresh ?? "-"))
    }

    /// Delete fails while an upload of the same bytes is still in flight. The
    /// slot is empty, so a naive restore succeeds and the upload then
    /// overwrites it, losing the old file. It must be queued instead.
    func testFailedDeleteDuringAnInFlightReuploadQueuesTheOldFile() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter)
        let photo = image("p", seed: 8)
        let old = try await plane.prepare([photo], owner: "a").references.first?.fileID ?? "-"
        await plane.release(owner: "a")
        await gated.holdDeletesAtGate()
        await gated.failNextDeletesTransiently(1)
        await gated.holdUploadsAtGate()
        let gc = Task { await plane.collectGarbage() }
        await eventually("delete held") { await gated.waitingDeletes == 1 }
        let reupload = Task { try await plane.prepare([photo], owner: "b") }
        await eventually("re-upload held") { await gated.waitingUploads == 1 }
        await gated.openDeleteGate()
        let report = await gc.value
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.deleted, 1, "queued and drained in the same pass")
        await gated.openUploadGate()
        let fresh = try await reupload.value.references.first?.fileID ?? "-"
        let live = await inner.liveFileIDs()
        XCTAssertEqual(live, [fresh])
        XCTAssertFalse(live.contains(old))
    }

    /// Eviction must skip digests an in-progress prepare has pinned, or it
    /// queues a file for deletion that the prepare is about to hand out.
    func testEvictionSkipsEntriesPinnedByAnInProgressPrepare() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(maxRegistryEntries: 1), retry: noJitter)
        let owned = image("owned", seed: 1)
        let orphan = image("orphan", seed: 2)
        _ = try await plane.prepare([owned], owner: "v")
        let orphanID = try await plane.prepare([orphan], owner: "x").references.first?.fileID
        await plane.release(owner: "x")
        await gated.holdUploadsAtGate()
        let pending = Task { try await plane.prepare([orphan, pdf("new.pdf", seed: 3)], owner: "y") }
        await eventually("new upload held") { await gated.waitingUploads == 1 }
        // Runs to completion (pure reuse) and triggers eviction while `orphan` is pinned.
        _ = try await plane.prepare([owned], owner: "v2")
        let queued = await plane.pendingDeletionCount()
        XCTAssertEqual(queued, 0, "the pinned orphan must not be evicted")
        await gated.openUploadGate()
        let refs = try await pending.value.references
        XCTAssertEqual(refs.first?.fileID, orphanID)
        _ = await plane.collectGarbage()
        let live = await inner.liveFileIDs()
        XCTAssertTrue(live.contains(orphanID ?? "-"))
    }

    func testDeletionsOwedAtCrashTimeSurviveRelaunch() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let store = InMemoryRegistryStore()
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter, store: store)
        let id = try await plane.prepare([image("p", seed: 1)], owner: "a").references.first?.fileID ?? "-"
        await plane.release(owner: "a")
        await gated.holdDeletesAtGate()
        let gc = Task { await plane.collectGarbage() }
        await eventually("delete held") { await gated.waitingDeletes == 1 }
        // "Crash": a new plane is built from what was persisted while the delete was in flight.
        let relaunched = AttachmentPlane(fileService: inner, clock: clock, retry: noJitter, store: InMemoryRegistryStore(initial: try store.load()))
        let owed = await relaunched.pendingDeletionCount()
        XCTAssertEqual(owed, 1)
        await gated.openDeleteGate()
        _ = await gc.value
        let report = await relaunched.collectGarbage()
        XCTAssertEqual(report.alreadyGone + report.deleted, 1)
        let live = await inner.liveFileIDs()
        XCTAssertFalse(live.contains(id))
    }

    func testFailedDeleteWithoutContentionIsRetriedNextPass() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter)
        _ = try await plane.prepare([image("p", seed: 2)], owner: "a")
        await plane.release(owner: "a")
        await gated.failNextDeletesTransiently(1)
        let first = await plane.collectGarbage()
        XCTAssertEqual(first.failed, 1)
        let restored = await plane.entries().count
        XCTAssertEqual(restored, 1)
        let second = await plane.collectGarbage()
        XCTAssertEqual(second.deleted, 1)
        let after = await plane.entries().count
        XCTAssertEqual(after, 0)
    }

    func testProviderSideDeletionCountsAsAlreadyGone() async throws {
        let (plane, service, _) = makePlane(ttl: nil, limits: AttachmentLimits(orphanGracePeriod: 0))
        let id = try await plane.prepare([image("p", seed: 2)], owner: "a").references.first?.fileID ?? ""
        await plane.release(owner: "a")
        await service.forget(fileID: id)
        let report = await plane.collectGarbage()
        XCTAssertEqual(report, { var r = GarbageCollectionReport(); r.alreadyGone = 1; return r }())
        let entries = await plane.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: 7. Bounded state

    func testEvictionDropsOnlyUnownedEntriesLRUAndQueuesTheirFiles() async throws {
        let log = EventLog()
        let (plane, service, clock) = makePlane(ttl: nil, limits: AttachmentLimits(maxRegistryEntries: 2), log: log)
        _ = try await plane.prepare([image("old", seed: 1)], owner: "closed")
        await plane.release(owner: "closed")
        clock.advance(by: 1)
        _ = try await plane.prepare([image("b", seed: 2)], owner: "open")
        clock.advance(by: 1)
        _ = try await plane.prepare([image("c", seed: 3)], owner: "open")
        let entries = await plane.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.owners == ["open"] })
        let pending = await plane.pendingDeletionCount()
        XCTAssertEqual(pending, 1)
        _ = await plane.collectGarbage()
        let live = await service.liveFileIDs()
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(log.all.filter { if case .evicted = $0 { return true }; return false }.count, 1)
    }

    func testOwnedEntriesAreNeverEvictedEvenOverTheCap() async throws {
        let (plane, _, _) = makePlane(ttl: nil, limits: AttachmentLimits(maxRegistryEntries: 1))
        _ = try await plane.prepare([image("a", seed: 1), image("b", seed: 2), image("c", seed: 3)], owner: "open")
        // A later, unrelated prepare pushes the index further over the cap. The
        // earlier entries are no longer pinned, only owned, and must survive.
        _ = try await plane.prepare([image("d", seed: 4)], owner: "other")
        let count = await plane.entries().count
        XCTAssertEqual(count, 4)
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.evictions, 0)
    }

    func testEvictionIsLeastRecentlyUsedFirst() async throws {
        let log = EventLog()
        let (plane, _, clock) = makePlane(ttl: nil, limits: AttachmentLimits(maxRegistryEntries: 2), log: log)
        let older = image("older", seed: 1), newer = image("newer", seed: 2)
        _ = try await plane.prepare([older], owner: "o1")
        clock.advance(by: 10)
        _ = try await plane.prepare([newer], owner: "o2")
        await plane.release(owner: "o1")
        await plane.release(owner: "o2")
        clock.advance(by: 10)
        _ = try await plane.prepare([image("third", seed: 3)], owner: "o3") // 3 > 2: evict one
        let evicted = log.all.compactMap { event -> ContentDigest? in
            if case .evicted(let digest) = event { return digest }
            return nil
        }
        XCTAssertEqual(evicted, [ContentDigest.sha256(older.bytes)])
    }

    func testReuseRefreshesTheLRUPosition() async throws {
        let log = EventLog()
        let (plane, _, clock) = makePlane(ttl: nil, limits: AttachmentLimits(maxRegistryEntries: 2), log: log)
        let a = image("a", seed: 1), b = image("b", seed: 2)
        _ = try await plane.prepare([a], owner: "o1")
        clock.advance(by: 10)
        _ = try await plane.prepare([b], owner: "o2")
        await plane.release(owner: "o1")
        await plane.release(owner: "o2")
        clock.advance(by: 10)
        _ = try await plane.prepare([a], owner: "o3") // reuse: a is now the most recent
        await plane.release(owner: "o3")
        clock.advance(by: 10)
        _ = try await plane.prepare([image("c", seed: 3)], owner: "o4")
        let evicted = log.all.compactMap { event -> ContentDigest? in
            if case .evicted(let digest) = event { return digest }
            return nil
        }
        XCTAssertEqual(evicted, [ContentDigest.sha256(b.bytes)])
    }

    func testDeletionQueueIsBoundedAndCountsWhatItAbandons() async throws {
        let (plane, _, _) = makePlane(ttl: nil, limits: AttachmentLimits(maxRegistryEntries: 1, maxPendingDeletions: 1))
        for seed in UInt8(1)...4 {
            _ = try await plane.prepare([image("i\(seed)", seed: seed)], owner: "o\(seed)")
            await plane.release(owner: "o\(seed)")
        }
        let pending = await plane.pendingDeletionCount()
        XCTAssertEqual(pending, 1)
        let metrics = await plane.currentMetrics()
        XCTAssertEqual(metrics.evictions, 3)
        XCTAssertEqual(metrics.abandonedRemoteFiles, 2)
    }

    // MARK: Persistence

    func testRegistrySurvivesRelaunch() async throws {
        let clock = ManualClock()
        let service = SimulatedFileService(clock: clock, ttl: 3600)
        let store = InMemoryRegistryStore()
        let first = AttachmentPlane(fileService: service, clock: clock, retry: noJitter, store: store)
        _ = try await first.prepare([image("p", seed: 1)], owner: "chat")
        let relaunched = AttachmentPlane(fileService: service, clock: clock, retry: noJitter, store: store)
        let again = try await relaunched.prepare([image("p", seed: 1)], owner: "chat")
        XCTAssertEqual(again.references.first?.resolution, .reused)
        let uploads = await service.uploadCalls
        XCTAssertEqual(uploads, 1)
    }

    /// A queued deletion is being drained when a concurrent prepare persists,
    /// then the app dies. The owed delete must be in that snapshot.
    func testDrainPhaseDeletionsSurviveACrash() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let store = InMemoryRegistryStore()
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(maxRegistryEntries: 1), retry: noJitter, store: store)
        _ = try await plane.prepare([image("a", seed: 1)], owner: "x")
        await plane.release(owner: "x")
        _ = try await plane.prepare([image("b", seed: 2)], owner: "y") // evicts a: queued
        let queued = await plane.pendingDeletionCount()
        XCTAssertEqual(queued, 1)
        await gated.holdDeletesAtGate()
        let gc = Task { await plane.collectGarbage() }
        await eventually("drain delete held") { await gated.waitingDeletes == 1 }
        _ = try await plane.prepare([image("b", seed: 2)], owner: "z") // persists mid-drain
        let relaunched = AttachmentPlane(fileService: inner, clock: clock, retry: noJitter,
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let owed = await relaunched.pendingDeletionCount()
        XCTAssertEqual(owed, 1)
        await gated.openDeleteGate()
        _ = await gc.value
        // Once the pass confirms the delete, nothing is owed any more.
        let afterwards = AttachmentPlane(fileService: inner, clock: clock, retry: noJitter,
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let stillOwed = await afterwards.pendingDeletionCount()
        XCTAssertEqual(stillOwed, 0)
    }

    /// Two overlapping GC passes must not erase each other's in-progress deletes.
    func testOverlappingGCPassesKeepInProgressDeletesPersisted() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        let store = InMemoryRegistryStore()
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(orphanGracePeriod: 0), retry: noJitter, store: store)
        _ = try await plane.prepare([image("a", seed: 1)], owner: "x")
        await plane.release(owner: "x")
        await gated.holdDeletesAtGate()
        let first = Task { await plane.collectGarbage() }
        await eventually("held") { await gated.waitingDeletes == 1 }
        _ = await plane.collectGarbage() // nothing due; persists
        let relaunched = AttachmentPlane(fileService: inner, clock: clock, retry: noJitter,
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let owed = await relaunched.pendingDeletionCount()
        XCTAssertEqual(owed, 1)
        await gated.openDeleteGate()
        _ = await first.value
        let afterwards = AttachmentPlane(fileService: inner, clock: clock, retry: noJitter,
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let stillOwed = await afterwards.pendingDeletionCount()
        XCTAssertEqual(stillOwed, 0)
    }

    func testFailedQueuedDeleteStaysQueued() async throws {
        let clock = ManualClock()
        let gated = GatedFileService(inner: SimulatedFileService(clock: clock, ttl: nil))
        let plane = AttachmentPlane(fileService: gated, clock: clock,
                                    limits: AttachmentLimits(maxRegistryEntries: 1), retry: noJitter)
        _ = try await plane.prepare([image("a", seed: 1)], owner: "x")
        await plane.release(owner: "x")
        _ = try await plane.prepare([image("b", seed: 2)], owner: "y") // evicts a: queued
        await gated.failNextDeletesTransiently(1)
        let report = await plane.collectGarbage()
        XCTAssertEqual(report.failed, 1)
        let pending = await plane.pendingDeletionCount()
        XCTAssertEqual(pending, 1, "a failed queued delete is re-queued, not dropped")
        let retry = await plane.collectGarbage()
        XCTAssertEqual(retry.deleted, 1)
    }

    /// One upload of a batch has landed, the other is still in flight, and the
    /// app dies. The landed file must come back orphaned and be collected.
    func testUploadThatLandedBeforeACrashIsCollectedAfterRelaunch() async throws {
        let clock = ManualClock()
        let inner = SimulatedFileService(clock: clock, ttl: nil)
        let gated = GatedFileService(inner: inner)
        await gated.holdUpload(named: "slow.pdf")
        let store = InMemoryRegistryStore()
        let plane = AttachmentPlane(fileService: gated, clock: clock, retry: noJitter, store: store)
        let batch = Task { try await plane.prepare([image("fast.jpg", seed: 1), pdf("slow.pdf", seed: 2)], owner: "chat") }
        await eventually("fast upload recorded") { await plane.entries().count == 1 }
        // Crash now: relaunch from whatever was persisted.
        let relaunched = AttachmentPlane(fileService: inner, clock: clock,
                                         limits: AttachmentLimits(orphanGracePeriod: 60), retry: noJitter,
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let entry = await relaunched.entries().first
        XCTAssertEqual(entry?.owners, [])
        XCTAssertNotNil(entry?.orphanedAt)
        clock.advance(by: 61)
        let report = await relaunched.collectGarbage()
        XCTAssertEqual(report.deleted, 1)
        await gated.openUploadGate()
        _ = try await batch.value
    }

    func testReleaseIsDurable() async throws {
        let clock = ManualClock()
        let store = InMemoryRegistryStore()
        let service = SimulatedFileService(clock: clock, ttl: nil)
        let plane = AttachmentPlane(fileService: service, clock: clock, retry: noJitter, store: store)
        _ = try await plane.prepare([image("p", seed: 1)], owner: "chat")
        await plane.release(owner: "chat")
        let relaunched = AttachmentPlane(fileService: service, clock: clock, retry: noJitter,
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let entry = await relaunched.entries().first
        XCTAssertEqual(entry?.owners, [])
        XCTAssertNotNil(entry?.orphanedAt)
    }

    func testRestoredQueueIsCappedAndTheOverflowCounted() async throws {
        let clock = ManualClock()
        let store = InMemoryRegistryStore()
        let plane = AttachmentPlane(fileService: SimulatedFileService(clock: clock, ttl: nil), clock: clock,
                                    limits: AttachmentLimits(maxRegistryEntries: 1, maxPendingDeletions: 10),
                                    retry: noJitter, store: store)
        for seed in UInt8(1)...4 {
            _ = try await plane.prepare([image("i\(seed)", seed: seed)], owner: "o\(seed)")
            await plane.release(owner: "o\(seed)")
        }
        let queued = await plane.pendingDeletionCount()
        XCTAssertEqual(queued, 3)
        let relaunched = AttachmentPlane(fileService: SimulatedFileService(clock: clock), clock: clock,
                                         limits: AttachmentLimits(maxPendingDeletions: 1),
                                         store: InMemoryRegistryStore(initial: try store.load()))
        let kept = await relaunched.pendingDeletionCount()
        XCTAssertEqual(kept, 1)
        let abandoned = await relaunched.currentMetrics().abandonedRemoteFiles
        XCTAssertEqual(abandoned, 2)
    }

    func testCorruptOrFutureSnapshotsStartEmptyInsteadOfCrashing() async throws {
        for data in [Data("not json".utf8), Data("{\"version\":99,\"entries\":[]}".utf8)] {
            let log = EventLog()
            let plane = AttachmentPlane(fileService: SimulatedFileService(clock: ManualClock()), clock: ManualClock(),
                                        store: InMemoryRegistryStore(initial: data), observer: { log.append($0) })
            let entries = await plane.entries()
            XCTAssertTrue(entries.isEmpty)
            XCTAssertEqual(log.all, [.snapshotDiscarded])
        }
    }

    func testPersistFailureIsCountedNotFatal() async throws {
        let (plane, _, _) = makePlane(store: ThrowingStore())
        _ = try await plane.prepare([image("p", seed: 1)], owner: "chat")
        let metrics = await plane.currentMetrics()
        XCTAssertGreaterThan(metrics.persistFailures, 0)
    }
}
