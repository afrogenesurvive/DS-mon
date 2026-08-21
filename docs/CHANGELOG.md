# Changelog

## [0.2.0-1] — 2026-08-21

### Added

- License seats are now read-only (manual add / revoke / delete removed); the list mirrors the source `seats.json`.
- Auto-check for license seats: new "Auto-check interval (h)" setting in Settings → License (default 6 h) re-imports `seats.json` periodically, in addition to the manual "Check Licenses" button.
- The popover License tab now has **Valid / Revoked / Expired** sub-tabs.
- New **Export** action (popover action bar): saves a verbose JSON via the file picker with DeepSeek + other provider usage across today/week/month/all-time, daily/weekly/monthly aggregates, breakdowns, per-source usage, and every raw record.
- Show/hide (eye) toggles added to the provider API key fields and the AWS Secret Key field.

### Changed

- App bundle name and version now derive from the current git branch (e.g. branch `0.2.0` → `dev_mon-0.2.0.app`).
- Export button moved to the popover action bar for visibility.

### Fixed

- Popover License tab "Check Licenses" button no longer emits an unused-result warning.

## [main-6] — 2026-08-05

### Added

- **Source Usage section** in the DeepSeek tab popover, switchable with the existing **Total Usage** view (renamed from "Usage Stats").
  - Aggregate / Individual display modes.
  - Filter by source (menu) and time period (Today / Week / Month), with a graph ↔ list toggle.
  - Aggregate shows per-source rows (requests, tokens, cost, last-seen `dd:MM:yyyy HH:mm`); individual shows per-request rows (time, source, model, tokens, status).
  - Local (empty `sourceIP`) usage is labeled "local"/本机 and included as its own row in the aggregate, so remote machine usage is compared against the host's own.
- **Sortable columns** in the Total Usage, Source Usage aggregate, and Source Usage individual lists (click a header to toggle ascending/descending).
- Loading spinner and debounced refresh (1s) for the individual list.

### Changed

- Popover width increased 290 → 334 to give the tables breathing room.
- Individual list time format is now `dd:MM:yyyy HH:mm`.
- Individual list now balances **per source** (50 records/source) so a high-volume source (e.g. local) can't hide others.
- Added `(source_ip, timestamp)` index on `usage_log` for faster per-source queries.

### Fixed

- Individual list no longer drops sources that appear in the aggregate (was loading only the 2000 newest records globally, which the local traffic flood filled).
- Individual list no longer hangs while loading (indexed queries + debounced reloads).

## [main-5] — 2026-08-04

### Added

- **Push-token auth for `/sync/push`**: new "Push Token" field in Settings → Services → Data Sync. Token is stored encrypted via SecureStore (with `DSMON_PUSH_TOKEN` env var fallback) and can be generated (256-bit via `SecRandomCopyBytes`), revealed, or copied from the UI.
- When a push token is configured, `POST /sync/push` now requires `Authorization: Bearer <token>` — missing/mismatched tokens return `401 {"error":"unauthorized"}` and records are not inserted. Comparison is constant-time (CryptoKit SHA-256 + byte XOR) to avoid timing/length side channels.
- Client-mode sync pushes now send the same bearer token, so DS-mon↔DS-mon sync keeps working against a server that enforces a token.

### Changed

- No token configured → `/sync/push` remains open (backward compatible). The "Usage by Source" aggregation is unaffected.

## [main-4] — 2026-07-27

### Fixed

- Fixed GitHub Actions tracking showing "User or organization not found" error on Free plan accounts. The billing API returns 404 for free accounts; now handled gracefully by falling back to default free-tier values (2000 min, 500 MB storage) with no error shown.

## [main-3] — 2026-07-26

### Fixed

- Fixed action bar (Settings/Quit) being pushed off-screen by restructuring popover into tab-based UI (DeepSeek / GitHub / AWS tabs).
- Fixed missing API keys after bundle ID rename by adding SecureStore key migration (`~/.ds-mon/` → `~/.dev-mon/`) with fallback decryption, and UserDefaults migration from old `com.dsmon.app` domain to new `com.devmon.app` domain.

### Changed

- Popover now uses tab bar navigation instead of stacked sections.
- Increased popover height from 500 → 540 to accommodate tabs.

## [main-2] — 2026-07-26

### Changed

- Renamed app from DS-mon to dev_mon across all source files, build scripts, docs, and CI.
- Reorganized source directory from `Sources/DS-mon/` to `Sources/dev_mon/`.

### Added

- **GitHub Actions tracking**: New `GitHubUsageTracker` polls Billing API for compute minutes and storage usage against free tier limits. Configurable via Services settings with Personal Access Token.
- **AWS EC2 Free Tier tracking**: New `AWSUsageTracker` + `SigV4Signer` polls EC2 DescribeInstances API to track running hours, instance eligibility, and forecast month-end usage. Configurable via Services settings with AWS credentials.
- New `ProgressBar` reusable UI component for progress visualization.
- Cloud usage sections in popover with color-coded status indicators.

## [main-1] — 2026-07-26

### Fixed

- Fixed build error by adding missing `sourceIP` parameter to `UsageRecord` initializer calls in `UsageLogger.swift`.
- Renamed DS-mon to dev_mon.
- Added GitHub Actions & AWS EC2 free tier tracking.
