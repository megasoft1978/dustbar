// Prints the CGWindowID of the DustBar demo popover (default) or its status item window (--status).
//   swift scripts/capture/winid.swift <ownerName> [--pid <pid>] [--status] [--bounds]
// Output: "<id>" or, with --bounds, "<id> <x> <y> <w> <h>" (points, global coordinates).
// Exit 0 = found, 1 = no match, 2 = bad arguments.
// The popover is the largest window of the owner at a normal window layer (the demo backdrop sits at the
// desktop level, which is excluded) with height > 300. Status items are drawn by WindowServer/MenuBarAgent,
// so --status normally finds nothing; the shell script treats that as "not capturable".
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard let owner = args.first, !owner.hasPrefix("--") else {
    FileHandle.standardError.write("usage: winid.swift <ownerName> [--pid N] [--status] [--bounds]\n".data(using: .utf8)!)
    exit(2)
}
args.removeFirst()
var wantStatus = false
var wantBounds = false
var pid: Int?
var i = 0
while i < args.count {
    switch args[i] {
    case "--status": wantStatus = true
    case "--bounds": wantBounds = true
    case "--pid":
        guard i + 1 < args.count, let p = Int(args[i + 1]) else { exit(2) }
        pid = p
        i += 1
    default:
        FileHandle.standardError.write("unknown option \(args[i])\n".data(using: .utf8)!)
        exit(2)
    }
    i += 1
}

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []

struct Hit { let id: Int; let x: Double; let y: Double; let w: Double; let h: Double }
var hits: [Hit] = []
for win in windows {
    guard let name = win[kCGWindowOwnerName as String] as? String,
          name.localizedCaseInsensitiveContains(owner),
          let id = win[kCGWindowNumber as String] as? Int,
          let layer = win[kCGWindowLayer as String] as? Int,
          let b = win[kCGWindowBounds as String] as? [String: Double] else { continue }
    if let pid, (win[kCGWindowOwnerPID as String] as? Int) != pid { continue }
    let hit = Hit(id: id, x: b["X"] ?? 0, y: b["Y"] ?? 0, w: b["Width"] ?? 0, h: b["Height"] ?? 0)
    if wantStatus {
        // Menu bar level (24/25) and bar height only.
        guard (layer == 24 || layer == 25), hit.h <= 40 else { continue }
    } else {
        // Normal popover layers; excludes the desktop-level demo backdrop (layer near Int32.min).
        guard layer > 0, layer < 1000, hit.h > 300 else { continue }
    }
    hits.append(hit)
}

guard let best = hits.max(by: { $0.w * $0.h < $1.w * $1.h }) else { exit(1) }
if wantBounds {
    print("\(best.id) \(Int(best.x)) \(Int(best.y)) \(Int(best.w)) \(Int(best.h))")
} else {
    print(best.id)
}
