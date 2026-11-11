# AttachmentPlaneKit

**Upload once, reference everywhere, and never hand the model a dead file id.** A content-addressed attachment plane for the multimodal AI features in an iOS app: the layer between "the user picked a photo" and "the request to Claude carries a `file_id`".

Demo app: [**ai-attachment-plane-demo-app**](https://github.com/rajatslakhina/ai-attachment-plane-demo-app), a separate Xcode project that consumes this package as a remote dependency pinned from `1.0.0`.

---

## The problem

Every iOS app that adds "attach a file and ask the AI" ships the same naive pipeline: read the bytes, base64 them into the request, send. It works in the demo and fails at scale in five ways a lead ends up owning:

1. **The same bytes are uploaded again and again.** A user shares one 4 MB screenshot into three chats, retries a failed send, or reopens a draft. Each one is a full upload on a cellular link: bandwidth, battery and seconds of latency before the model sees anything.
2. **Concurrent callers race.** Five views prepare the same PDF at once (a share sheet plus a background prefetch plus a retry). Five uploads, five file ids, and four of them are never deleted.
3. **Remote file ids expire or disappear.** Provider file stores (for Claude, the Files API) have lifetimes, quotas and operator purges. A cached `file_id` that dies between "prepare" and "send" becomes a confusing 404 in the middle of a conversation.
4. **Cost is discovered after the money is spent.** A 40-page PDF is uploaded in full before anyone learns the request is over the token budget.
5. **Nobody deletes anything.** Without ownership, every uploaded file leaks until it expires (if it was given an expiry at all), and the storage quota fills with orphans.

> **What dedup does not save.** Referencing a `file_id` does not make input tokens free: the model still reads the file on every request that references it. This plane saves upload bandwidth, latency, battery and storage quota, and it refuses over-budget requests before spending anything. Prompt caching is the separate lever for repeated input-token cost.

Moving to the Files API (upload once, reference by `file_id`) is the right fix. It also turns a stateless pipeline into a **distributed cache with a remote, expiring, lossy backing store**. That needs system design, not a helper function.

## Why this matters for a lead

This is a build-vs-buy and platform decision. It affects every team that ships an AI feature with attachments, so it has to live in one shared layer, not be re-solved per screen. Getting it wrong costs bandwidth and latency (duplicate uploads), reliability (404s mid-conversation), quota (leaked files) and money (over-budget requests that are only refused after the upload). Those costs are invisible in code review and only show up on the invoice or in support tickets.

## System design

```
            nonisolated (off-actor)                 AttachmentPlane actor (one per app)
 sources ──► Admission ──► SHA-256 ──────────────► decide (no suspension) ──► pin ──► await ──► retain(owner)
             size / count  content                  │ reuse   (index hit, outlives margin)       │
             token budget  identity                 │ join    (upload already in flight)         ▼
             (exact count,                          │ dup     (same bytes twice in this batch)   FileRegistry
              padded heuristic                      └ upload  (single-flight Task + retry)       digest → file, owners
              on failure)                                                                         │
                                                    send(): operation throws MissingRemoteFiles ──┤ compare-and-invalidate,
                                                                                                  │ re-prepare, retry once
                                                    release(owner) ─► orphanedAt ─► collectGarbage() ─► delete
```

### The eight guarantees

Each guarantee has tests. The load-bearing ones also have a mutation in [`scripts/mutation-check.sh`](scripts/mutation-check.sh) that breaks the code on purpose and requires the suite to fail.

| # | Guarantee | How | Mutation that must fail the suite |
|---|-----------|-----|-----------------------------------|
| 1 | **Upload once per content**, across conversations and within one batch | Identity is the SHA-256 of the bytes, not the file name. Duplicates in one batch ride the first upload | in-batch dedup disabled |
| 2 | **Single flight**: concurrent callers share one upload, including its retries | `inFlight[digest]` holds the one `Task`. Joiners await it. The task records its own result, so a joiner that throws early never loses it | joiners ignore the in-flight task |
| 3 | **No near-dead references** | Reuse only if `expiresAt − now > reuseSafetyMargin`, otherwise upload fresh. The about-to-expire file is not deleted, because a request inside the margin may still use it | margin set to 0 |
| 4 | **Refuse before spending** | Size, count and empty-file checks, then a token budget using the exact count (`count_tokens`) or, if that fails, a heuristic × 1.25. All of this runs before any upload | structural check skipped; budget skipped |
| 5 | **Self-healing send** | When the operation throws `MissingRemoteFiles`, the plane invalidates exactly those ids (compare-and-swap, so a newer mapping is never clobbered), prepares again and retries once. A second miss propagates: looping would hide an outage. `heals` counts only retries that succeeded | invalidation skipped; heals not counted |
| 6 | **GC never races reuse** | Due entries leave the index *before* the delete is awaited. Digests pinned by an in-progress `prepare` are skipped. A failed delete that lost its slot to a newer upload queues the old file instead of overwriting the mapping | entries removed after the await; pins ignored; old file not queued |
| 7 | **Bounded state** | Unowned, unpinned index entries are LRU-evicted past `maxRegistryEntries` and their files queued for deletion. The deletion queue is capped, and anything it drops is counted (`abandonedRemoteFiles`). Owned entries are never evicted | eviction ignores ownership; eviction ignores pins; eviction not LRU; reuse does not refresh LRU; restored queue truncated silently |
| 8 | **No leak across a crash, once the snapshot is written** | Every new upload is recorded orphaned and persisted before any caller retains it, so an upload that lands after its batch failed, or just before a crash, is still collectable. The deletion queue, including files a GC pass or queue drain was deleting when the app died, is persisted with the index. The one remaining window (the provider has stored the file but the app dies before the snapshot write) is what an upload-time expiry is for, see below | new uploads start without an orphan timestamp; upload not persisted; release not persisted; in-progress deletes (GC pass or queue drain) not persisted; confirmed deletes never cleared; failed queued delete dropped |

Plus: **all-or-nothing batches.** If one attachment in a request fails, nothing is retained, and every upload of that batch, finished or still in flight, is recorded already orphaned, so GC reclaims it once the batch's pins drop (mutation: fresh uploads start without an orphan timestamp; tested in both failure orders).

**A note on provider expiry.** Anthropic's Files API keeps a file until it is deleted or until its `expires_at`, which is only set when the upload passes an optional expiry (`expires_in_seconds`, per the current Files API docs). Two consequences for the design:

- A `FileService` adapter for Claude **should set an expiry** (for example 30 days) as a backstop. It bounds the damage from anything GC never reaches: a crash before the snapshot is written, `abandonedRemoteFiles`, an uninstall. The plane already handles expiring files: `RemoteFile.expiresAt` feeds the reuse safety margin, so an id is never handed out minutes before it dies.
- Without an expiry, GC is the only reclaim path, and `abandonedRemoteFiles` counts files that will sit against the organization's storage quota until someone deletes them. It is worth alerting on.

## Software architecture

| Layer | Type | Why it is shaped this way |
|-------|------|---------------------------|
| Identity | `ContentDigest` (pure-Swift SHA-256) | No CryptoKit and no dependency, so the core builds and is tested on Linux. Checked against the FIPS 180-2 vectors and the padding boundaries (55/56/63/64/65/119/120 bytes) |
| Policy (pure) | `AttachmentLimits`, `RetryPolicy`, `HeuristicTokenEstimator`, `Admission` | Value types with clamping inits. A bad remote config cannot produce a negative budget, a zero-attempt retry loop or a divide-by-zero |
| Index (pure) | `FileRegistry` | A value type with no I/O and no concurrency, so every rule is unit-testable directly. Versioned JSON snapshot; a corrupt or future snapshot starts empty (costs bandwidth, never correctness) |
| Coordination | `AttachmentPlane` actor | The only place with shared mutable state. Hashing is `nonisolated`, so a large PDF never blocks other conversations' lookups. Decisions are made in one synchronous pass, then digests are pinned before the first `await` |
| Ports | `FileService`, `TokenCounting`, `PlaneClock`, `RegistryStore` | The provider, the token counter, time and persistence are injected. `ManualClock.sleep` advances time instead of waiting, so backoff schedules are asserted exactly |
| Adapter | `SimulatedFileService` | A second implementation of the `FileService` contract, with TTLs and scripted faults (transient, permanent, purge). The demo and the tests run against it |
| UI | `AttachmentPlaneUI` (`AttachmentConsoleView`) | A console that drives the real actor through seven scenarios. It compiles to nothing where SwiftUI is unavailable |

### Trade-offs and rejected alternatives

- **Inline base64 everywhere (rejected).** It is simple and has no state, but it re-sends the bytes on every request (bandwidth, latency, battery), and large attachments run into the request size limit.
- **Cache keyed by file URL or `PHAsset` id (rejected).** The same bytes arrive through different URLs (share sheet, Files, Photos edits), and an edited asset keeps its id. Only a content hash is an honest identity.
- **One upload per caller, deduplicated afterwards (rejected).** The bandwidth is already spent, and the extra remote files must be deleted by something that knows they are extras.
- **Retrying everything (rejected).** Retrying a 413 or 415 burns battery and quota to get the same answer. Only `.transient` is retried, with full-jitter exponential backoff (`maxAttempts` 4, cap 8 s).
- **Deleting the about-to-expire file on re-upload (rejected).** A request sent a moment earlier, inside the safety margin, may still reference it. Provider expiry reclaims it safely.
- **Evicting owned entries to enforce a hard cap (rejected).** That orphans a live remote file with nobody left to delete it. The bound is on unowned entries. Owned entries are bounded by the app's live conversations, which the app controls.
- **An unbounded deletion queue (rejected).** If GC never runs, memory and the persisted snapshot grow forever. Instead the queue is capped and the overflow counted (`abandonedRemoteFiles`), which turns a silent quota leak into a metric.
- **Cancelling the shared upload when a caller is cancelled (rejected).** Other callers are waiting on the same task. Single flight means the upload belongs to the content, not to the first caller (tested). In v1 a cancelled caller is not interrupted either: it waits for the shared upload and receives its references.

### What it deliberately does not do

- **Transport.** Background `URLSession`, resumable chunks and congestion control sit below the `FileService` port, in whatever transport the app already has.
- **Release during an in-flight prepare for the same owner.** If `release(owner:)` lands while that owner's `prepare` is still awaiting an upload, the `prepare` re-retains when it finishes. Release again (or on next launch) to reclaim. A release generation counter would close this; it is documented rather than built.
- **Avoiding a second token count on heal.** `send` re-runs admission (including `count_tokens`, when configured) before its one retry.
- **Real Files API or `count_tokens` adapters.** Writing them takes a few lines against the ports (`POST /v1/files`, `DELETE /v1/files/{id}`, `POST /v1/messages/count_tokens`). They are left out so the repo needs no API key to build, test or demo.
- **Exact token estimates.** `HeuristicTokenEstimator` is a deliberately conservative upper bound for admission: images use the `w × h / 750` approximation after capping the long edge at 1568 px (the provider may downscale further, so real counts can be lower), plus flat PDF-page and text rates. The exact count from `count_tokens`, when configured, always wins.

## Usage

```swift
.package(url: "https://github.com/rajatslakhina/ai-attachment-plane-kit.git", from: "1.0.0")
```

```swift
import AttachmentPlane

let plane = AttachmentPlane(fileService: MyFilesAPIClient(),     // conforms to FileService
                            tokenCounter: MyCountTokensClient(),  // optional, conforms to TokenCounting
                            store: MyKeychainOrFileStore())       // optional, conforms to RegistryStore

let reply = try await plane.send(attachments, owner: conversation.id, tokenBudget: 60_000) { refs in
    // Build image/document content blocks with {"type": "file", "file_id": ref.fileID}.
    // If the API answers 404 for a file_id, throw MissingRemoteFiles(fileIDs: [...]).
    try await claude.messages(contentBlocks(for: refs) + [.text(prompt)])
}

// When the conversation is deleted:
await plane.release(owner: conversation.id)
// Periodically (e.g. BGAppRefreshTask):
await plane.collectGarbage()
```

## Running the tests

```bash
swift test                    # 56 XCTest cases (Linux or macOS)
scripts/mutation-check.sh     # breaks each guarantee on purpose; every mutant must fail the suite
```

## Verification

What has actually been run, stated exactly:

- **Linux, Swift 6.0.3 (Ubuntu 24.04):** clean `swift build --build-tests -Xswiftc -warnings-as-errors`, then `swift test`: 56/56 XCTest cases pass. `scripts/mutation-check.sh`: 26/26 mutants caught (each one compiles and makes the suite fail).
- **macOS, Xcode 27.2 / Swift 6.4.2:** clean `swift build --build-tests -Xswiftc -warnings-as-errors` (this compiles `AttachmentPlaneUI` against the macOS SDK) and `swift test`: 56/56. `xcodebuild build -scheme AttachmentPlaneKit-Package -destination 'generic/platform=iOS Simulator' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` succeeded for both products.
- **iOS Simulator run of the demo app: done on 2026-11-11.** The demo was built with `xcodebuild` (Xcode 27.2, Debug) from a scratch copy whose package reference was switched to this repo's local path, because the kit is not on GitHub yet. That build was the first iOS compile of `AttachmentPlaneUI` and its log had no errors or warnings. The app was installed on a dedicated iPhone 18 Pro simulator (iOS 27.2) and launched four times with `-scenarios` launch arguments; the process was running after each launch and no crash report was written. The four screenshots are committed in the demo repo, and the counters on them match the demo README's table. A run against the GitHub-resolved package has not happened yet.
- **CI:** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) defines a Linux job (`swift:6.0` container: build with warnings as errors, tests, mutation check) and a `macos-15` job (build, tests, iOS Simulator build of both products). See the repository's Actions tab for its runs.
- **Independent review:** three rounds by a separate reviewer model with no memory of writing the code. Rounds 1 and 2 found two remote-file leaks, a crash-persistence gap under actor reentrancy, a bypassable config clamp and README overclaims; all were fixed and each has a test and a mutation. Round 3 found two untested load-bearing lines (now tested and mutated). Round 3's fixes were not re-reviewed.

## License

MIT
