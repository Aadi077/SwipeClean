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

/// Everything that survives an app relaunch: which photos you've already judged,
/// which ones are waiting in the trash, and the order you like to review in.
struct ReviewState: Codable {
    var reviewed: Set<String> = []
    var pending: Set<String> = []
    var sort: SortOrder = .newest

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
