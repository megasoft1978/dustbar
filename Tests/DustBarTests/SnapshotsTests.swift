import Foundation
import Testing
@testable import DustBar

/// Fake tmutil: records each call and returns a canned result. Never starts a process.
final class FakeTmutil {
    let status: Int32
    let output: String
    private(set) var calls: [(exe: String, args: [String])] = []

    init(status: Int32 = 0, output: String = "") {
        self.status = status
        self.output = output
    }

    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        calls.append((exe, args))
        return (status, output)
    }
}

@Suite struct SnapshotsTests {
    private let listing = """
    Snapshots for disk /:
    com.apple.TimeMachine.2024-01-03-120000.local
    com.apple.TimeMachine.2024-01-01-000000.local
    com.apple.TimeMachine.2024-01-02-093015.local
    """

    @Test func listParsesAndSortsOldestFirst() {
        let fake = FakeTmutil(output: listing)
        let snaps = Snapshots.list(run: fake.run)
        #expect(snaps.map(\.date) == ["2024-01-01-000000", "2024-01-02-093015", "2024-01-03-120000"])
        #expect(fake.calls.count == 1)
        #expect(fake.calls.first?.exe == "/usr/bin/tmutil")
        #expect(fake.calls.first?.args == ["listlocalsnapshots", "/"])
    }

    @Test func listAcceptsNameWithoutLocalSuffix() {
        let out = "com.apple.TimeMachine.2024-05-06-070809\n"
        #expect(Snapshots.list(run: FakeTmutil(output: out).run).map(\.date) == ["2024-05-06-070809"])
    }

    @Test func listIgnoresInjectedAndMalformedLines() {
        let out = """
        Snapshots for disk /:
        com.apple.TimeMachine.2024-01-01-000000; rm -rf /.local
        com.apple.TimeMachine.2024-01-01-000000.local; rm -rf /
        com.apple.TimeMachine.2024-01-01-000000 && rm -rf ~
        com.apple.TimeMachine.$(rm -rf /).local
        com.apple.TimeMachine.2024-13-01-000000.local
        com.apple.TimeMachine.2024-01-01-0000000.local
        com.apple.TimeMachine.\u{0662}\u{0660}\u{0662}\u{0664}-01-01-000000.local
        ../../etc/passwd
        com.apple.TimeMachine.2024-01-01-000000.local
        """
        let snaps = Snapshots.list(run: FakeTmutil(output: out).run)
        #expect(snaps.map(\.date) == ["2024-01-01-000000"])
    }

    @Test func listReturnsEmptyOnTmutilFailure() {
        let fake = FakeTmutil(status: 1, output: listing)
        #expect(Snapshots.list(run: fake.run).isEmpty)
        #expect(Snapshots.list(run: FakeTmutil(output: "Snapshots for disk /:\n").run).isEmpty)
    }

    @Test func initAcceptsOnlyTheExactStampShape() {
        #expect(LocalSnapshot(date: "2024-01-01-000000") != nil)
        #expect(LocalSnapshot(date: "2024-12-31-235959")?.date == "2024-12-31-235959")
        let bad = [
            "2024-01-01-000000; rm -rf /", "2024-01-01-000000 ", " 2024-01-01-000000", "2024-01-01-000000\n",
            "2024-01-01-000000\u{0}", "2024-01-01-000000 && rm -rf ~", "$(rm -rf /)", "`rm -rf /`",
            "2024-01-01-000000 -x", "-2024-01-01-000000", "--all", "../2024-01-01-000000", "2024/01/01-000000",
            "2024-01-01-00000", "2024-01-01-0000000", "2024-01-01T000000", "2024-1-01-000000",
            "\u{0662}024-01-01-000000", "2024-13-01-000000", "2024-02-30-000000", "0000-00-00-000000", "",
        ]
        for b in bad { #expect(LocalSnapshot(date: b) == nil, "\(b.debugDescription) should be rejected") }
    }

    @Test func deleteRunsTmutilWithValidatedDateOnly() {
        let fake = FakeTmutil(status: 0)
        let snap = LocalSnapshot(date: "2024-01-01-000000")!
        #expect(Snapshots.delete(snap, run: fake.run))
        #expect(fake.calls.count == 1)
        #expect(fake.calls.first?.exe == "/usr/bin/tmutil")
        #expect(fake.calls.first?.args == ["deletelocalsnapshots", "2024-01-01-000000"])
    }

    @Test func deleteReportsTmutilFailure() {
        let snap = LocalSnapshot(date: "2024-01-01-000000")!
        #expect(Snapshots.delete(snap, run: FakeTmutil(status: 1).run) == false)
    }

    @Test func injectionAttemptsNeverReachTmutil() {
        // Only validated snapshots can exist, so a rejected string can never be passed to delete.
        let fake = FakeTmutil(status: 0)
        for attempt in ["2024-01-01-000000; rm -rf /", "$(reboot)", "2024-01-01-000000 --all", "../../etc"] {
            if let snap = LocalSnapshot(date: attempt) { _ = Snapshots.delete(snap, run: fake.run) }
        }
        #expect(fake.calls.isEmpty)
    }

    @Test func summaryReportsCountAndRangeOnly() {
        let snaps = Snapshots.list(run: FakeTmutil(output: listing).run)
        #expect(Snapshots.summary(snaps) == "3 local snapshots, oldest 2024-01-01 00:00, newest 2024-01-03 12:00")
        #expect(Snapshots.summary(Array(snaps.prefix(1))) == "1 local snapshot, oldest 2024-01-01 00:00, newest 2024-01-01 00:00")
        #expect(Snapshots.summary([]) == "No local snapshots")
    }

    @Test func runTerminatesAHungProcess() {
        let t0 = Date()
        let r = Snapshots.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(r.0 == -1)
        #expect(Date().timeIntervalSince(t0) < 10)
        let ok = Snapshots.run("/bin/echo", ["hi"], timeout: 5)
        #expect(ok.0 == 0 && ok.1 == "hi\n")
    }
}
