import Foundation

enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case newest
    case oldest
    case largest
    case shuffled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .largest: return "Biggest first"
        case .shuffled: return "Shuffled"
        }
    }

    var symbol: String {
        switch self {
        case .newest: return "arrow.down.to.line"
        case .oldest: return "arrow.up.to.line"
        case .largest: return "externaldrive"
        case .shuffled: return "shuffle"
        }
    }
}

/// One calendar month. `month == 0` is the bucket for photos with no date.
struct MonthKey: Hashable, Codable, Identifiable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(month)" }
    var isUndated: Bool { month == 0 }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(for date: Date?) {
        guard let date else {
            self.init(year: 0, month: 0)
            return
        }
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    private var firstOfMonth: Date? {
        guard !isUndated else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// "September 2026"
    var title: String {
        guard let date = firstOfMonth else { return "No date" }
        return Fmt.monthYear.string(from: date)
    }

    /// "September" — for rows already grouped under a year heading.
    var monthName: String {
        guard let date = firstOfMonth else { return "No date" }
        return Fmt.monthOnly.string(from: date)
    }
}

/// Kinds of photo you can single out. These map onto properties PhotoKit
/// already hands us, so filtering stays an in-memory predicate.
enum Category: String, Codable, CaseIterable, Identifiable {
    case all
    case screenshots
    case videos
    case selfies
    case livePhotos
    case favorites

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Any type"
        case .screenshots: return "Screenshots"
        case .videos: return "Videos"
        case .selfies: return "Selfies"
        case .livePhotos: return "Live Photos"
        case .favorites: return "Favorites"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .screenshots: return "camera.viewfinder"
        case .videos: return "video"
        case .selfies: return "person.crop.square"
        case .livePhotos: return "livephoto"
        case .favorites: return "heart"
        }
    }
}

/// Which slice of the library the deck is serving up. Every non-default field
/// narrows further — they AND together, so "Screenshots from Sept 2024" works.
struct Filter: Hashable, Codable {
    var category: Category = .all
    var month: MonthKey? = nil
    var albumID: String? = nil
    /// Inverts the deck to show only the deferred pile.
    var skippedOnly = false

    var isDefault: Bool { self == Filter() }

    init(category: Category = .all, month: MonthKey? = nil, albumID: String? = nil, skippedOnly: Bool = false) {
        self.category = category
        self.month = month
        self.albumID = albumID
        self.skippedOnly = skippedOnly
    }

    // Lenient like ReviewState: a field added in a later version must not make
    // an existing filter undecodable.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        category = (try? box.decodeIfPresent(Category.self, forKey: .category) ?? .all) ?? .all
        month = try? box.decodeIfPresent(MonthKey.self, forKey: .month)
        albumID = try? box.decodeIfPresent(String.self, forKey: .albumID)
        skippedOnly = (try? box.decodeIfPresent(Bool.self, forKey: .skippedOnly) ?? false) ?? false
    }
}

/// Only still read, to carry a pre-filter state file forward.
enum LegacyScope: Hashable, Codable {
    case all
    case month(MonthKey)
}

/// Everything that survives an app relaunch: which photos you've already judged,
/// which ones are waiting in the bin, and how you like to review.
struct ReviewState: Codable {
    var reviewed: Set<String> = []
    var pending: Set<String> = []
    /// Deferred, not judged — deliberately separate from `reviewed`.
    var skipped: Set<String> = []
    var sort: SortOrder = .newest
    var filter = Filter()
    var allowsCellular = false
    var lifetimeReviewed = 0
    var lifetimeFreed: Int64 = 0

    init() {}

    // Decoded leniently so adding a field in a later version doesn't throw away
    // someone's review progress — a missing key falls back to its default.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        reviewed = try box.decodeIfPresent(Set<String>.self, forKey: .reviewed) ?? []
        pending = try box.decodeIfPresent(Set<String>.self, forKey: .pending) ?? []
        skipped = try box.decodeIfPresent(Set<String>.self, forKey: .skipped) ?? []
        sort = try box.decodeIfPresent(SortOrder.self, forKey: .sort) ?? .newest
        allowsCellular = try box.decodeIfPresent(Bool.self, forKey: .allowsCellular) ?? false
        lifetimeReviewed = try box.decodeIfPresent(Int.self, forKey: .lifetimeReviewed) ?? 0
        lifetimeFreed = try box.decodeIfPresent(Int64.self, forKey: .lifetimeFreed) ?? 0

        // A shape mismatch here must never throw: load() turns any decode error
        // into a blank state, which would silently discard all review progress.
        if let saved = try? box.decodeIfPresent(Filter.self, forKey: .filter) {
            filter = saved
        } else if let legacyBox = try? decoder.container(keyedBy: LegacyKeys.self),
                  let legacy = try? legacyBox.decodeIfPresent(LegacyScope.self, forKey: .scope),
                  case .month(let key) = legacy {
            filter = Filter(month: key)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reviewed, pending, skipped, sort, filter, allowsCellular
        case lifetimeReviewed, lifetimeFreed
    }

    /// Read-only; `scope` was replaced by `filter`. Kept in its own key set so it
    /// doesn't break the synthesized encoder, which requires every CodingKeys
    /// case to match a stored property.
    private enum LegacyKeys: String, CodingKey {
        case scope
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("review-state.json")
    }

    static func load() -> ReviewState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(ReviewState.self, from: data)
        else { return ReviewState() }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
