import AVFoundation
import Photos
import SwiftUI

/// The rounded, shadowed card shell. Kept separate so the stacked cards behind
/// the top one get exactly the same look.
@MainActor
struct CardFrame: View {
    let asset: PHAsset
    let size: CGSize
    let fit: Bool
    var paused: Bool = false

    var body: some View {
        PhotoCardView(asset: asset, fit: fit, paused: paused)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
    }
}

@MainActor
struct PhotoCardView: View {
    let asset: PHAsset
    let fit: Bool
    var paused: Bool = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var sizeText: String?
    @State private var needsNetwork = false
    @State private var downloadProgress: Double?
    @State private var forceDownload = false
    @State private var player: AVPlayer?

    private var isVideo: Bool { asset.mediaType == .video }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.cardSurface

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if needsNetwork {
                    waitingForWiFi
                } else if let downloadProgress {
                    downloadRing(downloadProgress)
                } else {
                    ProgressView().tint(.white.opacity(0.35))
                }

                if isVideo, let player {
                    PlayerLayerView(player: player, fill: !fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                if isVideo && paused {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 60))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .allowsHitTesting(false)
                }

                caption.frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.18), value: image)
            .task(id: asset.localIdentifier) {
                guard isVideo else { return }
                guard let item = await ImageStore.shared.playerItem(for: asset) else { return }
                let made = AVPlayer(playerItem: item)
                made.isMuted = true                  // triage, not viewing
                made.actionAtItemEnd = .none
                player = made
                if !paused { made.play() }
            }
            .onChange(of: paused) { _, isPaused in
                isPaused ? player?.pause() : player?.play()
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
                // Loop, so a two-second clip isn't a single blink.
                guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
                player?.seek(to: .zero)
                if !paused { player?.play() }
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .task(id: "\(asset.localIdentifier)|\(forceDownload)") {
                let pixels = CGSize(width: geo.size.width * displayScale,
                                    height: geo.size.height * displayScale)
                needsNetwork = false
                downloadProgress = nil

                let outcome = await ImageStore.shared.load(
                    for: asset,
                    size: pixels,
                    force: forceDownload,
                    onProgress: { value in
                        Task { @MainActor in downloadProgress = value }
                    }
                )

                downloadProgress = nil
                switch outcome {
                case .image(let loaded): image = loaded
                case .needsNetwork: needsNetwork = true
                case .failed: image = nil
                }
            }
            .task(id: asset.localIdentifier) {
                let bytes = await ImageStore.shared.byteSize(of: asset)
                sizeText = bytes > 0 ? Fmt.bytes(bytes) : nil
            }
        }
    }

    /// Shown when the original lives in iCloud and we're on a metered connection.
    private var waitingForWiFi: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Waiting for Wi-Fi")
                .font(.headline)
            Text("This one is only in iCloud. Downloading it now would use cellular data.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Button("Download anyway") { forceDownload = true }
                .buttonStyle(.borderedProminent)
                .tint(Color.keepGreen)
                .padding(.top, 2)
        }
    }

    private func downloadRing(_ value: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.02, value))
                .stroke(Color.keepGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(width: 58, height: 58)
        .animation(.easeOut(duration: 0.2), value: value)
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if asset.mediaType == .video {
                Image(systemName: "play.circle.fill")
                Text(Fmt.duration(asset.duration))
                Text("·")
            }
            Text(asset.creationDate.map { Fmt.date.string(from: $0) } ?? "No date")
            if let sizeText {
                Text("·")
                Text(sizeText)
            }
            if asset.isFavorite {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 44)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

@MainActor
struct ThumbView: View {
    let asset: PHAsset
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.cardSurface
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: asset.localIdentifier) {
                let side = max(geo.size.width, geo.size.height) * displayScale
                image = await ImageStore.shared.image(for: asset, size: CGSize(width: side, height: side))
            }
        }
    }
}
