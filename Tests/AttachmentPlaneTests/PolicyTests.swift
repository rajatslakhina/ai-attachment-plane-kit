import Foundation
import XCTest
@testable import AttachmentPlane

final class PolicyTests: XCTestCase {
    func testSaturatingArithmeticNeverTraps() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.min, 2), Int.min)
        XCTAssertEqual(Saturating.multiply(-3, 4), -12)
        XCTAssertEqual(Saturating.int(.nan), 0)
        XCTAssertEqual(Saturating.int(.infinity), Int.max)
        XCTAssertEqual(Saturating.int(-.infinity), Int.min)
        XCTAssertEqual(Saturating.int(Double(Int.max)), Int.max) // rounds to 2^63, which would trap
        XCTAssertEqual(Saturating.int(1e300), Int.max)
        XCTAssertEqual(Saturating.int(-1e300), Int.min)
        XCTAssertEqual(Saturating.int(41.9), 41)
    }

    func testLimitsAreClampedSoBadConfigCannotDisableAdmission() {
        let limits = AttachmentLimits(maxFileBytes: -5, maxAttachmentsPerRequest: 0, reuseSafetyMargin: .nan,
                                      orphanGracePeriod: -.infinity, maxRegistryEntries: -1,
                                      maxPendingDeletions: 0, estimateSafetyFactor: 0.2)
        XCTAssertEqual(limits.maxFileBytes, 1)
        XCTAssertEqual(limits.maxAttachmentsPerRequest, 1)
        XCTAssertEqual(limits.reuseSafetyMargin, 0)
        XCTAssertEqual(limits.orphanGracePeriod, 0)
        XCTAssertEqual(limits.maxRegistryEntries, 1)
        XCTAssertEqual(limits.maxPendingDeletions, 1)
        XCTAssertEqual(limits.estimateSafetyFactor, 1)
    }

    func testBackoffIsExponentialCappedAndSafeForHostileInputs() {
        XCTAssertEqual(noJitter.delay(beforeRetry: 1), 0.5)
        XCTAssertEqual(noJitter.delay(beforeRetry: 2), 1.0)
        XCTAssertEqual(noJitter.delay(beforeRetry: 3), 2.0)
        XCTAssertEqual(noJitter.delay(beforeRetry: 10), 8.0)       // capped
        XCTAssertEqual(noJitter.delay(beforeRetry: Int.max), 8.0)  // no overflow
        XCTAssertEqual(noJitter.delay(beforeRetry: Int.min), 0.5)  // no overflow
        let hostile = RetryPolicy(maxAttempts: 0, baseDelay: .infinity, maxDelay: -1, jitter: { _ in .nan })
        XCTAssertEqual(hostile.maxAttempts, 1)
        XCTAssertEqual(hostile.delay(beforeRetry: 1), 0)
        let tooBig = RetryPolicy(baseDelay: 1, maxDelay: 4, jitter: { $0 * 100 })
        XCTAssertEqual(tooBig.delay(beforeRetry: 2), 2) // jitter clamped to 0...raw
        let negative = RetryPolicy(baseDelay: 1, maxDelay: 4, jitter: { _ in -3 })
        XCTAssertEqual(negative.delay(beforeRetry: 2), 0)
    }

    func testImageEstimateScalesTheLongEdgeTo1568() {
        let estimator = HeuristicTokenEstimator()
        let small = AttachmentSource(name: "s", bytes: [1], mediaType: .png, pixelSize: PixelSize(width: 750, height: 100))
        XCTAssertEqual(estimator.estimate(small), 100)
        // 4032×3024 scales to 1568×1176: 1568*1176/750 = 2458.6 → 2459.
        let photo = AttachmentSource(name: "p", bytes: [1], mediaType: .jpeg, pixelSize: PixelSize(width: 4032, height: 3024))
        XCTAssertEqual(estimator.estimate(photo), 2459)
        let unknown = AttachmentSource(name: "u", bytes: [1], mediaType: .webp)
        XCTAssertEqual(estimator.estimate(unknown), 1600)
        let degenerate = AttachmentSource(name: "d", bytes: [1], mediaType: .gif, pixelSize: PixelSize(width: 0, height: -4))
        XCTAssertEqual(estimator.estimate(degenerate), 1600)
        let huge = AttachmentSource(name: "h", bytes: [1], mediaType: .png, pixelSize: PixelSize(width: Int.max, height: Int.max))
        XCTAssertEqual(estimator.estimate(huge), 3279) // 1568×1568/750, no trap
    }

    func testDocumentAndTextEstimates() {
        var estimator = HeuristicTokenEstimator()
        XCTAssertEqual(estimator.estimate(pdf("p", seed: 1, pages: 4)), 4 * 2300)
        // No page count: pages guessed from bytes, rounded up, at least 1.
        XCTAssertEqual(estimator.estimate(pdf("p", seed: 1, count: 60_001, pages: nil)), 2 * 2300)
        XCTAssertEqual(estimator.estimate(pdf("p", seed: 1, count: 10, pages: 0)), 2300)
        let text = AttachmentSource(name: "t", bytes: bytes(10), mediaType: .plainText)
        XCTAssertEqual(estimator.estimate(text), 4)
        estimator.bytesPerPDFPageGuess = 0 // mutated after init: must not divide by zero
        XCTAssertEqual(estimator.estimate(pdf("p", seed: 1, count: 3, pages: nil)), 3 * 2300)
        estimator.tokensPerPDFPage = Int.max
        XCTAssertEqual(estimator.estimate(pdf("p", seed: 1, pages: 2)), Int.max)
    }

    func testMediaKinds() {
        XCTAssertEqual(MediaType.allCases.filter { $0.kind == .image }.count, 4)
        XCTAssertEqual(MediaType.pdf.kind, .document)
        XCTAssertEqual(MediaType.plainText.kind, .text)
    }
}
