import Foundation

// Slice B owns this file.
public final class Monitor: @unchecked Sendable {
    /// onStats: every 60 s. onDirty: batched changed directory paths from FSEvents (30 s latency).
    public init(root: String, onStats: @escaping @Sendable (VolumeStats) -> Void, onDirty: @escaping @Sendable (Set<String>) -> Void) {}
    public func start() {}
    public func stop() {}
    public static func currentStats(path: String = "/") -> VolumeStats { VolumeStats() }
}
