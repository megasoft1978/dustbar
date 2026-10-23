import Testing
@testable import DustBar

@Test func treeRollUp() {
    let t = DiskTree(rootPath: "/x")
    let d = t.add(name: "d", parent: 0, isDir: true)
    t.add(name: "f", parent: d, isDir: false, size: 10)
    t.rollUp()
    #expect(t.size[0] == 10)
    #expect(t.path(of: 2) == "/x/d/f")
}
