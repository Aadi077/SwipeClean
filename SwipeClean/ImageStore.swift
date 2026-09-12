import Photos
import UIKit

/// Loads and caches card-sized renditions, and warms up the next few cards so
/// swiping never waits on disk or iCloud.
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    private var cachedWindow: [PHAsset] = []
    private let lock = NSLock()

    private init() {
        cache.countLimit = 60
        manager.allowsCachingHighQualityImages = false
    }

    func image(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let key = "\(asset.localIdentifier)@\(Int(size.width))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: UIImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true   // pull originals down from iCloud
            var finished = false

            self.manager.requestImage(for: asset,
                                      targetSize: size,
                                      contentMode: .aspectFit,
                                      options: options) { result, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
        }

        if let image { cache.setObject(image, forKey: key) }
        return image
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
        manager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFit, options: nil)
    }

    func byteSize(of asset: PHAsset) async -> Int64 {
        await Task.detached(priority: .utility) { AssetSize.bytes(of: asset) }.value
    }
}
