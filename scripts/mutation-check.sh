#!/usr/bin/env bash
# Mutation check: break each load-bearing guarantee on purpose and require the
# test suite to FAIL. A mutation that survives means a guarantee the README
# claims is not actually protected by a test.
#
# Usage: scripts/mutation-check.sh            (run from anywhere; needs swift + python3)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TIMEOUT=""
if command -v timeout >/dev/null; then TIMEOUT="timeout 300"; elif command -v gtimeout >/dev/null; then TIMEOUT="gtimeout 300"; fi

# file ~ exact original text ~ replacement ~ what it breaks   ('~' appears in no target)
MUTATIONS=(
  'Sources/AttachmentPlane/AttachmentPlane.swift~} else if let flight = inFlight[digest] {~} else if let flight = inFlight[digest], digest.hex.isEmpty {~single flight: concurrent callers each upload'
  'Sources/AttachmentPlane/AttachmentPlane.swift~if pending[digest] != nil {~if pending[digest] != nil, digest.hex.isEmpty {~duplicates inside one batch are not folded'
  'Sources/AttachmentPlane/FileRegistry.swift~expiry.timeIntervalSince(now) <= margin~expiry.timeIntervalSince(now) <= 0~files about to expire are reused'
  'Sources/AttachmentPlane/AttachmentPlane.swift~guard case .transient(let reason) = error, attempt < self.retry.maxAttempts else {~guard let reason = Optional(String(describing: error)), attempt < self.retry.maxAttempts else {~permanent upload errors are retried'
  'Sources/AttachmentPlane/AttachmentPlane.swift~if let refusal = admission.structuralCheck(sources) {~if let refusal = admission.structuralCheck(sources), sources.isEmpty {~oversized/too-many/empty attachments reach the network'
  'Sources/AttachmentPlane/AttachmentPlane.swift~if let budget = tokenBudget, cost.inputTokens > max(0, budget) {~if let budget = tokenBudget, cost.inputTokens < 0, budget < 0 {~token budget not enforced'
  'Sources/AttachmentPlane/AttachmentPlane.swift~            await invalidate(fileIDs: missing.fileIDs)~            _ = missing~send does not heal a lost file'
  'Sources/AttachmentPlane/AttachmentPlane.swift~excluding: protected, remove: true)~excluding: protected, remove: false)~GC races reuse: a file being deleted is handed out'
  'Sources/AttachmentPlane/AttachmentPlane.swift~excluding: protected, remove: true)~excluding: [], remove: true)~GC deletes a file an in-progress prepare decided to reuse'
  'Sources/AttachmentPlane/AttachmentPlane.swift~if inFlight[entry.digest] != nil || !registry.restore(entry) { enqueueDeletion(remote.id) }~_ = registry.restore(entry)~a failed delete that lost its slot leaks the old file'
  'Sources/AttachmentPlane/AttachmentPlane.swift~if inFlight[entry.digest] != nil || !registry.restore(entry) { enqueueDeletion(remote.id) }~if !registry.restore(entry) { enqueueDeletion(remote.id) }~a failed delete restored under an in-flight re-upload leaks the old file'
  'Sources/AttachmentPlane/FileRegistry.swift~.filter { $0.owners.isEmpty && !pinned.contains($0.digest) }~.filter { !pinned.contains($0.digest) }~eviction drops owned entries'
  'Sources/AttachmentPlane/AttachmentPlane.swift~excluding: protected) {~excluding: []) {~eviction ignores pins and queues a file a prepare is handing out'
  'Sources/AttachmentPlane/FileRegistry.swift~owners: [], orphanedAt: now)~owners: [], orphanedAt: nil)~an upload that lands after its batch failed is never collected'
  'Sources/AttachmentPlane/AttachmentPlane.swift~deleting.formUnion(due.compactMap { $0.remote?.id })~_ = due~a crash mid-GC leaks the files being deleted'
  'Sources/AttachmentPlane/AttachmentPlane.swift~deleting.formUnion(queued)~_ = queued~a crash while draining the queue leaks the files being deleted'
  'Sources/AttachmentPlane/FileRegistry.swift~.sorted { ($0.lastUsed, $0.digest) < ($1.lastUsed, $1.digest) }~.sorted { ($0.lastUsed, $0.digest) > ($1.lastUsed, $1.digest) }~eviction is not least-recently-used'
  'Sources/AttachmentPlane/AttachmentPlane.swift~metrics.abandonedRemoteFiles = owed.count - pendingDeletions.count~_ = owed~a truncated restored queue drops files silently'
  'Sources/AttachmentPlane/AttachmentPlane.swift~enqueueDeletion(fileID)~_ = fileID~a failed queued delete is dropped silently'
  'Sources/AttachmentPlane/AttachmentPlane.swift~persist() // finishUpload: a fresh upload is durable before any caller retains it~_ = 0~an upload that lands before a crash is lost'
  'Sources/AttachmentPlane/AttachmentPlane.swift~persist() // release: the orphan timestamp must survive a relaunch~_ = 0~a release is lost on relaunch'
  'Sources/AttachmentPlane/AttachmentPlane.swift~defer { deleting.remove(remote.id) }~_ = 0~confirmed GC deletes stay owed forever'
  'Sources/AttachmentPlane/AttachmentPlane.swift~defer { deleting.remove(fileID) }~_ = 0~confirmed queue deletes stay owed forever'
  'Sources/AttachmentPlane/AttachmentPlane.swift~registry.touch(digest, now: now)~_ = now~reuse does not refresh the LRU position'
  'Sources/AttachmentPlane/AttachmentPlane.swift~await noteHeal(missing.fileIDs) // counted only when the retry succeeded~_ = 0~heals are not counted'
  'Sources/AttachmentPlane/ContentDigest.swift~let s0 = rotr(w[t - 15], 7)~let s0 = rotr(w[t - 15], 8)~SHA-256 message schedule is wrong'
)

caught=0
survived=0
for entry in "${MUTATIONS[@]}"; do
  IFS='~' read -r file original replacement label <<<"$entry"
  rm -rf "$WORK/pkg"
  mkdir -p "$WORK/pkg"
  (cd "$ROOT" && tar --exclude .build --exclude .git -cf - .) | (cd "$WORK/pkg" && tar -xf -)
  python3 - "$WORK/pkg/$file" "$original" "$replacement" <<'PY'
import sys
path, original, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
count = text.count(original)
if count != 1:
    sys.exit(f"mutation target found {count} times in {path}: {original!r}")
open(path, "w").write(text.replace(original, replacement))
PY
  # A mutation must still compile; a "catch" by compile error proves nothing.
  if ! (cd "$WORK/pkg" && swift build --build-tests >"$WORK/log" 2>&1); then
    echo "INVALID   $label (mutant does not compile)"
    survived=$((survived + 1))
    continue
  fi
  # A hang (a gated task never released because the mutant broke an
  # interleaving) also counts as caught, via the timeout's non-zero exit.
  if (cd "$WORK/pkg" && $TIMEOUT swift test >"$WORK/log" 2>&1); then
    echo "SURVIVED  $label"
    survived=$((survived + 1))
  else
    echo "caught    $label"
    caught=$((caught + 1))
  fi
done

echo "mutations caught: $caught/${#MUTATIONS[@]}"
[ "$survived" -eq 0 ]
