import Foundation
import Testing
@testable import DustBar

@Suite struct FileTypesTests {
    /// /r/videos: movie.mp4 (500), clip.MOV (200), "(small files)" (30); /r/pics: a.jpg (100), b.png (50);
    /// /r/old.mp4 is a directory (skipped, its file counts as other); /r/notes (7, no extension).
    private func fixture() -> DiskTree {
        let t = DiskTree(rootPath: "/r")
        let videos = t.add(name: "videos", parent: 0, isDir: true)
        t.add(name: "movie.mp4", parent: videos, isDir: false, size: 500)
        t.add(name: "clip.MOV", parent: videos, isDir: false, size: 200)
        t.add(name: "(small files)", parent: videos, isDir: false, size: 30)
        let pics = t.add(name: "pics", parent: 0, isDir: true)
        t.add(name: "a.jpg", parent: pics, isDir: false, size: 100)
        t.add(name: "b.png", parent: pics, isDir: false, size: 50)
        let dir = t.add(name: "old.mp4", parent: 0, isDir: true)
        t.add(name: "inner.bin", parent: dir, isDir: false, size: 11)
        t.add(name: "notes", parent: 0, isDir: false, size: 7)
        t.rollUp()
        return t
    }

    @Test func extensionsClassify() {
        #expect(FileTypes.kind(of: "a.MP4") == .video)
        #expect(FileTypes.kind(of: "x.tar.gz") == .archives)
        #expect(FileTypes.kind(of: "photo.HEIC") == .images)
        #expect(FileTypes.kind(of: "song.flac") == .audio)
        #expect(FileTypes.kind(of: "notes.md") == .documents)
        #expect(FileTypes.kind(of: "main.swift") == .code)
        #expect(FileTypes.kind(of: "App.pkg") == .apps)
        #expect(FileTypes.kind(of: "Setup.dmg") == .diskImages)
        #expect(FileTypes.kind(of: "README") == .other)
        #expect(FileTypes.kind(of: ".DS_Store") == .other)
        #expect(FileTypes.kind(of: "trailing.") == .other)
        #expect(FileTypes.kind(of: "(small files)") == .smallFiles)
    }

    @Test func extensionTableHasNoDuplicates() {
        let all = FileTypes.extensions.values.flatMap { $0 }
        #expect(Set(all).count == all.count)
    }

    @Test func slicesReconcileWithRootSize() {
        let t = fixture()
        let slices = FileTypes.breakdown(tree: t)
        #expect(slices.reduce(UInt64(0)) { $0 + $1.bytes } == t.size[0])
        #expect(t.size[0] == 898)
    }

    @Test func slicesAreNonEmptyAndSortedByBytes() {
        let slices = FileTypes.breakdown(tree: fixture())
        #expect(slices.map(\.kind) == [.video, .images, .smallFiles, .other])
        #expect(slices.map(\.bytes) == [700, 150, 30, 18])
        #expect(slices.allSatisfy { $0.bytes > 0 })
    }

    @Test func countsAndTopFilesPerKind() throws {
        let slices = FileTypes.breakdown(tree: fixture())
        let video = try #require(slices.first { $0.kind == .video })
        #expect(video.count == 2)
        #expect(video.top == [
            FileTypes.TypedFile(path: "/r/videos/movie.mp4", bytes: 500),
            FileTypes.TypedFile(path: "/r/videos/clip.MOV", bytes: 200),
        ])
        let other = try #require(slices.first { $0.kind == .other })
        #expect(other.count == 2)
        #expect(other.top.map(\.path) == ["/r/old.mp4/inner.bin", "/r/notes"])
    }

    @Test func smallFilesAreListedUnderTheirFolder() throws {
        let slices = FileTypes.breakdown(tree: fixture())
        let small = try #require(slices.first { $0.kind == .smallFiles })
        #expect(small.bytes == 30)
        #expect(small.count == 1)
        #expect(small.top == [FileTypes.TypedFile(path: "/r/videos", bytes: 30)])
    }

    @Test func topListIsCappedAtFive() throws {
        let t = DiskTree(rootPath: "/r")
        for i in 1...9 {
            t.add(name: "f\(i).zip", parent: 0, isDir: false, size: UInt64(i) * 10)
        }
        t.rollUp()
        let archives = try #require(FileTypes.breakdown(tree: t).first)
        #expect(archives.kind == .archives)
        #expect(archives.count == 9)
        #expect(archives.top.map(\.bytes) == [90, 80, 70, 60, 50])
        #expect(archives.bytes == 450)
    }

    @Test func emptyTreeGivesNoSlices() {
        #expect(FileTypes.breakdown(tree: DiskTree(rootPath: "/r")).isEmpty)
    }
}

@Test func countTextAgreesWithNoun() {
    #expect(TypesView.countText(1, folders: false) == "1 file")
    #expect(TypesView.countText(2, folders: false) == "2 files")
    #expect(TypesView.countText(0, folders: false) == "0 files")
    #expect(TypesView.countText(1, folders: true) == "1 folder")
    #expect(TypesView.countText(1_234, folders: true) == "1,234 folders")
}
