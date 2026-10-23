import Testing
@testable import DustBar

private func category(_ id: String, _ items: [(String, UInt64)]) -> CleanCategory {
    CleanCategory(
        id: id, title: id, detail: "", defaultSelected: false,
        items: items.map { CleanItem(path: $0.0, bytes: $0.1) }
    )
}

@Test func triStateReflectsSelection() {
    let c = category("caches", [("/a", 1), ("/b", 2)])
    #expect(CleanSelection.state(of: c, selected: []) == .none)
    #expect(CleanSelection.state(of: c, selected: ["/a"]) == .some)
    #expect(CleanSelection.state(of: c, selected: ["/a", "/b"]) == .all)
    #expect(CleanSelection.state(of: category("empty", []), selected: []) == .none)
}

@Test func toggleCategorySelectsThenClears() {
    let c = category("caches", [("/a", 1), ("/b", 2)])
    var selected: Set<String> = ["/a"]
    CleanSelection.toggle(c, selected: &selected)
    #expect(selected == ["/a", "/b"])
    CleanSelection.toggle(c, selected: &selected)
    #expect(selected.isEmpty)
}

@Test func toggleItemFlipsOnlyThatPath() {
    let item = CleanItem(path: "/a", bytes: 1)
    var selected: Set<String> = ["/b"]
    CleanSelection.toggle(item, selected: &selected)
    #expect(selected == ["/a", "/b"])
    CleanSelection.toggle(item, selected: &selected)
    #expect(selected == ["/b"])
}

@Test func selectedBytesAndResolveDedupeAcrossCategories() {
    let cats = [
        category("caches", [("/a", 10), ("/b", 20)]),
        category("trash", [("/b", 20), ("/c", 5)]),
    ]
    let selected: Set<String> = ["/a", "/b", "/c"]
    let items = CleanSelection.resolve(cats, selected: selected)
    #expect(items.map(\.path) == ["/a", "/b", "/c"])
    #expect(CleanSelection.selectedBytes(cats, selected: selected) == 35)
    #expect(CleanSelection.selectedBytes(cats, selected: ["/c"]) == 5)
    #expect(CleanSelection.resolve(cats, selected: []).isEmpty)
}

@Test func abbreviateReplacesHomePrefixOnly() {
    let home = "/Users/me"
    #expect(CleanSelection.abbreviate("/Users/me/Library/Caches", home: home) == "~/Library/Caches")
    #expect(CleanSelection.abbreviate("/Users/me", home: home) == "~")
    #expect(CleanSelection.abbreviate("/Users/mexico/x", home: home) == "/Users/mexico/x")
    #expect(CleanSelection.abbreviate("/opt/x", home: home) == "/opt/x")
    #expect(CleanSelection.abbreviate("/Users/me/x", home: "") == "/Users/me/x")
}

@Test func summarySaysMovedToTrash() {
    let result = CleanResult(
        trashed: [CleanItem(path: "/a", bytes: 1024)],
        refused: [CleanItem(path: "/System", bytes: 1)],
        failed: [(CleanItem(path: "/b", bytes: 1), "busy")]
    )
    let text = CleanSelection.summary(result)
    #expect(text.hasPrefix("Moved "))
    #expect(text.contains(" to Trash · "))
    #expect(!text.contains("Freed"))
    #expect(text.hasSuffix("· 1 refused · 1 failed"))
}

@Test func summaryPermanentWording() {
    let result = CleanResult(trashed: [CleanItem(path: "/a", bytes: 1024)])
    let text = CleanSelection.summary(result, permanent: true)
    #expect(text.hasPrefix("Permanently deleted "))
    #expect(!text.contains("Moved"))
}

@Test func planSplitsTrashFromRest() {
    let cats = [
        category("caches", [("/a", 10), ("/b", 20)]),
        category("trash", [("/t1", 7), ("/t2", 9)]),
    ]
    let plan = CleanSelection.plan(cats, selected: ["/a", "/t1", "/t2"])
    #expect(plan.rest.map(\.path) == ["/a"])
    #expect(plan.restBytes == 10)
    #expect(plan.trash.map(\.path) == ["/t1", "/t2"])
    #expect(plan.trashBytes == 16)
}

@Test func planTrashOnlyLeavesRestEmpty() {
    let cats = [category("caches", [("/a", 10)]), category("trash", [("/t1", 7)])]
    let plan = CleanSelection.plan(cats, selected: ["/t1"])
    #expect(plan.rest.isEmpty)
    #expect(plan.trash.map(\.path) == ["/t1"])
}

@Test func planPathInBothGoesPermanentOnly() {
    let cats = [category("caches", [("/b", 20)]), category("trash", [("/b", 20)])]
    let plan = CleanSelection.plan(cats, selected: ["/b"])
    #expect(plan.rest.isEmpty)
    #expect(plan.trash.map(\.path) == ["/b"])
}

@Test func planEmptySelection() {
    let cats = [category("caches", [("/a", 1)]), category("trash", [("/t", 1)])]
    let plan = CleanSelection.plan(cats, selected: [])
    #expect(plan.rest.isEmpty && plan.trash.isEmpty)
    #expect(plan.restBytes == 0 && plan.trashBytes == 0)
}

@Test func listedCapsAtLimitBySizeDesc() {
    let items = (0..<250).map { CleanItem(path: "/p\($0)", bytes: UInt64($0)) }
    let c = CleanCategory(id: "big", title: "big", detail: "", defaultSelected: false, items: items)
    let listed = CleanSelection.listed(c)
    #expect(listed.shown.count == CleanSelection.listLimit)
    #expect(listed.hidden == 150)
    #expect(listed.shown.first?.bytes == 249)
    #expect(listed.shown.last?.bytes == 150)
    let small = CleanSelection.listed(category("s", [("/a", 1), ("/b", 2)]))
    #expect(small.shown.map(\.path) == ["/b", "/a"])
    #expect(small.hidden == 0)
}
