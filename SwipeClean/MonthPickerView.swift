import SwiftUI

@MainActor
struct MonthPickerView: View {
    @Environment(PhotoDeck.self) private var deck
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                List {
                    Section {
                        ScopeRow(
                            title: "All photos",
                            total: deck.libraryCount,
                            remaining: deck.unreviewedTotal,
                            isSelected: deck.scope == .all
                        ) {
                            choose(.all)
                        }
                    }

                    ForEach(deck.monthsByYear) { group in
                        Section(group.label) {
                            ForEach(group.buckets) { bucket in
                                ScopeRow(
                                    title: bucket.key.monthName,
                                    total: bucket.total,
                                    remaining: bucket.remaining,
                                    isSelected: deck.scope == .month(bucket.key)
                                ) {
                                    choose(.month(bucket.key))
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listRowSpacing(2)
            }
            .navigationTitle("Browse by month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { deck.refreshMonths() }
        }
    }

    private func choose(_ scope: Scope) {
        deck.setScope(scope)
        dismiss()
    }
}

private struct ScopeRow: View {
    let title: String
    let total: Int
    let remaining: Int
    let isSelected: Bool
    let action: () -> Void

    private var isFinished: Bool { remaining == 0 }
    private var progress: Double {
        total == 0 ? 1 : Double(total - remaining) / Double(total)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(isFinished ? "All \(total) reviewed" : "\(remaining) left of \(total)")
                        .font(.caption)
                        .foregroundStyle(isFinished ? Color.keepGreen : .secondary)

                    // Thin bar so a half-finished month is obvious at a glance.
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
