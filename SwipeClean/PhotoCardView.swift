import Photos
import SwiftUI

/// The rounded, shadowed card shell. Kept separate so the stacked cards behind
/// the top one get exactly the same look.
@MainActor
struct CardFrame: View {
    let asset: PHAsset
    let size: CGSize
    let fit: Bool

    var body: some View {
        PhotoCardView(asset: asset, fit: fit)
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

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var sizeText: String?

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
                } else {
                    ProgressView().tint(.white.opacity(0.35))
                }

                caption.frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.18), value: image)
            .task(id: asset.localIdentifier) {
                let pixels = CGSize(width: geo.size.width * displayScale,
                                    height: geo.size.height * displayScale)
                image = await ImageStore.shared.image(for: asset, size: pixels)
            }
            .task(id: asset.localIdentifier) {
                let bytes = await ImageStore.shared.byteSize(of: asset)
                sizeText = bytes > 0 ? Fmt.bytes(bytes) : nil
            }
        }
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
