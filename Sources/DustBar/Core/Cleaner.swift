import Foundation

// Slice C owns this file. Trash only, never unlink, except emptyTrash, which removes direct children of ~/.Trash.
public enum Cleaner {
    /// Production entry point: real home, no extra roots.
    public static func trash(_ items: [CleanItem]) -> CleanResult {
        trash(items, home: NSHomeDirectory(), extraRoots: [])
    }

    /// Re-checks the denylist per item, then acts on the same resolved path it checked. Moves to the Trash via trashItem only.
    /// `extraRoots` exists for tests; production never passes any.
    public static func trash(_ items: [CleanItem], home: String, extraRoots: [String]) -> CleanResult {
        var result = CleanResult()
        let fm = FileManager.default
        for item in items {
            guard let c = Rules.resolvedChild(item.path), !Rules.isDenied(c.path, home: home, roots: extraRoots) else {
                result.refused.append(item)
                continue
            }
            // isDenied also resolves the final component, so a symlink is refused when its target is denied.
            var st = stat()
            guard lstat(c.path, &st) == 0 else {
                result.failed.append((item, String(cString: strerror(errno))))
                continue
            }
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: c.path), resultingItemURL: &resultingURL)
                result.trashed.append(item)
            } catch {
                result.failed.append((item, error.localizedDescription))
            }
        }
        return result
    }

    /// Permanently removes items that are direct children of the physical ~/.Trash. Anything else is refused.
    /// Symlinks are unlinked, never followed. Removed items are reported in `trashed`.
    public static func emptyTrash(_ items: [CleanItem], home: String = NSHomeDirectory()) -> CleanResult {
        var result = CleanResult()
        let fm = FileManager.default
        let trashDir = Rules.physical(home + "/.Trash")
        for item in items {
            guard let c = Rules.resolvedChild(item.path), c.dir == trashDir, !Rules.isDenied(c.path, home: home) else {
                result.refused.append(item)
                continue
            }
            var st = stat()
            guard lstat(c.path, &st) == 0 else {
                result.failed.append((item, String(cString: strerror(errno))))
                continue
            }
            var failure: String?
            if (st.st_mode & S_IFMT) == S_IFDIR {
                do { try fm.removeItem(atPath: c.path) } catch { failure = error.localizedDescription }
            } else if unlink(c.path) != 0 {
                failure = String(cString: strerror(errno))
            }
            if let failure {
                result.failed.append((item, failure))
            } else {
                result.trashed.append(item)
            }
        }
        return result
    }
}
