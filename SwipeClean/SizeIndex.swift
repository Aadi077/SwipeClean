import Foundation

/// A persisted map of asset id to on-disk bytes.
///
/// Measuring a single asset means a PHAssetResource lookup, which is far too
/// slow to do inline for a whole library — so results are cached to disk, built
/// once in the background, and topped up opportunistically as cards are viewed.
final class SizeIndex: @unchecked Sendable {
    static let shared = SizeIndex()

    private var sizes: [String: Int64] = [:]
    private var loaded = false
    private var dirty = false
    private let lock = NSLock()

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sizes.json")
    }

    private init() {}

    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: Int64].self, from: data) {
            sizes = stored
        }
    }

    func size(for id: String) -> Int64? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return sizes[id]
    }

    /// Ids we haven't measured yet, in the order given.
    func missingIDs(among ids: [String]) -> [String] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return ids.filter { sizes[$0] == nil }
    }

    func merge(_ batch: [String: Int64]) {
        guard !batch.isEmpty else { return }
        loadIfNeeded()
        lock.lock()
        sizes.merge(batch) { _, new in new }
        dirty = true
        lock.unlock()
    }

    /// Drop entries for assets that no longer exist, so the file doesn't grow
    /// forever the way the review state would have.
    func prune(to live: Set<String>) {
        loadIfNeeded()
        lock.lock()
        let before = sizes.count
        sizes = sizes.filter { live.contains($0.key) }
        if sizes.count != before { dirty = true }
        lock.unlock()
    }

    func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = sizes
        dirty = false
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
