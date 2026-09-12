import Foundation
import Observation
import Photos

enum AssetSize {
    /// Best-effort on-disk size of an asset, summed across its resources
    /// (original + edited render + paired live-photo video).
    static func bytes(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { total, resource in
            if let number = resource.value(forKey: "fileSize") as? NSNumber {
                return total + number.int64Value
            }
            return total
        }
    }
}

struct MonthBucket: Identifiable {
    let key: MonthKey
    let total: Int
    let remaining: Int

    var id: String { key.id }
    var isFinished: Bool { remaining == 0 }
}

struct YearGroup: Identifiable {
    let year: Int
    let buckets: [MonthBucket]

    var id: Int { year }
    var label: String { year == 0 ? "Undated" : String(year) }
}

@MainActor
@Observable
final class PhotoDeck {

    enum Phase: Equatable {
        case loading
        case denied
        case ready
    }

    private struct Move {
        let asset: PHAsset
        let delete: Bool
    }

    private(set) var phase: Phase = .loading
    private(set) var queue: [PHAsset] = []
    private(set) var cursor: Int = 0
    private(set) var pending: [PHAsset] = []
    private(set) var pendingBytes: Int64 = 0
    private(set) var libraryCount: Int = 0
    private(set) var unreviewedTotal: Int = 0
    private(set) var isLimitedAccess = false
    private(set) var isLoading = false
    private(set) var sortOrder: SortOrder = .newest
    private(set) var allowsCellular = false
    private(set) var scope: Scope = .all
    private(set) var months: [MonthBucket] = []

    /// The whole library, kept in memory so changing month or scope is a filter
    /// rather than a refetch.
    private var allAssets: [PHAsset] = []
    private var state = ReviewState()
    private var history: [Move] = []
    private var saveTask: Task<Void, Never>?

    // MARK: - Derived

    var current: PHAsset? { cursor < queue.count ? queue[cursor] : nil }

    /// The two cards peeking out from under the top one.
    var upcoming: [PHAsset] {
        guard cursor + 1 < queue.count else { return [] }
        return Array(queue[(cursor + 1)..<min(cursor + 3, queue.count)])
    }

    var remaining: Int { max(0, queue.count - cursor) }
    var canUndo: Bool { !history.isEmpty }
    var sessionProgress: Double { queue.isEmpty ? 1 : Double(cursor) / Double(queue.count) }
    var isScoped: Bool { scope != .all }

    var monthsByYear: [YearGroup] {
        var order: [Int] = []
        var grouped: [Int: [MonthBucket]] = [:]
        for bucket in months {
            if grouped[bucket.key.year] == nil { order.append(bucket.key.year) }
            grouped[bucket.key.year, default: []].append(bucket)
        }
        return order.map { YearGroup(year: $0, buckets: grouped[$0] ?? []) }
    }

    func window(ahead count: Int) -> [PHAsset] {
        guard cursor < queue.count else { return [] }
        return Array(queue[cursor..<min(cursor + count, queue.count)])
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .loading, !isLoading else { return }
        state = ReviewState.load()
        sortOrder = state.sort
        scope = state.scope
        allowsCellular = state.allowsCellular
        ImageStore.shared.allowsCellular = allowsCellular

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }
        isLimitedAccess = (status == .limited)
        await reload()
        phase = .ready
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        let order = sortOrder
        let all = await Task.detached(priority: .userInitiated) {
            PhotoDeck.fetchAssets(order: order)
        }.value

        // Forget ids for photos that no longer exist so the file doesn't grow forever.
        let liveIDs = Set(all.map(\.localIdentifier))
        state.reviewed.formIntersection(liveIDs)
        state.pending.formIntersection(liveIDs)

        allAssets = all
        libraryCount = all.count
        pending = all.filter { state.pending.contains($0.localIdentifier) }

        rebuildQueue()
        recomputeMonths()
        saveNow()
        recomputePendingBytes()
    }

    private nonisolated static func fetchAssets(order: SortOrder) -> [PHAsset] {
        let options = PHFetchOptions()
        if order != .shuffled {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: order == .oldest)]
        }
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return order == .shuffled ? assets.shuffled() : assets
    }

    /// The queue is always "unreviewed photos inside the current scope". Any
    /// position from a previous queue is meaningless, so start at the top and
    /// drop the undo stack.
    private func rebuildQueue() {
        queue = allAssets.filter { asset in
            !state.reviewed.contains(asset.localIdentifier) && matchesScope(asset)
        }
        cursor = 0
        history.removeAll()
    }

    private func matchesScope(_ asset: PHAsset) -> Bool {
        switch scope {
        case .all:
            return true
        case .month(let key):
            return MonthKey(for: asset.creationDate) == key
        }
    }

    // MARK: - Months

    private func recomputeMonths() {
        var totals: [MonthKey: (total: Int, remaining: Int)] = [:]
        var unreviewed = 0

        for asset in allAssets {
            let key = MonthKey(for: asset.creationDate)
            var entry = totals[key] ?? (total: 0, remaining: 0)
            entry.total += 1
            if !state.reviewed.contains(asset.localIdentifier) {
                entry.remaining += 1
                unreviewed += 1
            }
            totals[key] = entry
        }

        unreviewedTotal = unreviewed
        months = totals
            .map { MonthBucket(key: $0.key, total: $0.value.total, remaining: $0.value.remaining) }
            .sorted { a, b in
                // Undated last, then newest month first.
                if a.key.isUndated != b.key.isUndated { return b.key.isUndated }
                if a.key.year != b.key.year { return a.key.year > b.key.year }
                return a.key.month > b.key.month
            }
    }

    /// Counts drift as you swipe; the month sheet calls this when it opens.
    func refreshMonths() {
        recomputeMonths()
    }

    func setScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        scope = newScope
        state.scope = newScope
        rebuildQueue()
        recomputeMonths()
        saveNow()
    }

    // MARK: - Swiping

    func decide(delete: Bool) {
        guard let asset = current else { return }

        state.reviewed.insert(asset.localIdentifier)
        if delete {
            state.pending.insert(asset.localIdentifier)
            pending.append(asset)
            Task.detached(priority: .utility) {
                let size = AssetSize.bytes(of: asset)
                await MainActor.run { self.pendingBytes += size }
            }
        }

        history.append(Move(asset: asset, delete: delete))
        if history.count > 200 { history.removeFirst() }

        cursor += 1
        unreviewedTotal = max(0, unreviewedTotal - 1)
        scheduleSave()
    }

    func undo() {
        guard let move = history.popLast() else { return }

        state.reviewed.remove(move.asset.localIdentifier)
        if move.delete {
            state.pending.remove(move.asset.localIdentifier)
            pending.removeAll { $0.localIdentifier == move.asset.localIdentifier }
            recomputePendingBytes()
        }
        cursor = max(0, cursor - 1)
        unreviewedTotal += 1
        scheduleSave()
    }

    /// Pull a photo back out of the bin; it stays reviewed, just kept.
    func restore(_ asset: PHAsset) {
        state.pending.remove(asset.localIdentifier)
        pending.removeAll { $0.localIdentifier == asset.localIdentifier }
        history.removeAll { $0.asset.localIdentifier == asset.localIdentifier }
        recomputePendingBytes()
        scheduleSave()
    }

    func setAllowsCellular(_ allowed: Bool) {
        guard allowed != allowsCellular else { return }
        allowsCellular = allowed
        state.allowsCellular = allowed
        ImageStore.shared.allowsCellular = allowed
        saveNow()
    }

    func setSort(_ order: SortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        state.sort = order
        saveNow()
        Task { await reload() }
    }

    // MARK: - Deleting for real

    /// iOS shows its own "Delete N items?" confirmation here, and everything
    /// lands in Recently Deleted for 30 days. Throws if the user cancels.
    func emptyTrash() async throws {
        let targets = pending
        guard !targets.isEmpty else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(targets as NSArray)
        }

        let goneIDs = Set(targets.map(\.localIdentifier))
        state.pending.subtract(goneIDs)
        state.reviewed.subtract(goneIDs)
        allAssets.removeAll { goneIDs.contains($0.localIdentifier) }
        pending.removeAll()
        pendingBytes = 0
        libraryCount = allAssets.count

        // Deleted assets are still sitting behind the cursor in `queue`; undoing
        // back onto one would show a photo that no longer exists.
        history.removeAll()
        recomputeMonths()
        saveNow()
    }

    /// Clears progress for whatever is currently in scope — the month you're
    /// looking at, or the whole library when nothing is scoped.
    func resetProgress() async {
        let targetIDs = Set(allAssets.filter { matchesScope($0) }.map(\.localIdentifier))
        state.reviewed.subtract(targetIDs)
        state.pending.subtract(targetIDs)
        pending.removeAll { targetIDs.contains($0.localIdentifier) }

        rebuildQueue()
        recomputeMonths()
        recomputePendingBytes()
        saveNow()
    }

    // MARK: - Persistence

    private func recomputePendingBytes() {
        let targets = pending
        Task.detached(priority: .utility) {
            let total = targets.reduce(Int64(0)) { $0 + AssetSize.bytes(of: $1) }
            await MainActor.run { self.pendingBytes = total }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = state
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .background) { snapshot.save() }.value
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = state
        Task.detached(priority: .utility) { snapshot.save() }
    }
}
