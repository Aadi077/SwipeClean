import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @Environment(PhotoDeck.self) private var deck
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            switch deck.phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text("Reading your library…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .denied:
                PermissionView()
            case .ready:
                VStack(spacing: 0) {
                    if deck.isLimitedAccess { limitedBanner }
                    DeckScreen()
                }
            }
        }
        .task { await deck.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { deck.saveNow() }
        }
    }

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Only your selected photos are visible. Switch to Full Access in Settings to review everything.")
                .font(.caption)
            Spacer(minLength: 0)
            Button("Settings", action: openSettings)
                .font(.caption.bold())
        }
        .padding(12)
        .background(Color.orange.opacity(0.18))
        .foregroundStyle(.orange)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

@MainActor
struct PermissionView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("SwipeClean needs your photos")
                .font(.title2.bold())
            Text("Grant photo access and you can swipe through your whole library — left to bin, right to keep. Nothing is deleted until you confirm.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 36)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.keepGreen)
        }
    }
}
