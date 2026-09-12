import AVFoundation
import Photos
import SwiftUI
import UIKit

/// A bare AVPlayerLayer — no transport controls, since the card itself is the
/// control surface and chrome would fight the swipe gestures.
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

extension ImageStore {
    /// Gated on the same Wi-Fi rule as stills: a video original is the most
    /// expensive thing in the library to pull down.
    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = networkAllowed(force: false)
            var finished = false

            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: item)
            }
        }
    }
}
