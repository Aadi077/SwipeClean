import Photos
import SwiftUI

@MainActor
struct TrashView: View {
    @Environment(PhotoDeck.self) private var deck
    @Environment(\.dismiss) private var dismiss

    @State private var isDeleting = false
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if deck.pending.isEmpty {
                    ContentUnavailableView(
                        "Nothing marked",
                        systemImage: "trash",
                        description: Text("Swipe a photo left to put it in here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(deck.pending, id: \.localIdentifier) { asset in
                                Button {
                                    withAnimation(.snappy) { deck.restore(asset) }
                                } label: {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fill)
                                        .overlay { ThumbView(asset: asset) }
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.55))
                                                .font(.title3)
                                                .padding(5)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }
                    .safeAreaInset(edge: .bottom) { deleteBar }
                }
            }
            .navigationTitle("Marked for deletion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't delete", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var deleteBar: some View {
        VStack(spacing: 10) {
            Text("Tap any photo to put it back. Deleted items go to Recently Deleted for 30 days.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: performDelete) {
                HStack(spacing: 8) {
                    if isDeleting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text(buttonTitle)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.deleteRed, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var buttonTitle: String {
        let count = deck.pending.count
        let noun = count == 1 ? "item" : "items"
        let suffix = deck.pendingBytes > 0 ? " · frees \(Fmt.bytes(deck.pendingBytes))" : ""
        return "Delete \(count) \(noun)\(suffix)"
    }

    private func performDelete() {
        isDeleting = true
        Task {
            do {
                try await deck.emptyTrash()
                dismiss()
            } catch {
                // Cancelling the system confirmation lands here too; stay put quietly.
                let nsError = error as NSError
                if nsError.domain != "PHPhotosErrorDomain" || nsError.code != 3072 {
                    errorText = error.localizedDescription
                }
            }
            isDeleting = false
        }
    }
}
