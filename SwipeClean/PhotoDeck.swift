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
    private(set) var isLimitedAccess = false
    private(set) var isLoading = false
    private(set) var sortOrder: SortOrder = .newest

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

    func window(ahead count: Int) -> [PHAsset] {
        guard cursor < queue.count else { return [] }
        return Array(queue[cursor..<min(cursor + count, queue.count)])
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .loading, !isLoading else { return }
        state = ReviewState.load()
        sortOrder = state.sort

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

        libraryCount = all.count
        pending = all.filter { state.pending.contains($0.localIdentifier) }
        queue = all.filter { !state.reviewed.contains($0.localIdentifier) }

        // The rebuilt queue holds only unreviewed photos, so every position from
        // the old queue is meaningless — start at the top and drop the undo stack.
        cursor = 0
        history.removeAll()

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
        scheduleSave()
    }

    /// Pull a photo back out of the trash pile; it stays reviewed, just kept.
    func restore(_ asset: PHAsset) {
        state.pending.remove(asset.localIdentifier)
        pending.removeAll { $0.localIdentifier == asset.localIdentifier }
        history.removeAll { $0.asset.localIdentifier == asset.localIdentifier }
        recomputePendingBytes()
        scheduleSave()
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

        for asset in targets {
            state.pending.remove(asset.localIdentifier)
        }
        pending.removeAll()
        pendingBytes = 0
        history.removeAll()
        libraryCount = max(0, libraryCount - targets.count)
        saveNow()
    }

    func resetProgress() async {
        state.reviewed.removeAll()
        state.pending.removeAll()
        pending.removeAll()
        pendingBytes = 0
        history.removeAll()
        saveNow()
        await reload()
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
