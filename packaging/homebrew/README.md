# Homebrew cask (personal tap)

`Casks/dustbar.rb.template` is the source of truth. `scripts/release.sh` fills in the version and the DMG sha256 and writes `dist/dustbar.rb`.

Tap repo: `megasoft1978/homebrew-dustbar` (file `Casks/dustbar.rb`). Users install with:

    brew tap megasoft1978/dustbar && brew install --cask dustbar

Release flow:

1. `scripts/release.sh` builds `dist/DustBar-<ver>.zip`, `dist/DustBar-<ver>.dmg`, `dist/SHA256SUMS` and `dist/dustbar.rb`. It makes no network calls.
2. Publish the release assets (the script prints the exact `gh release create` command).
3. Copy `dist/dustbar.rb` to `Casks/dustbar.rb` in the tap repo, then commit and push there.

Notes:

- The DMG is not notarized. The cask's postflight clears `com.apple.quarantine`.
- `depends_on macos: :sequoia` means Sequoia or newer (Homebrew symbol semantics).
- The release repo is private. Anonymous `brew install` only works once the release assets are downloadable without auth (public repo or public asset host).
- Check the cask locally with a throwaway tap: `brew tap-new --no-git local/dustbar-test`, copy the file into its `Casks/`, then `brew style` and `brew audit --cask`.
