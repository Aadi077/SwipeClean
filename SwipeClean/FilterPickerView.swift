import SwiftUI

@MainActor
struct FilterPickerView: View {
    @Environment(PhotoDeck.self) private var deck
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                List {
                    Section {
                        FilterRow(
                            title: "All photos",
                            symbol: "photo.stack",
                            total: deck.libraryCount,
                            remaining: deck.unreviewedTotal,
                            isSelected: !deck.isFiltered
                        ) {
                            deck.clearFilter()
                            dismiss()
                        }
                    } footer: {
                        if deck.isFiltered, let summary = deck.filterSummary {
                            Text("Showing \(summary). Filters stack — pick a type and a month to combine them.")
                        }
                    }

                    if deck.categoryBuckets.count > 1 {
                        Section("Type") {
                            ForEach(deck.categoryBuckets) { bucket in
                                FilterRow(
                                    title: bucket.title,
                                    symbol: bucket.symbol,
                                    total: bucket.total,
                                    remaining: bucket.remaining,
                                    isSelected: deck.filter.category.rawValue == bucket.id
                                ) {
                                    deck.setCategory(Category(rawValue: bucket.id) ?? .all)
                                }
                            }
                        }
                    }

                    if !deck.albumBuckets.isEmpty {
                        Section("Albums") {
                            ForEach(deck.albumBuckets) { bucket in
                                FilterRow(
                                    title: bucket.title,
                                    symbol: bucket.symbol,
                                    total: bucket.total,
                                    remaining: bucket.remaining,
                                    isSelected: deck.filter.albumID == bucket.id
                                ) {
                                    deck.setAlbum(bucket.id)
                                }
                            }
                        }
                    }

                    ForEach(deck.monthsByYear) { group in
                        Section(group.label) {
                            ForEach(group.buckets) { bucket in
                                FilterRow(
                                    title: bucket.key.monthName,
                                    symbol: nil,
                                    total: bucket.total,
                                    remaining: bucket.remaining,
                                    isSelected: deck.filter.month == bucket.key
                                ) {
                                    deck.setMonth(bucket.key)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listRowSpacing(2)
            }
            .navigationTitle("Filter photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if deck.isFiltered {
                        Button("Clear") { deck.clearFilter() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { deck.refreshCounts() }
        }
    }
}

/// One selectable slice. Tapping an already-selected type or month clears it,
/// which is why these stay on screen rather than dismissing the sheet.
private struct FilterRow: View {
    let title: String
    let symbol: String?
    let total: Int
    let remaining: Int
    let isSelected: Bool
    let action: () -> Void

    private var isFinished: Bool { total > 0 && remaining == 0 }
    private var progress: Double {
        total == 0 ? 1 : Double(total - remaining) / Double(total)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Color.keepGreen : .secondary)
                        .frame(width: 22)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(isFinished ? "All \(total) reviewed" : "\(remaining) left of \(total)")
                        .font(.caption)
                        .foregroundStyle(isFinished ? Color.keepGreen : .secondary)

                    // Thin bar so a half-finished slice is obvious at a glance.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule()
                                .fill(isFinished ? Color.keepGreen : Color.keepGreen.opacity(0.65))
                                .frame(width: max(0, geo.size.width * progress))
                        }
                    }
                    .frame(height: 3)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.keepGreen : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.cardSurface.opacity(isSelected ? 0.9 : 0.45))
    }
}
