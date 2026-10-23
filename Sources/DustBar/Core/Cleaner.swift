import Foundation

// Slice C owns this file. Trash only, never unlink.
public enum Cleaner {
    public static func trash(_ items: [CleanItem]) -> CleanResult { CleanResult() }
}
