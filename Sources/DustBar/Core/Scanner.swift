import Foundation

// Slice A owns this file.
public enum Scanner {
    /// Walks `root` (single device), builds a pruned DiskTree (files < 1 MB folded into an "other" child per dir).
    public static func scan(root: String, progress: @escaping @Sendable (ScanProgress) -> Void) async -> DiskTree {
        DiskTree(rootPath: root)
    }
}
