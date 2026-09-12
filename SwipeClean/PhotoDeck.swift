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

/// Collection-derived facts about the library, gathered off the main actor.
struct LibraryIndex {
    var albumMembers: [String: Set<String>] = [:]
    var albumTitles: [String: String] = [:]
    var selfieIDs: Set<String> = []
}

struct CountBucket: Identifiable {
    let id: String
    let title: String
    let symbol: String?
    let total: Int
    let remaining: Int

    var isFinished: Bool { total > 0 && remaining == 0 }
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

    enum Verdict {
        case keep
        case bin
        case skip
    }

    private struct Move {
        let asset: PHAsset
        let verdict: Verdict
        /// Whether the photo had been deferred before this move, so undo can
        /// put it back in the skip pile rather than the main queue.
        let wasSkipped: Bool
    }

    private(set) var phase: Phase = .loading
    private(set) var queue: [PHAsset] = []
    private(set) var cursor: Int = 0
    private(set) var pending: [PHAsset] = []
    private(set) var pendingBytes: Int64 = 0
    private(set) var libraryCount: Int = 0
    private(set) var unreviewedTotal: Int = 0
    private(set) var skippedCount: Int = 0
    /// Non-nil while the background size measurement is running.
    private(set) var sizingProgress: (done: Int, total: Int)?
    private(set) var isLimitedAccess = false
    private(set) var isLoading = false
    private(set) var sortOrder: SortOrder = .newest
    private(set) var allowsCellular = false
    private(set) var filter = Filter()
    private(set) var months: [MonthBucket] = []
    private(set) var categoryBuckets: [CountBucket] = []
    private(set) var albumBuckets: [CountBucket] = []

    /// The whole library, kept in memory so changing month or scope is a filter
    /// rather than a refetch.
    private var allAssets: [PHAsset] = []
    private var assetsByID: [String: PHAsset] = [:]
    /// localIdentifier sets per album, and the ids PhotoKit considers selfies.
    private var albumMembers: [String: Set<String>] = [:]
    private var albumTitles: [String: String] = [:]
    private var selfieIDs: Set<String> = []
    private var state = ReviewState()
    private var history: [Move] = []
    private var saveTask: Task<Void, Never>?
    private var sizingTask: Task<Void, Never>?

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
    var isFiltered: Bool { !filter.isDefault }

    /// "Screenshots · Sept 2024", or nil when nothing is narrowed.
    var filterSummary: String? {
        var parts: [String] = []
        if filter.skippedOnly { parts.append("Skipped") }
        if filter.category != .all { parts.append(filter.category.label) }
        if let albumID = filter.albumID { parts.append(albumTitles[albumID] ?? "Album") }
        if let month = filter.month { parts.append(month.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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
        filter = state.filter
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
        let index = await Task.detached(priority: .userInitiated) {
            PhotoDeck.fetchIndex()
        }.value

        // Forget ids for photos that no longer exist so the file doesn't grow forever.
        let liveIDs = Set(all.map(\.localIdentifier))
        state.reviewed.formIntersection(liveIDs)
        state.pending.formIntersection(liveIDs)
        state.skipped.formIntersection(liveIDs)
        SizeIndex.shared.prune(to: liveIDs)

        allAssets = all
        assetsByID = Dictionary(all.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        albumMembers = index.albumMembers
        albumTitles = index.albumTitles
        selfieIDs = index.selfieIDs
        libraryCount = all.count
        pending = all.filter { state.pending.contains($0.localIdentifier) }

        // An album that vanished shouldn't leave the deck stuck showing nothing.
        if let albumID = filter.albumID, albumMembers[albumID] == nil {
            filter.albumID = nil
            state.filter = filter
        }

        rebuildQueue()
        recomputeBuckets()
        saveNow()
        recomputePendingBytes()
        ensureSizesIndexed()
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

    /// Album membership and the selfie list, which are collection lookups rather
    /// than asset properties. Done once per reload, off the main actor.
    private nonisolated static func fetchIndex() -> LibraryIndex {
        var index = LibraryIndex()

        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { collection, _, _ in
            let contents = PHAsset.fetchAssets(in: collection, options: nil)
            guard contents.count > 0 else { return }
            var ids = Set<String>()
            ids.reserveCapacity(contents.count)
            contents.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            index.albumMembers[collection.localIdentifier] = ids
            index.albumTitles[collection.localIdentifier] = collection.localizedTitle ?? "Untitled album"
        }

        let selfies = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                             subtype: .smartAlbumSelfPortraits,
                                                             options: nil)
        selfies.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                index.selfieIDs.insert(asset.localIdentifier)
            }
        }

        return index
    }

    /// The queue is always "unreviewed photos matching the filter". Any position
    /// from a previous queue is meaningless, so start at the top and drop undo.
    private func rebuildQueue() {
        queue = allAssets.filter { asset in
            !state.reviewed.contains(asset.localIdentifier) && matches(asset, filter)
        }
        if sortOrder == .largest {
            queue.sort { bytes(of: $0) > bytes(of: $1) }
        }
        cursor = 0
        history.removeAll()
    }

    private func bytes(of asset: PHAsset) -> Int64 {
        SizeIndex.shared.size(for: asset.localIdentifier) ?? 0
    }

    /// Re-sorts only the part of the queue still ahead of the cursor. Sorting
    /// the whole array would pull already-reviewed photos back in front of it.
    private func resortRemaining() {
        guard sortOrder == .largest, cursor < queue.count else { return }
        let head = Array(queue[..<cursor])
        let tail = Array(queue[cursor...]).sorted { bytes(of: $0) > bytes(of: $1) }
        queue = head + tail
    }

    /// Measures anything unmeasured, in the background, then re-sorts. The deck
    /// stays usable in its existing order while this runs.
    func ensureSizesIndexed() {
        guard sortOrder == .largest, sizingTask == nil else { return }

        let missing = Set(SizeIndex.shared.missingIDs(among: allAssets.map(\.localIdentifier)))
        let todo = allAssets.filter { missing.contains($0.localIdentifier) }
        guard !todo.isEmpty else {
            resortRemaining()
            return
        }

        sizingProgress = (done: 0, total: todo.count)
        sizingTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [String: Int64] = [:]
            var done = 0

            for asset in todo {
                if Task.isCancelled { break }
                batch[asset.localIdentifier] = AssetSize.bytes(of: asset)
                done += 1

                if batch.count >= 50 {
                    SizeIndex.shared.merge(batch)
                    batch.removeAll(keepingCapacity: true)
                    let sofar = done
                    let outOf = todo.count
                    await MainActor.run { [weak self] in
                        self?.sizingProgress = (done: sofar, total: outOf)
                    }
                }
            }

            SizeIndex.shared.merge(batch)
            SizeIndex.shared.save()

            await MainActor.run { [weak self] in
                self?.sizingProgress = nil
                self?.sizingTask = nil
                self?.resortRemaining()
            }
        }
    }

    private func matches(_ asset: PHAsset, _ candidate: Filter, ignoringSkipAxis: Bool = false) -> Bool {
        // The deferred pile is a mode, not a slice: normal browsing hides it,
        // and skippedOnly shows nothing else.
        if !ignoringSkipAxis,
           state.skipped.contains(asset.localIdentifier) != candidate.skippedOnly { return false }
        if let month = candidate.month, MonthKey(for: asset.creationDate) != month { return false }
        if let albumID = candidate.albumID,
           albumMembers[albumID]?.contains(asset.localIdentifier) != true { return false }
        return matchesCategory(asset, candidate.category)
    }

    private func matchesCategory(_ asset: PHAsset, _ category: Category) -> Bool {
        switch category {
        case .all: return true
        case .screenshots: return asset.mediaSubtypes.contains(.photoScreenshot)
        case .videos: return asset.mediaType == .video
        case .selfies: return selfieIDs.contains(asset.localIdentifier)
        case .livePhotos: return asset.mediaSubtypes.contains(.photoLive)
        case .favorites: return asset.isFavorite
        }
    }

    // MARK: - Counts

    /// Facet counts: each axis is counted with *itself* relaxed but the other
    /// axes applied, so the month list shows how many screenshots each month
    /// holds once Screenshots is picked.
    private func recomputeBuckets() {
        var monthTotals: [MonthKey: (total: Int, remaining: Int)] = [:]
        var categoryTotals: [Category: (total: Int, remaining: Int)] = [:]
        var albumTotals: [String: (total: Int, remaining: Int)] = [:]
        var unreviewed = 0

        var withoutMonth = filter; withoutMonth.month = nil
        var withoutCategory = filter; withoutCategory.category = .all
        var withoutAlbum = filter; withoutAlbum.albumID = nil

        for asset in allAssets {
            let fresh = !state.reviewed.contains(asset.localIdentifier)
                && !state.skipped.contains(asset.localIdentifier)
            if fresh { unreviewed += 1 }

            if matches(asset, withoutMonth) {
                let key = MonthKey(for: asset.creationDate)
                var entry = monthTotals[key] ?? (total: 0, remaining: 0)
                entry.total += 1
                if fresh { entry.remaining += 1 }
                monthTotals[key] = entry
            }

            if matches(asset, withoutCategory) {
                for category in Category.allCases where matchesCategory(asset, category) {
                    var entry = categoryTotals[category] ?? (total: 0, remaining: 0)
                    entry.total += 1
                    if fresh { entry.remaining += 1 }
                    categoryTotals[category] = entry
                }
            }
        }

        // Walk membership sets rather than assets × albums.
        for (albumID, members) in albumMembers {
            var entry = (total: 0, remaining: 0)
            for memberID in members {
                guard let asset = assetsByID[memberID], matches(asset, withoutAlbum) else { continue }
                entry.total += 1
                if !state.reviewed.contains(memberID) { entry.remaining += 1 }
            }
            if entry.total > 0 { albumTotals[albumID] = entry }
        }

        unreviewedTotal = unreviewed
        skippedCount = state.skipped.count

        months = monthTotals
            .map { MonthBucket(key: $0.key, total: $0.value.total, remaining: $0.value.remaining) }
            .sorted { a, b in
                // Undated last, then newest month first.
                if a.key.isUndated != b.key.isUndated { return b.key.isUndated }
                if a.key.year != b.key.year { return a.key.year > b.key.year }
                return a.key.month > b.key.month
            }

        categoryBuckets = Category.allCases.compactMap { category in
            guard let entry = categoryTotals[category], entry.total > 0 else { return nil }
            return CountBucket(id: category.rawValue, title: category.label, symbol: category.symbol,
                               total: entry.total, remaining: entry.remaining)
        }

        albumBuckets = albumTotals
            .map { CountBucket(id: $0.key, title: albumTitles[$0.key] ?? "Album",
                               symbol: "rectangle.stack", total: $0.value.total, remaining: $0.value.remaining) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Counts drift as you swipe; the filter sheet calls this when it opens.
    func refreshCounts() {
        recomputeBuckets()
    }

    func setFilter(_ newFilter: Filter) {
        guard newFilter != filter else { return }
        filter = newFilter
        state.filter = newFilter
        rebuildQueue()
        recomputeBuckets()
        saveNow()
    }

    func clearFilter() { setFilter(Filter()) }

    func setCategory(_ category: Category) {
        var next = filter
        next.category = category
        setFilter(next)
    }

    func setMonth(_ month: MonthKey?) {
        var next = filter
        next.month = (filter.month == month) ? nil : month
        setFilter(next)
    }

    func setAlbum(_ albumID: String?) {
        var next = filter
        next.albumID = (filter.albumID == albumID) ? nil : albumID
        setFilter(next)
    }

    // MARK: - Swiping

    func decide(delete: Bool) {
        guard let asset = current else { return }

        let wasSkipped = state.skipped.remove(asset.localIdentifier) != nil
        state.reviewed.insert(asset.localIdentifier)
        if delete {
            state.pending.insert(asset.localIdentifier)
            pending.append(asset)
            if let known = SizeIndex.shared.size(for: asset.localIdentifier) {
                pendingBytes += known
            } else {
                Task.detached(priority: .utility) {
                    let size = AssetSize.bytes(of: asset)
                    SizeIndex.shared.merge([asset.localIdentifier: size])
                    await MainActor.run { self.pendingBytes += size }
                }
            }
        }

        history.append(Move(asset: asset, verdict: delete ? .bin : .keep, wasSkipped: wasSkipped))
        if history.count > 200 { history.removeFirst() }

        cursor += 1
        if !wasSkipped { unreviewedTotal = max(0, unreviewedTotal - 1) }
        skippedCount = state.skipped.count
        scheduleSave()
    }

    /// Defer a photo. It leaves the queue without being judged and waits in the
    /// skip pile, which survives relaunch.
    func skip() {
        guard let asset = current else { return }

        state.skipped.insert(asset.localIdentifier)
        history.append(Move(asset: asset, verdict: .skip, wasSkipped: false))
        if history.count > 200 { history.removeFirst() }

        cursor += 1
        unreviewedTotal = max(0, unreviewedTotal - 1)
        skippedCount = state.skipped.count
        scheduleSave()
    }

    func undo() {
        guard let move = history.popLast() else { return }
        let id = move.asset.localIdentifier

        switch move.verdict {
        case .keep, .bin:
            state.reviewed.remove(id)
            if move.verdict == .bin {
                state.pending.remove(id)
                pending.removeAll { $0.localIdentifier == id }
                recomputePendingBytes()
            }
            // Restore the pile membership it had before, not a blanket un-skip.
            if move.wasSkipped { state.skipped.insert(id) } else { unreviewedTotal += 1 }
        case .skip:
            state.skipped.remove(id)
            unreviewedTotal += 1
        }

        skippedCount = state.skipped.count
        cursor = max(0, cursor - 1)
        scheduleSave()
    }

    /// Pull a photo back out of the bin; it stays reviewed, just kept.
    func toggleSkippedOnly() {
        var next = filter
        next.skippedOnly.toggle()
        setFilter(next)
    }

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
        if order != .largest {
            sizingTask?.cancel()
            sizingTask = nil
            sizingProgress = nil
        }
        sortOrder = order
        state.sort = order
        saveNow()
        Task {
            await reload()
            ensureSizesIndexed()
        }
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
        recomputeBuckets()
        saveNow()
    }

    /// Clears progress for whatever is currently in scope — the month you're
    /// looking at, or the whole library when nothing is scoped.
    func resetProgress() async {
        // Starting over clears deferrals too, so the skip axis is ignored when
        // working out what's in scope — otherwise the pile would survive a reset.
        let targetIDs = Set(allAssets
            .filter { matches($0, filter, ignoringSkipAxis: true) }
            .map(\.localIdentifier))
        state.reviewed.subtract(targetIDs)
        state.pending.subtract(targetIDs)
        state.skipped.subtract(targetIDs)
        pending.removeAll { targetIDs.contains($0.localIdentifier) }

        rebuildQueue()
        recomputeBuckets()
        recomputePendingBytes()
        saveNow()
    }

    // MARK: - Persistence

    private func recomputePendingBytes() {
        let targets = pending
        Task.detached(priority: .utility) {
            var total: Int64 = 0
            var measured: [String: Int64] = [:]

            for asset in targets {
                if let known = SizeIndex.shared.size(for: asset.localIdentifier) {
                    total += known
                } else {
                    let size = AssetSize.bytes(of: asset)
                    measured[asset.localIdentifier] = size
                    total += size
                }
            }

            SizeIndex.shared.merge(measured)
            let settled = total
            await MainActor.run { self.pendingBytes = settled }
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
