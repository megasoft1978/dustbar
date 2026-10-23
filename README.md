# DustBar

Tiny native macOS menu bar app: watches free disk space, shows what is using it, and cleans safely after review.

- Menu bar ring with free GB (amber below 15% free, red below 5%), low-disk notification.
- Popover tabs: Explore (animated sunburst while scanning, "Largest here" list, drill-down), Types (video/images/code/... breakdown), Growth (what grew since earlier scans), Clean.
- Clean tab: caches, Xcode, simulators, logs and crash reports, dev caches, stale `node_modules`, old Downloads, large files, duplicates, plus Time Machine local snapshots (separate, confirmed, permanent). Review each item before anything moves.
- Settings (⌘, from the menu bar item): alert threshold, excluded folders, scan scope (home or whole disk, browse-only), weekly cleanup reminder (never deletes anything).
- Cleanup moves items to the Trash (undoable). The only permanent delete is the separate, confirmed "Empty Trash", limited to direct children of `~/.Trash`.
- Protected paths (system, Library internals, Keychains, Mail, Photos, cloud storage, `~/.ssh`, `~/.aws`, `~/.gnupg`, app bundles, the home folder and its top-level folders) can never be cleaned.

## Build and install

```sh
bash scripts/bundle.sh          # build/DustBar.app (release, stripped, ad-hoc signed)
cp -R build/DustBar.app /Applications/
open /Applications/DustBar.app
```

Requires macOS 15+, Swift 6 toolchain. No third-party dependencies. Grant Full Disk Access (System Settings > Privacy & Security) for complete scans. Launch at Login: right-click the menu bar item.

## Tests

```sh
swift test                                   # unit tests
DUSTBAR_SCAN_BENCH=$HOME/Library swift test --filter ScanBenchTests   # scan benchmark
```

## Design notes

- Scanner: parallel `getattrlistbulk` walk (allocated size, hard links once, one device, symlinks not followed), post-order pruning so only directories above ~1 MB are kept (about 90k nodes for 8.6M files), live snapshots of the top 3 levels about once a second, readdir fallback on non-APFS volumes.
- The last tree is cached in `~/Library/Caches/com.megasoft78.dustbar/tree.bin` for an instant first view; a fresh scan always follows.
- Memory: about 16 MB idle, peak under 100 MB during a full-home scan, about 27 MB afterwards (`MallocSpaceEfficient` set through `LSEnvironment`). Binary about 1 MB.
- Opening the popover refreshes only changed folders when possible (about 140x faster than a full scan on `~/Library`), full rescan otherwise.
- `FSEvents` watches the home folder (30 s latency); statfs every 60 s. No other timers.
- Icon source: `design/AppIcon.svg`, rendered with `scripts/make-icon.sh`.
