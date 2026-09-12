import Photos
import UIKit

enum ImageLoad {
    case image(UIImage)
    /// The original only exists in iCloud and we deliberately withheld the download.
    case needsNetwork
    case failed
}

/// Loads and caches card-sized renditions, and warms up the next few cards so
/// swiping never waits on disk or iCloud.
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    private var cachedWindow: [PHAsset] = []
    private let lock = NSLock()

    private let settingsLock = NSLock()
    private var cellularAllowed = false

    private init() {
        cache.countLimit = 60
        manager.allowsCachingHighQualityImages = false
    }

    /// Off by default: a big iCloud library would otherwise quietly eat a data plan.
    var allowsCellular: Bool {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return cellularAllowed
        }
        set {
            settingsLock.lock()
            cellularAllowed = newValue
            settingsLock.unlock()
        }
    }

    /// Whether we'll reach out to iCloud right now for this load.
    func networkAllowed(force: Bool) -> Bool {
        force || allowsCellular || !NetworkMonitor.shared.isMetered
    }

    func load(for asset: PHAsset,
              size: CGSize,
              force: Bool = false,
              onProgress: (@Sendable (Double) -> Void)? = nil) async -> ImageLoad {
        let key = "\(asset.localIdentifier)@\(Int(size.width))" as NSString
        if let cached = cache.object(forKey: key) { return .image(cached) }

        let allowNetwork = networkAllowed(force: force)

        let outcome: ImageLoad = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowNetwork
            if let onProgress {
                options.progressHandler = { progress, _, _, _ in onProgress(progress) }
            }
            var finished = false

            self.manager.requestImage(for: asset,
                                      targetSize: size,
                                      contentMode: .aspectFit,
                                      options: options) { result, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !finished else { return }
                finished = true

                if let result {
                    continuation.resume(returning: .image(result))
                    return
                }
                // Nil result plus this flag means "it's in the cloud and you told
                // me not to fetch it" rather than a genuine failure.
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.resume(returning: inCloud && !allowNetwork ? .needsNetwork : .failed)
            }
        }

        if case .image(let image) = outcome {
            cache.setObject(image, forKey: key)
        }
        return outcome
    }

    /// Convenience for thumbnails, where a missing image just renders as blank.
    func image(for asset: PHAsset, size: CGSize) async -> UIImage? {
        if case .image(let image) = await load(for: asset, size: size) { return image }
        return nil
    }

    func prefetch(_ assets: [PHAsset], size: CGSize) {
        lock.lock()
        let previous = cachedWindow
        cachedWindow = assets
        lock.unlock()

        let stale = previous.filter { old in !assets.contains(where: { $0.localIdentifier == old.localIdentifier }) }
        if !stale.isEmpty {
            manager.stopCachingImages(for: stale, targetSize: size, contentMode: .aspectFit, options: nil)
        }

        // Prefetching is a nicety; never let it spend cellular data.
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = networkAllowed(force: false)
        manager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFit, options: options)
    }

    /// Card captions go through here, which quietly warms the shared index.
    func byteSize(of asset: PHAsset) async -> Int64 {
        if let known = SizeIndex.shared.size(for: asset.localIdentifier) { return known }
        let bytes = await Task.detached(priority: .utility) { AssetSize.bytes(of: asset) }.value
        SizeIndex.shared.merge([asset.localIdentifier: bytes])
        return bytes
    }
}
