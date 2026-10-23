import Foundation
import Testing
@testable import DustBar

@Suite(.serialized) struct CleanerTests {
    private let realTrash = NSHomeDirectory() + "/.Trash"

    /// True when something exists at `path` (symlinks counted, not followed).
    private func present(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    @Test func trashesScratchFileIntoTrash() throws {
        let s = try Scratch()
        defer { s.cleanup() }

        let name = "dustbar-scratch-\(UUID().uuidString).txt"
        let path = try s.file(name, bytes: 1_024)
        let result = Cleaner.trash([CleanItem(path: path, bytes: 1_024)], home: s.root, extraRoots: [])

        let inTrash = realTrash + "/" + name
        defer { try? FileManager.default.removeItem(atPath: inTrash) }  // our own scratch file only
        #expect(result.trashed.count == 1)
        #expect(result.refused.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(!present(path))
        #expect(FileManager.default.fileExists(atPath: inTrash))
    }

    @Test func productionDefaultDoesNotWidenToTestRoots() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let path = try s.file("scratch/a.txt")
        let result = Cleaner.trash([CleanItem(path: path, bytes: 1)], home: "/Users/nobody-dustbar", extraRoots: [])
        #expect(result.refused.map(\.path) == [path])
        #expect(result.trashed.isEmpty)
        #expect(present(path))
    }

    @Test func refusesItemsAlreadyInTrash() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let old = try s.file(".Trash/old.dmg")
        let nested = try s.file(".Trash/folder/inner.bin")
        let items = [old, nested].map { CleanItem(path: $0, bytes: 1) }
        let result = Cleaner.trash(items, home: s.root, extraRoots: [])
        #expect(result.refused.map(\.path) == [old, nested])
        #expect(result.trashed.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(present(old))
        #expect(present(nested))
    }

    @Test func refusesDeniedPathsAndLeavesThemUntouched() throws {
        let s = try Scratch()
        defer { s.cleanup() }

        let keychain = try s.file("Library/Keychains/login.keychain-db")
        let app = try s.file("Foo.app/Contents/Info.plist")
        let desktop = try s.dir("Desktop")
        let link = try s.link("evil", to: "/System/Library")
        let keyLink = try s.link("keyslink", to: keychain)
        _ = try s.link("sysdir", to: "/System")
        let viaSysDir = s.root + "/sysdir/Library"  // parent resolves to /System
        let traversal = s.root + "/../../../../../../../../usr/bin/dustbar-no-such-file"
        let outside = "/opt/dustbar-no-such-dir/x"
        let items = [keychain, app, desktop, link, keyLink, viaSysDir, traversal, outside].map { CleanItem(path: $0, bytes: 1) }

        let result = Cleaner.trash(items, home: s.root, extraRoots: [])
        #expect(result.trashed.isEmpty)
        #expect(result.refused.map(\.path) == items.map(\.path))
        #expect(result.failed.isEmpty)
        #expect(present(keychain))
        #expect(present(app))
        #expect(present(desktop))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "/System/Library")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: keyLink)) == keychain)
    }

    @Test func reportsMissingItemAsFailed() throws {
        let s = try Scratch()
        defer { s.cleanup() }

        let missing = CleanItem(path: s.root + "/does-not-exist.bin", bytes: 10)
        let result = Cleaner.trash([missing], home: s.root, extraRoots: [])
        #expect(result.trashed.isEmpty)
        #expect(result.refused.isEmpty)
        #expect(result.failed.count == 1)
        #expect(result.failed.first?.0 == missing)
        #expect(!(result.failed.first?.1.isEmpty ?? true))
    }

    @Test func emptyTrashRemovesOnlyDirectChildren() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let keep = try s.file("Documents/keep.txt")
        let old = try s.file(".Trash/old.dmg")
        let folder = try s.dir(".Trash/folder")
        let inner = try s.file(".Trash/folder/inner.bin")
        let alias = try s.link(".Trash/alias", to: keep)

        let items = [old, folder, alias].map { CleanItem(path: $0, bytes: 1) }
        let result = Cleaner.emptyTrash(items, home: s.root)
        #expect(result.trashed.map(\.path) == [old, folder, alias])
        #expect(result.refused.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(!present(old))
        #expect(!present(folder))
        #expect(!present(inner))
        #expect(!present(alias))
        #expect(present(keep))
    }

    @Test func emptyTrashRefusesAnythingNotADirectTrashChild() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let keep = try s.file("Documents/keep.txt")
        let nested = try s.file(".Trash/folder/inner.bin")
        let items = [
            keep,                                                // outside ~/.Trash
            s.root + "/.Trash",                                  // the Trash itself
            nested,                                              // grandchild of ~/.Trash
            s.root + "/.Trash/folder/../../Documents/keep.txt",  // traversal out of ~/.Trash
        ]
        let result = Cleaner.emptyTrash(items.map { CleanItem(path: $0, bytes: 1) }, home: s.root)
        #expect(result.refused.map(\.path) == items)
        #expect(result.trashed.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(present(keep))
        #expect(present(nested))
    }

    @Test func emptyTrashRefusesRedirectedTrash() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        // Home is a child of the fixture root, so ~/.Trash -> <root>/elsewhere points outside home.
        let fakeHome = s.root + "/home"
        let target = try s.file("elsewhere/x.bin")
        _ = try s.link("home/.Trash", to: s.root + "/elsewhere")
        let result = Cleaner.emptyTrash([CleanItem(path: fakeHome + "/.Trash/x.bin", bytes: 1)], home: fakeHome)
        #expect(result.refused.count == 1)
        #expect(result.trashed.isEmpty)
        #expect(present(target))
    }

    @Test func emptyTrashReportsMissingAsFailed() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.dir(".Trash")
        let ghost = CleanItem(path: s.root + "/.Trash/ghost", bytes: 1)
        let result = Cleaner.emptyTrash([ghost], home: s.root)
        #expect(result.trashed.isEmpty)
        #expect(result.refused.isEmpty)
        #expect(result.failed.map(\.0) == [ghost])
    }

    @Test func emptyTrashRefusesSymlinkedTrash() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let fakeHome = s.root + "/home"
        let target = try s.file("elsewhere/x.bin")
        _ = try s.link("home/.Trash", to: s.root + "/elsewhere")
        // Even a home whose real target sits inside it is refused when ~/.Trash is a link.
        let inner = try s.file("home/real/y.bin")
        let result = Cleaner.emptyTrash([CleanItem(path: fakeHome + "/.Trash/x.bin", bytes: 1),
                                         CleanItem(path: fakeHome + "/real/y.bin", bytes: 1)], home: fakeHome)
        #expect(result.refused.count == 2)
        #expect(result.trashed.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(present(target))
        #expect(present(inner))
    }
}
