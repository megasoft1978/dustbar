import Foundation

// Slice C owns this file.
public enum Rules {
    public static func isDenied(_ path: String) -> Bool { true }
    public static func discover(home: String) async -> [CleanCategory] { [] }
}
