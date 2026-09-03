# Changelog

## [0.2.6-1] — 2026-09-03

### Added

- **Z.ai (GLM) 提供商**：新增第五家提供商 Z.ai —— OpenAI 兼容国际端点，覆盖 GLM 全系模型定价（glm-5.3 / 5.2 / 5.1 / 5 / 4.7 / 4.6 / 4.5 等，免费 Flash 模型计 0 价）。Z.ai 无公开余额/用量 API，作为「按月计费（spend-based）」提供商，其「本月已花费」由本地代理日志核算，并据此推导剩余额度。
- **Z.AI 接口选择**：设置 → 提供商 → Z.AI 新增「接口」分段选择 —— **Coding Plan**（默认，Z.AI for Copilot / GLM Coding Plan 订阅专用）或 **标准（按量付费）**，二者上游路径不同。
- **Coding Plan 配额 / 套餐用量**（选中 Z.ai 时）：弹窗账户区新增套餐用量块，展示套餐名、续费日期及各用量窗口（5 小时会话 / 7 天周窗口 / 月度联网搜索与阅读）与已用百分比；数据取自 Z.ai 内部（非官方）接口，明确标注「仅供参考」，查询失败静默降级，不影响主流程。
- **Z.ai 钱包余额**（可选行）：弹窗账户区展示 Z.ai 控制台钱包余额（内部非官方接口，仅供参考，失败静默隐藏）。
- **AWS 历史累计抵扣**：AWS 页新增「历史累计抵扣」—— 分页汇总 Cost Explorer 历史（约 13 个月，按约 12 个月窗口分页）内全部 Credit 记录（并单列 EC2 部分），且纳入用量导出。
- **AWS 抵扣总额（手动填写）+ 剩余抵扣**：AWS 无公开 API 查询剩余抵扣，设置 → 服务 → AWS 新增「抵扣总额」手填项，AWS 页据此显示「剩余抵扣 = 总额 − 本月已用抵扣」。
- **用量导出加入云用量快照**：导出的用量 JSON 新增 `cloud`（AWS + GitHub Actions）快照段，含免费套餐用量率、计费/抵扣与实例运行小时明细。

### Changed

- **EC2 免费套餐小时统计更准确**：仅统计*运行中*实例，且运行时长自本月 1 日零时起算（跨月常驻实例不再把上月时长计入本月），运行小时与月底预测保留一位小数。
- **代理路径归一化**：转发前先剥离客户端请求中可能自带的 API 前缀，再拼接当前提供商的 API 路径，避免 base URL 已带前缀时出现双重前缀导致上游 404（也便于把各提供商端点统一指向同一本地地址）。
- **剩余额度行标签**：按月计费提供商的「剩余」行使用正确的「剩余预算 / Remaining」标签（此前误用「余额」标签）。
- **构建脚本**：打包 .app 时一并复制 SPM 资源包（`dev_mon_dev_mon.bundle`），修复 Release 版通过 `Bundle.module` 访问 logo 等资源失效的问题。

## [0.2.5-1] — 2026-08-27

### Added

- **提供商商标 Logo**：弹窗顶部提供商标签行显示 DeepSeek / OpenAI / Anthropic / Kimi 官方商标（模板渲染、跟随选中态），资源缺失时自动回退到 SF Symbol 图标。
- **月度预算 / 剩余额度**：按月计费提供商（OpenAI / Anthropic）账户区新增「本月预算」「剩余预算」；优先读取提供商消费上限，未配置时可在设置中按提供商手填月度预算。
- **管理端用量分页**：OpenAI / Anthropic 管理端用量与费用报告支持游标分页拉取，并估算 Anthropic 当日未结清的 UTC 费用桶，月度费用显示更准确。
- **新 Claude 模型定价**：新增 Opus 5 / Sonnet 5 / Haiku 4.5 / Opus 4.6–4.8 / Sonnet 4.6 定价表。
- **请求列表增强**：总用量与来源用量列表支持按活跃提供商过滤，并展示逐条 token 用量。

### Changed

- **弹窗悬停提示**：标签页、提供商与底部操作栏按钮改用自定义悬停提示（此前系统 tooltip 在无边框弹出窗口中不显示）。
- **OpenAI 流式用量捕获**：代理自动为流式 Chat Completions 请求注入 `stream_options.include_usage`，使 OpenAI 流式请求也能记录逐条用量（此前需客户端显式开启）。

### Fixed

- 用量图表悬停 tooltip 不再拦截鼠标事件，可连续查看各时段数据。

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
