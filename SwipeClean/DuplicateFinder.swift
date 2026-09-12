import Photos
import UIKit
import Vision

struct DuplicateGroup: Identifiable, Hashable {
    let id: String
    var memberIDs: [String]
}

struct DuplicateScan {
    var groups: [DuplicateGroup] = []
    /// How many photos we managed to feature-print, and how many we tried.
    var analyzed = 0
    var attempted = 0

    /// We had candidates but couldn't analyse a single one — reporting "no
    /// duplicates" here would be a lie.
    var didFail: Bool { attempted > 0 && analyzed == 0 }
}

/// Finds near-duplicates — bursts, retries, the eleven shots of the same sunset.
///
/// Built to be cheap by construction: candidates are clustered by capture time
/// first, so only photos taken within a minute of each other ever get
/// feature-printed. Printing an entire library would be unusable on device.
final class DuplicateFinder: @unchecked Sendable {
    static let shared = DuplicateFinder()
    private init() {}

    /// Photos taken within this many seconds of each other are candidates.
    static let clusterWindow: TimeInterval = 60

    /// Feature-print distance below which two photos count as near-duplicates.
    /// Measured against generated fixtures: frames of the same scene score
    /// 0.03-0.07, unrelated scenes 0.86-1.04. 0.3 sits well clear of both.
    static let similarityThreshold: Float = 0.3

    /// Guards against a pathological run (a long timelapse) turning into a
    /// quadratic comparison over hundreds of images.
    static let maxClusterSize = 40

    func findGroups(in assets: [PHAsset],
                    onProgress: @Sendable @escaping (Int, Int) -> Void) async -> DuplicateScan {
        let clusters = timeClusters(in: assets)
        let workTotal = clusters.reduce(0) { $0 + $1.count }
        var scan = DuplicateScan()
        guard workTotal > 0 else { return scan }

        var done = 0

        for cluster in clusters {
            if Task.isCancelled { return scan }

            var prints: [(id: String, print: VNFeaturePrintObservation)] = []
            for asset in cluster {
                if Task.isCancelled { return scan }
                scan.attempted += 1
                if let print = await featurePrint(for: asset) {
                    prints.append((asset.localIdentifier, print))
                    scan.analyzed += 1
                }
                done += 1
                onProgress(done, workTotal)
            }
            scan.groups.append(contentsOf: groupBySimilarity(prints))
        }

        // Biggest piles first — that's where the easy wins are.
        scan.groups.sort { $0.memberIDs.count > $1.memberIDs.count }
        return scan
    }

    /// The cheap pass: runs of photos taken close together in time.
    private func timeClusters(in assets: [PHAsset]) -> [[PHAsset]] {
        let dated = assets
            .compactMap { asset -> (asset: PHAsset, date: Date)? in
                guard let date = asset.creationDate else { return nil }
                return (asset, date)
            }
            .sorted { $0.date < $1.date }

        var clusters: [[PHAsset]] = []
        var run: [PHAsset] = []
        var previous: Date?

        for entry in dated {
            if let previous, entry.date.timeIntervalSince(previous) <= Self.clusterWindow {
                run.append(entry.asset)
            } else {
                if run.count > 1 { clusters.append(Array(run.prefix(Self.maxClusterSize))) }
                run = [entry.asset]
            }
            previous = entry.date
        }
        if run.count > 1 { clusters.append(Array(run.prefix(Self.maxClusterSize))) }

        return clusters
    }

    private func featurePrint(for asset: PHAsset) async -> VNFeaturePrintObservation? {
        // A small rendition is plenty: feature prints describe composition, not
        // detail, and this keeps memory flat across a long scan.
        let size = CGSize(width: 224, height: 224)
        guard let image = await ImageStore.shared.image(for: asset, size: size),
              let cgImage = image.cgImage else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Vision's feature extractor is unavailable in some environments —
            // the iOS Simulator can't create its espresso context, for one.
            return nil
        }
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// Union-find over one time cluster, so A~B and B~C land in a single group.
    private func groupBySimilarity(_ prints: [(id: String, print: VNFeaturePrintObservation)]) -> [DuplicateGroup] {
        guard prints.count > 1 else { return [] }

        var parent = Array(0..<prints.count)

        func root(_ start: Int) -> Int {
            var index = start
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        for i in 0..<prints.count {
            for j in (i + 1)..<prints.count {
                var distance = Float.greatestFiniteMagnitude
                try? prints[j].print.computeDistance(&distance, to: prints[i].print)
                guard distance < Self.similarityThreshold else { continue }
                let a = root(i), b = root(j)
                if a != b { parent[a] = b }
            }
        }

        var buckets: [Int: [String]] = [:]
        for index in prints.indices {
            buckets[root(index), default: []].append(prints[index].id)
        }

        return buckets.values
            .filter { $0.count > 1 }
            .map { DuplicateGroup(id: $0.sorted().joined(separator: "|"), memberIDs: $0) }
    }
}
