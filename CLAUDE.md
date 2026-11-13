# HomeControl

macOS menu bar app (SwiftUI, `macos/`) plus a Python backend (`backend/`). See README.md.

## Versioning

`VERSION` holds `release.major.minor` (starts at 0.1.0). It is the single source of truth: build-app.sh puts it in
Info.plist, the backend reports it, and the in-app update checker compares it with `main`'s `VERSION` on GitHub.

- **Every small change or bug fix bumps the minor number** (0.1.0 → 0.1.1): run `scripts/bump-version.sh` in the same commit.
- `scripts/bump-version.sh major` for larger features (resets minor); `release` for a new release (resets both).
- The update checker only offers an update when `main` has a higher VERSION, so bump before pushing.

## Updating

Settings → Advanced and the menu bar show an Update button when GitHub's VERSION is newer. It runs
`scripts/update.sh` (git fetch, fast-forward merge, rebuild, relaunch). `config.json` and `.env` are untracked so pulls never conflict with them.
