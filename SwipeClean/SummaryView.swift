import SwiftUI

/// The receipt. Swiping is effort with an invisible payoff otherwise — this is
/// where the reclaimed space actually shows up.
@MainActor
struct SummaryView: View {
    @Environment(PhotoDeck.self) private var deck
    var justFreed: Int64?
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            if let justFreed {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.keepGreen)
                    Text("Freed \(Fmt.bytes(justFreed))")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Those items are in Recently Deleted for 30 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.keepGreen)
            }

            panel(title: "This session", rows: [
                ("\(deck.sessionReviewed)", "reviewed"),
                ("\(deck.sessionBinned)", "binned"),
                (Fmt.bytes(deck.sessionFreed), "freed"),
            ])

            panel(title: "All time", rows: [
                ("\(deck.lifetimeReviewed)", "reviewed"),
                (Fmt.bytes(deck.lifetimeFreed), "freed"),
            ])

            Spacer(minLength: 0)

            Button("Done", action: onDone)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.keepGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    private func panel(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            HStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(spacing: 3) {
                        Text(row.0)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text(row.1)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
