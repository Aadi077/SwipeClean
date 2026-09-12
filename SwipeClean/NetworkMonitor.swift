import Foundation
import Network

/// Tells us whether the current path costs money. `isExpensive` covers cellular
/// and personal hotspots; `isConstrained` is Low Data Mode.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.aadi.SwipeClean.network")
    private let lock = NSLock()
    private var expensive = false
    private var constrained = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.expensive = path.isExpensive
            self.constrained = path.isConstrained
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// True when pulling a full-resolution original would spend the user's data.
    var isMetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive || constrained
    }
}
