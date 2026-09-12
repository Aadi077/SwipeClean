import Foundation

enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case newest
    case oldest
    case shuffled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .shuffled: return "Shuffled"
        }
    }

    var symbol: String {
        switch self {
        case .newest: return "arrow.down.to.line"
        case .oldest: return "arrow.up.to.line"
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

/// Which slice of the library the deck is serving up.
enum Scope: Hashable, Codable {
    case all
    case month(MonthKey)

    var title: String {
        switch self {
        case .all: return "your library"
        case .month(let key): return key.title
        }
    }
}

/// Everything that survives an app relaunch: which photos you've already judged,
/// which ones are waiting in the bin, and how you like to review.
struct ReviewState: Codable {
    var reviewed: Set<String> = []
    var pending: Set<String> = []
    var sort: SortOrder = .newest
    var scope: Scope = .all

    init() {}

    // Decoded leniently so adding a field in a later version doesn't throw away
    // someone's review progress — a missing key falls back to its default.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        reviewed = try box.decodeIfPresent(Set<String>.self, forKey: .reviewed) ?? []
        pending = try box.decodeIfPresent(Set<String>.self, forKey: .pending) ?? []
        sort = try box.decodeIfPresent(SortOrder.self, forKey: .sort) ?? .newest
        scope = try box.decodeIfPresent(Scope.self, forKey: .scope) ?? .all
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
