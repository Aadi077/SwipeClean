import Photos
import SwiftUI

@MainActor
struct DuplicatesView: View {
    @Environment(PhotoDeck.self) private var deck
    @Environment(\.dismiss) private var dismiss

    /// Group id -> the member being kept. Seeded with the biggest file, which
    /// is usually the original rather than a re-save or a share-sheet copy.
    @State private var keepers: [String: String] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if let progress = deck.duplicateProgress {
                    scanning(progress)
                } else if deck.duplicateGroups.isEmpty {
                    empty
                } else {
                    groupList
                }
            }
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        deck.cancelDuplicateScan()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: seedKeepers)
            .onChange(of: deck.duplicateGroups) { seedKeepers() }
        }
    }

    // MARK: - States

    private func scanning(_ progress: (done: Int, total: Int)) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                .tint(Color.keepGreen)
                .frame(width: 220)
            Text("Comparing \(progress.done) of \(progress.total)")
                .font(.callout)
            Text("Only photos taken within a minute of each other are compared, so this skips most of your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(deck.duplicateScanFailed ? .orange
                                 : (deck.hasScannedDuplicates ? Color.keepGreen : .secondary))
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if !deck.hasScannedDuplicates || deck.duplicateScanFailed {
                Button(deck.duplicateScanFailed ? "Try again" : "Scan") { deck.scanForDuplicates() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.keepGreen)
            }
        }
    }

    private var symbol: String {
        if deck.duplicateScanFailed { return "exclamationmark.triangle.fill" }
        return deck.hasScannedDuplicates ? "checkmark.seal.fill" : "square.on.square"
    }

    private var title: String {
        if deck.duplicateScanFailed { return "Couldn't compare photos" }
        return deck.hasScannedDuplicates ? "No duplicates found" : "Find near-duplicates"
    }

    private var message: String {
        if deck.duplicateScanFailed {
            return "Image analysis isn't available here — it needs a real device. Nothing was changed."
        }
        return deck.hasScannedDuplicates
            ? "Nothing in your unreviewed photos looks like a repeat."
            : "Looks for bursts and repeat shots — the same thing photographed several times in a row."
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(deck.duplicateGroups) { group in
                    GroupRow(
                        group: group,
                        keeperID: keepers[group.id] ?? group.memberIDs.first ?? "",
                        onPick: { keepers[group.id] = $0 }
                    )
                }
            }
            .padding(.vertical, 14)
        }
        .safeAreaInset(edge: .bottom) { binBar }
    }

    private var binBar: some View {
        VStack(spacing: 9) {
            Text("Tap a photo to keep that one instead. The rest go to the bin, not straight to deletion.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                deck.markForDeletion(extras)
                dismiss()
            } label: {
                Text("Bin \(extras.count) extra\(extras.count == 1 ? "" : "s")\(savingsSuffix)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.deleteRed, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(extras.isEmpty)
            .opacity(extras.isEmpty ? 0.5 : 1)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    // MARK: - Selection

    private var extras: [String] {
        deck.duplicateGroups.flatMap { group in
            let keeper = keepers[group.id] ?? group.memberIDs.first
            return group.memberIDs.filter { $0 != keeper }
        }
    }

    private var savingsSuffix: String {
        let bytes = extras.reduce(Int64(0)) { $0 + deck.byteSize(for: $1) }
        return bytes > 0 ? " · frees \(Fmt.bytes(bytes))" : ""
    }

    private func seedKeepers() {
        for group in deck.duplicateGroups where keepers[group.id] == nil {
            let best = group.memberIDs.max { a, b in
                deck.byteSize(for: a) < deck.byteSize(for: b)
            }
            keepers[group.id] = best ?? group.memberIDs.first
        }
    }
}

@MainActor
private struct GroupRow: View {
    @Environment(PhotoDeck.self) private var deck
    let group: DuplicateGroup
    let keeperID: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(group.memberIDs.count) similar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        if let asset = deck.asset(for: id) {
                            thumb(asset: asset, id: id)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func thumb(asset: PHAsset, id: String) -> some View {
        let isKeeper = id == keeperID
        return Button { onPick(id) } label: {
            ThumbView(asset: asset)
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isKeeper ? Color.keepGreen : Color.deleteRed.opacity(0.6),
                                      lineWidth: isKeeper ? 3 : 1.5)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isKeeper ? "checkmark.circle.fill" : "trash.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isKeeper ? Color.keepGreen : Color.deleteRed)
                        .font(.title3)
                        .padding(5)
                }
                .opacity(isKeeper ? 1 : 0.55)
                .overlay(alignment: .bottomLeading) {
                    Text(Fmt.bytes(deck.byteSize(for: id)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(5)
                }
        }
        .buttonStyle(.plain)
    }
}
