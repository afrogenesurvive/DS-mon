# Changelog

## [0.2.3-1] — 2026-08-27

### Added

- **OpenAI / Anthropic (Claude) 月度费用与 token 用量**：通过各提供商的管理密钥拉取本月费用与 token 用量（输入 / 输出 / 缓存）。
- **AWS 计费与抵扣**：AWS 标签页新增本月费用、EC2 费用、已用抵扣额度与月末费用预测。
- **提供商标签页**：弹窗顶部改为独立标签行（样式与 Usage/License 等标签一致），替代原下拉菜单。
- **导出 / 导入配置**：底部新增按钮，可将全部设置与 API 密钥导出为 JSON 备份，并支持导入恢复。

### Changed

- 底部操作栏改为图标按钮（悬停显示提示），固定弹窗宽度下不再换行、不再出现右侧空白。
- 账户区对费用型提供商（OpenAI / Anthropic）显示「本月费用」与 token 用量行。

### Fixed

- 弹窗布局：修复底部按钮溢出换行与右侧空白间隙。

## [0.2.2-1] — 2026-08-25

### Added

- **Collapsible sections** in the popover — click any section header to collapse/expand it:
  - **Account**: balance, topped-up/granted amounts, and the alert/info lines (threshold, default model, account status, pricing window, error).
  - **Total Usage** stats: requests, total tokens, cache hit, reasoning tokens, est. cost, response time.
  - **Request history**: the chart ↔ list view.
  - **Source Usage**: the graph ↔ list view, in both aggregate and individual modes.
- **DeepSeek peak/off-peak pricing**: the popover shows the current pricing window (peak vs off-peak), and an optional system notification fires on each window transition (off by default).

### Changed

- Popover content now scrolls when it exceeds 550 pt instead of being crammed into a fixed height.
- More top/bottom padding in the popover container; the License tab content is now inset from the container edges.
- Collapsible section headers highlight on hover to make them obviously clickable.

### Fixed

- Release builds no longer lose UI strings: `scripts/build.sh` builds with `-Onone` to work around a Swift 6.3.3 `-O` (whole-module) bug that silently stripped `Strings.swift` literals (empty section titles / missing labels).

## [0.2.1-1] — 2026-08-21

### Added

- **Provider id (`pid`) column** in the Source Usage lists:
  - Individual list: new `pid` column after the source column, showing each request's provider id (`deepseek` / `kimi` / `openai` / `anthropic`).
  - Aggregate list: new `pid` column showing the providers a source used, comma-joined (e.g. `deepseek,openai`).
  - Both columns are sortable — click the header to toggle ascending/descending.
- JSON usage export now includes provider ids: the per-source (`bySource`) entries report the providers each source used (`providerIds`); raw records already carried `providerId` and the per-provider section already carried it.

### Changed

- Source Usage aggregate list columns rebalanced to fit the new `pid` column.
- Balance/credit refresh is now provider-aware: it uses each provider's own authentication scheme. OpenAI and Anthropic have no public balance API, so they continue to show "—".

## [0.2.0-2] — 2026-08-21

### Changed

- Key/license expiry is now shown as a remaining-time countdown in `dd:hh:mm:ss` format (e.g. `03:14:22:05`) in both the Settings → License seat rows and the popover License tab, instead of an absolute calendar date. Unlimited seats (`exp = 0`) show `不限/Unlimited`; already-expired seats show `已过期/Expired`.

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
