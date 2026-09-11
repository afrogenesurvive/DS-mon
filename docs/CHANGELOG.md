# Changelog

## [0.3.4-1] — 2026-09-11

### Added

- **菜单栏未读通知徽标**：只要存在未读通知，菜单栏项**内容最左侧（leading 槽位）**就显示一个**红底白字的未读数字胶囊**（超过 9 条显示 `9+`），图标 / 指示灯条 / 文字芯片整体右移让位。与 DeepSeek **高峰/低谷状态点**刻意区分：状态点在**文字右上角**、贴顶、**黄（高峰）/ 绿（低谷）**、带白色描边；未读徽标在**最左侧**、垂直居中、**红**底白字、**无**描边 —— 位置、颜色、描边三者都不同，两者同时显示也不会混淆。徽标尺寸/宽度算法集中在 `StatusBarView`（`unreadBadgeText` / `unreadBadgeWidth` / `unreadBadgeGutter`），`StatusBarController.applyLabel` 直接复用同一套计算预留 `statusItem` 宽度，避免绘制与布局两处漂移。

### Changed

- **菜单栏红点只在「通知页真的被查看」时清除**：除原有的「点击通知页签 → `markAllRead()`」外，新增 `popoverVisibilityDidChange` 弹窗可见性广播（`StatusBarController.togglePopover` / `closePopover` 发出，object 为 `NSNumber(Bool)`）—— 重新打开弹窗时若正好停在通知页，同样视为已读并立即清除红点。
- **修正潜在误标已读**：`NSHostingView` 在弹窗 `orderOut` 后依然存活、`.onReceive` 照常收货，所以「弹窗关闭但页签仍停在通知页」时新到的通知会被静默标记已读（红点永远不亮）。现在 `StatsPopoverView` 用 `popoverVisible` 门控：仅当弹窗可见且当前就在通知页时才自动已读。
- `StatsPopoverView` 中三处硬编码的通知页签索引 `5` 收敛为 `Self.alertsTabIndex`。
- **设置 → 许可改为多注册表结构**：席位现在按「注册表 ▸ 密钥环 ▸ 密钥」三级折叠浏览（展开状态持久化），弹窗许可页签的席位行补充**签发日期**与**注册表名称**，已过期席位单独用橙色标记。

## [0.3.3-1] — 2026-09-11

### Changed

- **「全部展开 / 全部收起」由两个图标改为一个状态感知图标**：作用域内还有区段收起时显示「全部展开」，全部展开后显示「全部收起」，点击把作用域内所有区段切到相反状态，tooltip 与图标同步变化（`SectionExpandControls(allExpanded:toggle:)`）。8 处调用点（Usage、GitHub、AWS、Netlify、Databases 本地、Databases 仓库、Settings 服务、Settings Provider）全部更新。
- **GitHub 页**：展开/收起按钮移到 **Actions / Repositories** 子页签行右侧（仅仓库子页签显示）；**仓库列表**与**仓库信息**（描述 / 可见性 / 创建时间）也纳入折叠范围 —— 一次点击同时收起/展开 仓库列表 + 仓库信息 + 提交 / 分支 / 发布。
- **AWS 页**：展开/收起按钮进入 **Overview / Instances** 子页签行（仅 Instances 显示）；**实例详情**变为可折叠区段（折叠时保留实例 ID / 名称 / 状态徽标标题行），一次点击同时切换实例列表与详情。
- **Netlify 页**：新增**独立的展开/收起按钮行**（位于团队名之上）；**项目信息**（站点名 / Live 徽标 / 动作按钮 / ID 与 URL）与**构建设置**（仅 git 关联站点）各自独立可折叠，加上原有的部署历史 —— 按钮一次性切换 站点列表 + 项目信息 + 构建设置 + 部署历史。
- **Cloudflare 页**：**公开主机名**列表改为与 AWS 实例 / Netlify 站点一致的**可搜索列表**（按主机名或本地服务过滤，✕ 清除，结果列表可折叠，每行保留复制 / 删除）。按需求**本页不添加全局展开/收起按钮**。
- **Settings → Provider**：每个提供商区段改为**可折叠**（标题为 `<提供商> API Key`），展开/收起按钮位于 **Provider** 标题行（**?** 按钮旁）；**Balance Alert** 区块保持常显。

### Added

- **UI 状态持久化（`UIStateStore` + `ui_state_prefs.json`）**：主页签 / 子页签选择、每个区段的折叠状态、图表 ↔ 列表模式（Usage 与 Source Usage）写入 `~/Library/Application Support/dev_mon/ui_state_prefs.json`（非隔离 + 锁 + `@unchecked Sendable`，300ms 防抖保存，退出时 `flush()` 立即落盘），**重启应用后保持一致**。设置窗口的页签与 8 个服务区段的折叠状态同样持久化 —— 此前每次重开设置窗口都会重置。本地数据库三个「库列表」的展开状态也一并持久化（进入页面时按需要补拉一次实时查询）。
- **导出/导入配置新增 `ui.*` 扁平化条目**：UI 状态随配置迁移（配置格式版本 1 → 2）。
- `SearchableSelector` 增强：展开状态改由调用方持有（可被「全部收起」作用到并持久化）、新增 `showsSelection: false`（非「选择一项」型列表）与 `accessory`（行尾复制/删除按钮与行按钮**平级**渲染，不会被行的点击吞掉）。

### Fixed

- **导出配置丢失 Data Sync 的全部设置**：`sync_enabled` / `sync_mode` / `sync_listen_port` / `sync_target_address` / `sync_interval` 这 5 个键从未真正写入 UserDefaults —— 同步配置整体存于 `sync_config` JSON blob，所以导出的配置里同步设置**永远是空的**、导入也恢复不了。现在直接导出 `sync_config`，导入后重新加载并按新配置重启同步。
- **导出配置遗漏**：补上 **许可检查来源**（`license_check_source`，seats.json 路径）、**弹窗缩放倍数**（`popover_ui_scale`，导入后窗口立即按新倍数调整大小）与**同步游标**（`lastPushTimestamp`，避免还原后重复推送历史）。
- **导出用量数据遗漏**：`cloud` 段此前只有 AWS 与 GitHub，现补上 **Cloudflare**（守护状态 / 隧道健康 / 公开主机名 / 私有 IP 路由）、**Netlify**（账户 / 站点 / 最近 10 条部署）、**本地数据库**（状态 / 运行时长 / 库数量 / 错误）与**仓库数据存储**（分组、类型 / 来源 / 相对路径 / 大小 / 敏感标记）快照；并新增按本地仓库聚合的 **`byRepo`** 段（来自 `usage_log.repo`）。用量格式版本 2 → 3（新增字段均为可选，旧文件仍可解析）。
- 底部操作栏导出按钮的 tooltip 由「导出」改为 **「导出数据 / Export Data」**，与「导出配置」区分。

### Notes

- `docs/ui-guide.md`、`docs/settings-guide.md` 已同步更新（`docs/` 除 CHANGELOG 外为本地文件，不入库）。

## [0.3.2-1] — 2026-09-10

### Added

- **「全部展开 / 全部收起」按钮**：所有含多个可折叠区段的页面都加了这两个图标按钮，一键展开或收起该页全部区段 ——
  - **Usage 页**（含 Account + 用量统计 + 请求历史 + 来源用量，覆盖两个子页签）：按钮位于 **Usage / Source Usage** 切换行右侧；
  - **GitHub → Repositories**：位于所选仓库详情的提交 / 分支 / 发布三个区段上方，作用于当前仓库；
  - **Databases → Local**：位于页头，一次性展开 / 收起每个服务的 **库列表**（复用原有的拉取逻辑，展开时会各发一次实时查询）；
  - **Databases → Repo**：位于页头，一次性展开 / 收起所有仓库分组（无分组时隐藏）；
  - **Settings → 服务**：位于页签顶部右侧，一次性展开 / 收起全部 8 个服务区段。
- **`SectionExpandControls`**：`CollapsibleSection.swift` 中新增的可复用按钮组（`iconSize` / `spacing` / `expand` / `collapse`），图标为 `rectangle.expand.vertical` / `rectangle.compress.vertical`，悬停高亮 + 本地化 tooltip；新增字符串 `sectionsExpandAll` / `sectionsCollapseAll`。

### Notes

- Netlify 页签只有一个可折叠区段（Deploys 列表），其表头本身即为开关，故未重复添加。

## [0.3.1-3] — 2026-09-10

### Added

- **集中式通知设置页（Settings → 通知）**：新增第七个设置页签，把所有可发出的通知做成一张**勾选列表** —— AWS 实例持续运行、余额预警、DeepSeek 高峰切换、Cloudflare 隧道断开、Netlify 部署通知、数据库状态、仓库服务状态。勾选即启用对应的 macOS 系统通知与铃铛条目；使用的是**同一批 UserDefaults 键**，因此与 General / Services 页里的行内开关双向同步（两处任意一处修改都会立即生效）。页内注明「通知历史仅保存在本次运行内存中」。
- **AWS 实例持续运行提醒**：实例连续运行超过 **30 分钟**时发出铃铛条目 + 系统通知，之后**每 30 分钟重复一次**（不必等下一个整点），实例停止后计时清零、下次启动重新武装。计时起点优先取 EC2 的 `launchTime`，并持久化到 UserDefaults（应用重启后继续计时，且不会被后续刷新覆盖成更短的时间）。阈值与重复间隔为同一常量（30 分钟）。新增 `AppAlertKind.awsInstanceLongRunning`（铃铛图标 `clock.badge.exclamationmark` / 橙色），并在 `AWSUsageTracker` 每次刷新实例后评估。可在设置页关闭。

### Changed

- **Services 设置页改为可折叠区段**：8 个服务（Proxy、GitHub、AWS、Cloudflare、Netlify、Local DBs、Repo Data Stores、Data Sync）各自成为一个可点击展开/收起的区段，解决该页过长的问题。**Proxy / Cloudflare / Data Sync 默认展开**（它们的状态需要一眼可见），其余默认收起。
- **`CollapsibleSection` 支持样式与附件**：新增 `iconSize` / `titleFont` / `horizontalPadding` / `showsDivider` / `accessory` 参数（全部带默认值，popover 原有调用不受影响）。设置窗口用更大的字号与 20pt 内边距；Proxy 区段把「运行中/已停止」状态放入标题栏附件，**折叠时依然可见**。
- **导出/导入配置**新增 `aws_instance_running_notification_enabled`（实例计时起点属运行时状态，不导出）。

## [0.3.1-2] — 2026-09-10

### Added

- **仓库数据存储（Repo Data Stores）**：Databases 页签内新增 **本地 / 仓库** 子页签，列出本地仓库自带的数据存储 —— SQLite 文件（含 WAL「使用中」标记）、Chroma 向量库、JSONL 队列（条目数 / 待处理数 / 缓冲区占用）与 JSON 状态文件，按仓库分组可折叠；每个仓库还显示其**自带服务**（如后端 5001、webhook 3199 / runner PID）的运行状态与时长。发现顺序为仓库根目录 **`devmon.json`（精确声明）→ `.env` 声明的路径 → 已知目录 / 文件名模式**。严格只读：只做 stat 与只读查询，**绝不写入仓库**，也**绝不读取** `config.json`、`.env` 的值或密钥目录内容。
- **`devmon.json`**：仓库可选的清单文件，声明 `stores`（kind / path / label / tables / sensitive / capBytes）与 `service`（port / pidFile / triggerFile）。已为 `ai_transcription_agent`（Ephemeral Memory、Voiceprints、Semantic Memory + 5001）与 `copilot_agentic_task_helper`（两个队列 JSONL、DS-mon 用量缓冲、Trello = system of record + 3199）添加。
- **存储计数**：SQLite 显示 `quick_check` 完整性、表数量与逐表行数（`events` 等队列表按 `status` 分组，failed / dlq 高亮为橙色）；默认**只显示总量**，「显示详细信息」开关开启后才展开表名；`sensitive` 存储（如 `voiceprints.db`）**永远只显示总量**，不显示表名或内容。
- **备份存储**：SQLite / Chroma 用 `VACUUM INTO` 生成一致性快照，其余按文件复制到 `~/Backups/dev_mon/<仓库>/`（不在仓库内写入任何文件）。
- **设置 → 服务 → Repo Data Stores**：启用开关、扫描目录、扫描深度、显示详细信息、包含外部系统、仓库服务状态通知、立即扫描，并注明「只读、不读密钥文件」。
- **AppAlertKind 新增 storeDegraded / storeRestored**：仓库自带服务停止 / 恢复时发系统通知 + 铃铛条目（默认开，带冷却与自触发抑制；弹窗铃铛图标与配色 switch 同步补齐）。
- **导出/导入配置**新增六个 Repo Data Stores 键（启用、通知、扫描目录、深度、显示详细信息、包含外部系统）。

### Fixed

- **MongoDB（及其它第三方 tap 数据库）无法停止 / 启动**：Homebrew 4.6+ 要求先信任第三方 tap，`brew services stop mongodb-community` 会以 `Refusing to load formula mongodb/brew/mongodb-community from untrusted tap mongodb/brew.` 失败——旧版只是把该错误截断显示，数据库其实仍在运行。现在该错误被**结构化识别**，行内显示完整原因与修复命令，并提供 **信任 Tap**（执行 `brew trust --formula <formula>`，失败则回退 `brew trust --tap <tap>`）与 **重试** 按钮自动续跑刚才失败的动作；另加 **复制** 按钮。dev_mon 不会自行改动 Homebrew 的信任状态。
- **找不到数据库命令行客户端（mongosh / mysql / cypher-shell）**：`ProcessRunner.which` 依赖继承的 PATH，而从 Finder / Dock 启动的 app 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，Homebrew 目录不在其中 → 客户端永远「未找到」并回退到磁盘列表。现在 `ProcessRunner` 为所有子进程把 Homebrew 目录**前置进 PATH**，并对每个客户端按**候选绝对路径**（`/opt/homebrew/bin`、`/opt/homebrew/opt/<keg>/bin`、`/usr/local/bin`）查找后再回退 `which`。
- **MongoDB 库列表显示引擎内部文件**：停止时会把数据目录里的任意子目录都当作数据库，于是出现 `diagnostic.data`、`journal` 之类的「库名」。现在按引擎规则过滤（跳过 `diagnostic.data`、`journal`、`WiredTiger*`、`_mdb_catalog.wt`、`sizeStorer.wt`、`mongod.lock`、`_`/`collection-`/`index-` 前缀），并把 `<name>.wt` 还原为库名。
- **MongoDB 运行中看不到库列表**：`mongosh --eval` 默认打印 JS 风格数组（`[ 'admin', 'config' ]`），JSON 解析必然失败 → 列表恒为空。改为 `JSON.stringify(...)` 并解析 JSON 数组（保留旧输出与字典形式的回退解析）。
- **错误信息被截断到 240 字符 / 3 行**，恰好切掉唯一可操作的 `brew trust …` 命令。现在保留完整文本（仅压缩空行、上限 600 字符），可选中复制，并附修复按钮。
- **停止成功与否不再靠猜**：`brew services stop` 返回 0 但进程仍在时会显示「仍在运行（stop 未生效）」并可重试，而不是无条件把状态置为已停止。

### Changed

- **探测逻辑抽到 `PortProbe`**（端口 / socket / `ps etime` / pid 文件），本地数据库与仓库数据存储共用；本机数据库行的错误区改为「完整错误 + 复制 / 信任 Tap / 重试」。

## [0.3.1-1] — 2026-09-09

### Added

- **本地数据库页签（Databases）**：弹窗在 Netlify 与「通知」之间新增 Databases 页签，监控本机 Homebrew 安装的 **MongoDB / MySQL / Neo4j**——每行显示彩色字标、状态圆点（运行中绿 / 已停止红）与运行时长（uptime），并提供 **Start / Stop**（经用户级 `brew services`，无需管理员密码；MongoDB 与 Neo4j 以登录服务方式 `start` 重启，MySQL 用 ad-hoc `brew services run`，不改变登录自启）与 **DBs** 展开库列表（运行中实时查询 `mongosh` / `mysql` / `cypher-shell`；停止时列出磁盘数据目录并标注 *offline · on disk*）。
- **数据库状态通知**：被监控数据库停止 / 恢复时发系统通知 + 铃铛页条目（默认开；Settings → Services → Local DBs 中开关），带冷却与用户操作抑制，避免自触发误报。
- **设置 → 服务 → Local DBs**：启用开关、数据库状态通知开关、可选的 MySQL / Neo4j 用户名与密码（密码存钥匙串）、「检查状态」。
- **导出/导入配置**新增 Local DBs 键：启用、通知开关、MySQL / Neo4j 用户名（settingsKeys）；MySQL / Neo4j 密码随密钥明文导出（secretKeys）。
- **AppAlertKind 新增 dbDown / dbRestored**（弹窗铃铛图标与配色 switch 同步补齐）。
- **ProcessRunner.runAsync**：后台线程异步执行，供 `brew services` 等耗时命令使用。

### Changed

- **文档补齐**：ui-guide 顶部 View-tabs 列表补上 Notifications（铃铛）与新 Databases，Settings 由五页改为六页（含 Guide 指南页）；settings-guide / ui-guide / how-it-works 新增 Local DBs（Services 条目、Part 1.5 Databases 小节、通知来源、疑难排查、密钥安全提示）与「用量记录携带客户端仓库 repo（Data Sync / 导出保留）」说明；ui-guide「Source Usage」与 how-it-works「Where your data lives」补充仓库识别的三重回退与「连接建立时解析」说明。

### Fixed

- **本机来源的仓库子标签（local - <仓库名>）漏标 / 识别不到**：仓库解析扩展为最多三重回退——① 客户端进程 cwd 向上找 `.git`；② cwd 不在仓库内时，扫描该进程**已打开的文件**路径，按多数投票取仓库根（跳过 /System、/Library、/Applications、/dev）；③ GUI / 编辑器宿主（如 VS Code 辅助进程）cwd 为 `/` 时，遍历其**后代进程**（`ps -axo pid=,ppid=`，深度 ≤6、上限 400）的 cwd 取多数仓库。同时仓库名改为在**连接就绪时**即解析一次并按连接缓存（仅缓存成功结果，失败可重试），避免请求结束时连接已关闭、读不到客户端端口而漏标。

## [0.2.10-4] — 2026-09-09

### Changed

- **GitHub / Netlify / AWS 选择器支持搜索**：GitHub 仓库、Netlify 站点、AWS 实例三个「下拉菜单」改为**始终可见的搜索框 + 过滤结果列表**——输入即按名称/域名/ID/类型/状态/IP 过滤，右侧 ✕ 一键清除，点击结果选中并加载详情；**结果列表可折叠**（搜索框右侧箭头收起/展开，输入即自动展开，无论是否在搜索）。
- **GitHub 仓库详情**：最近提交与最近发布改为取 **10** 条；**分支按最近提交时间由新到旧排序**（对每条分支抓取其最新提交时间后排序，无日期者排在末尾）；提交 / 分支 / 发布三组列表改为**可折叠**区段（点击标题展开/收起，带计数与箭头）。
- **Netlify 部署历史**：只显示**最近 10** 条，标题可折叠（默认展开，切换站点自动复位）。
- **菜单栏高峰状态点**：DeepSeek 的黄色（高峰）/绿色（低谷）小圆点改画在**菜单栏文字右上角**，无论显示哪些文字芯片（甚至隐藏图标）；无文字时回退到图标右上角。

### Fixed

- **本地来源的「仓库子标签」一直不显示**：`LocalRepoDetector` 解析 `lsof` 输出时按固定列下标取地址，且没去掉行尾的 `(ESTABLISHED)` 状态 token——`lsof -nP` 实际形如 `TCP 127.0.0.1:59677->127.0.0.1:18080 (ESTABLISHED)`，旧解析永远匹配不到连接 → repo 从未写入。改为**直接找含 `->` 的地址 token**（不依赖列数 / 状态后缀），端口不在快照时**强制补拍一次**（带限流），仓库路径向上查找到文件系统根（不再限于 $HOME）。
- **GitHub 私有仓库未列出**：仓库列表原用 `GET /users/{username}/repos`——该端点**只返回公开仓库**；现改为已认证用户的 `GET /user/repos`（`visibility=all` + `affiliation=owner,collaborator,organization_member`），私有 / 协作者 / 组织仓库都会列出并可选中（仍需 classic PAT 勾选 `repo` 权限才能看到私有仓库）。
- **AWS 页签图标呈实心圆**：图标原是「深色圆底 + 白 a」的 Amazon 购物标，小尺寸下像实心圆；现改为从仓库根 `aws.svg` 重新生成的**透明 AWS 字标**（无底色）。

### Changed

- **Usage by Source 显示仓库**：本地来源在**聚合列表**的 local 行下方显示小号仓库副标签（多仓库以 `·` 分隔），**逐条（Individual）列表**的每个本地请求在其来源下方显示所属仓库。

### Added

- **Netlify 页签 / 设置图标使用真实品牌标**：从仓库根 `netflify.png`（Netlify 品牌标）生成透明单色模板图 `Sources/dev_mon/netlify.png` 并随包打包（`Package.swift` 新增 `.process("netlify.png")`）；图标资源缺失时才回退 diamond SF Symbol。

## [0.2.10-3] — 2026-09-09

### Added

- **用量按仓库标注（Source Usage）**：本机请求在逐条来源列表中标注为 **local - <仓库名>**——dev_mon 用 `lsof` 快照抓取本地连接对应的客户端进程 cwd，向上找最近的 `.git` 目录取仓库名（结果缓存约 1 秒）；聚合仍按来源 IP（不按仓库拆库）。解析不到（如 GUI 进程 cwd 非工作区）仍显示 local。`UsageRecord`/`usage_log` 新增 `repo` 列（迁移 V7），Data Sync 推送与用量读取自动携带。
- **通知与 Cloudflare 的文档 / 导出补齐**：ui-guide 增加 Notifications（铃铛页）说明、Cloudflare tab 与 Services 条目、Source Usage 的 local - repo 说明；settings-guide 增加 Notifications & alerts 汇总；导出/导入配置新增 `tunnelDownNotificationEnabled` 与 `balanceAlertEnabled` 两个通知开关。
- **菜单栏「Peak」高峰时间文字芯片**：菜单栏文字新增 **Peak** 芯片（Settings → General → Menu Bar Text 开关）——DeepSeek 活跃时显示当前高峰/低谷与距下次切换的倒计时（如 `Peak 2h14m left`，低谷时 `Peak in 6h30m`），高峰橙色、低谷绿色。

## [0.2.10-2] — 2026-09-09

### Added

- **Netlify 站点与部署页**：弹窗新增 Netlify 页签（下拉选择站点 + 全宽详情，样式同 AWS 实例页）：
  - 站点详情：Project ID / 主链接 / 自定义域名 / 管理后台均带复制按钮并可打开；git 链接站点显示仓库 / 分支 / 构建命令 / 发布目录。
  - **触发部署**：经构建钩子触发生产部署（站点无钩子时自动创建，默认用其生产分支），支持 **清缓存并部署**；部署标题带 dev_mon 标记。
  - **部署本地目录**：选择一个构建好的本地目录（如 dist/public），用 `ditto` 打包为 zip 上传为新部署——无需 git 联动；也可在「＋ 新建站点」里从本地目录创建站点。
  - **部署历史**：状态彩色圆点（绿 = ready/live，橙 = 构建/排队，红 = 失败）+ 上下文（production / branch / preview）+ 分支/标题/时间；部署永久链接可复制、后台链接可打开；失败部署内联显示 error_message。
  - **回滚 / 锁定**：旧版已构建部署可一键 **回滚**（restore 重新上线）；线上部署可 **锁定**（停止自动发布）与 **解锁**。
  - **部署状态通知**：成功 / 失败 / 回滚时发系统通知（设置 → 服务 → Netlify 中开关，默认开），用户触发后有冷却抑制。
- **设置 → 服务 → Netlify**：启用开关、Personal Access Token（钥匙串）、「验证并发现」→ 账户/team 选择、部署通知开关与限速/安全提示。
- **导出/导入配置**已包含 Netlify 设置（启用、账户、选中站点、通知开关）；令牌走钥匙串（与 Cloudflare 令牌一致，仅本机），随「导出配置」明文导出。

## [0.2.10-1] — 2026-09-07

### Changed

- **AWS 实例页改为「下拉选择 + 全宽详情」**：去掉左侧固定宽度实例侧栏，改为顶部下拉菜单选择实例（每项显示 `实例ID · 名称 · 类型`），选中实例的详情与操作占满整行；空状态提示文案随之简化。
- **「打开 RDP」改进**：优先调用微软 **Windows App**（`com.microsoft.windowsapp`）打开 `rdp://` 地址，未安装时回退到系统已注册的 RDP 处理器；实例没有公网 IP/DNS、或本机没有可用的 RDP 客户端时，页面内直接给出明确错误提示（此前会静默无反应或误报成功）。
- **缩放把手改为内容 overlay**：右下角拖拽把手作为弹窗内容上的 overlay 布局（不再占用独立层级导致偏移），可点/拖热区加大到 44×44。

### Fixed

- **修复弹窗内输入框无法聚焦/键盘输入**：无边框弹窗窗口现显式允许成为 key window（`canBecomeKey`/`canBecomeMain`），AWS 入站规则编辑等 TextField 可以正常获得焦点并输入。
- 打开/关闭入站规则编辑器时清除旧的瞬时操作提示，避免残留成功/失败文案；规则端口输入框改为弹性宽度。

## [0.2.9-2] — 2026-09-07

### Added

- **真实品牌页签图标**：弹窗顶部 GitHub / AWS / Cloudflare 页签（及设置 → 服务对应标题）现使用随应用打包的真实品牌 Logo——透明单色字形（github/aws/cloudflare，作为模板图随主题着色）；打包资源存在时自动显示真实图标，缺失仍回退 SF Symbol。License 页签图标由「盾牌勾选」改为**钥匙**（key.fill，弹窗页签、设置侧栏与许可页标题一致）。

### Changed

- **底部操作栏左对齐**：弹窗底部操作栏（刷新 / 导出用量 / 导出配置 / 导入配置 / 设置 / 退出）由靠右排列改为靠左排列。

## [0.2.9-1] — 2026-09-07

### Added

- **Cloudflare 隧道页**：弹窗新增 Cloudflare 页签（Overview / Public Hostnames / Private IP 三个子页）：
  - Overview 显示本机 cloudflared 服务状态（运行 / 停止 / 未安装）与 **Start / Stop / Restart**（需管理员密码，经 osascript 提权执行 `launchctl`）；并显示所选隧道名称、健康状态、连接数与更新时间。
  - **Public Hostnames**：增删公开主机名 —— 读写隧道 ingress 配置，并自动同步 Zone 内指向 `<隧道ID>.cfargotunnel.com` 的 CNAME 记录。
  - **Private IP**：增删私有网络路由（WARP/Zero Trust 客户端经隧道访问内网用）。
  - 服务进程在跑但隧道未连（0 连接）时，Overview 显示橙色提示，指引检查隧道 token / cloudflared 日志。
  - 出错状态（如「Failed to parse response」）页面内直接提供 **Verify & Discover**，无需回设置即可重试验证。
- **设置 → 服务 → Cloudflare**：启用开关、API Token（钥匙串）、「验证并发现」→ 账户 / Zone / 隧道选择、本机守护进程状态点。
- **实例信息一键复制**：AWS 实例详情中的公网 IP / 公网 DNS / 内网 IP 行新增复制按钮——EC2 停止再启动会更换公网 DNS，复制后即可直接粘贴使用。
- **打开 RDP 连接**：运行中的实例新增「打开 RDP」按钮：复制其公网 DNS/IP 并尝试以 `rdp://` 拉起远程桌面客户端（地址始终已复制，即使没有客户端响应 URL 也不影响）。
- **弹窗可拖拽缩放**：右下角新增拖拽把手，拖动可整体放大/缩小弹窗（文字、图标、间距按比例缩放，1.0×–2.2×），并记住上次大小。
- **顶部页签改为纯图标**：AI Usage / License / GitHub / AWS / Cloudflare 页签改为图标显示（悬停显示名称），并修复 GitHub / Cloudflare 页签此前图标不可见、页签不可点的问题；优先使用打包的品牌图标资源，缺省回退到 SF Symbol。
- **外观主题**：设置 → 通用新增「外观」—— 跟随系统 / 浅色 / 深色，即时作用于弹窗与设置窗口，随配置导入导出。

### Changed

- **Cloudflare 启动只弹一次管理员密码**：改为 `launchctl kickstart` 后轮询等待进程真正起来（launchd 异步 spawn），仅当数秒后仍未运行才补一次 `bootstrap`，不再连环弹出多次密码框；启动/重启成功后自动刷新 API 健康状态。
- **Cloudflare 私有路由显示修复**：隧道没有公开主机名时不再提前返回，私有 IP 路由照常拉取并加大分页——此前会导致仪表盘已有路由、dev_mon 却显示为空。
- **Cloudflare 故障排查**：文档明确区分 dev_mon 使用的 **API Token** 与 cloudflared 实际读取的**隧道 token**（本机 token 文件缺失会令 cloudflared 反复重启、隧道长期 Down）。
- **配置导入导出补齐**：导出范围新增 Cloudflare 全部设置键（启用 / 账户 / Zone / 隧道 ID 与名称）、Z.AI 端点选择与外观主题；Cloudflare API Token 纳入密钥导出；导入后自动应用主题。
- **弹窗主体布局重构**：为支持整体等比缩放，弹窗内容包一层缩放容器，右下角把手与页签、操作栏保持正常可用。

## [0.2.8-1] — 2026-09-06

### Added

- **AWS 概览列出全部实例**：AWS → 概览页现列出当前区域内的全部实例，每行显示状态圆点、实例 ID、类型与本地化状态文字（运行中实例优先排序）；运行中实例显示运行时长（非免费套餐机型附红色「~$30/月」成本提示），其余实例显示公网 IP（无则显示 —）。
- **公网 DNS 展示**：实例详情在实例进入运行状态后新增一行可复制的「公网 DNS」（EC2 公网主机名），实例停止/重启后随状态自动刷新为新地址。
- **安全组入站规则管理**：实例详情在主安全组下方新增「入站规则」区，列出全部入站规则（协议 / 端口 / 来源 CIDR 或对端安全组 / 描述，文字可复制），并支持逐条**添加 / 编辑 / 删除**——新增与编辑以内嵌卡片填写协议（TCP/UDP/ICMP/全部）、起始/结束端口、来源（可一键填入 `0.0.0.0/0` 或「我的 IP」）与可选描述；删除需二次确认。规则变更后自动刷新规则列表与「我的 IP RDP 3389」开放状态。

### Changed

- **启动/停止后自动轮询刷新**：对实例执行启动后最多自动轮询约 60 秒（每 5 秒）、停止后轮询数次（每 3 秒），待实例脱离过渡态即停止，使状态、公网 IP/DNS 与入站规则无需手动刷新即可反映最新结果。
- **AWS IAM 权限提示**：实例操作所需权限补充 `ec2:RevokeSecurityGroupIngress`（删除入站规则需要），并同步更新设置页提示与「权限不足」错误信息。

## [0.2.7-1] — 2026-09-06

### Added

- **设置 → 指南页签**：设置窗口新增「指南」页（书架图标），可在应用内阅读仓库 `docs/*.md` 说明文档（how-it-works / settings-guide / ui-guide 等，不含 CHANGELOG）。使用自定义 Markdown 渲染（标题、粗斜体、行内代码、代码块、列表/任务清单、对齐表格、相对链接等），文档列表按文档分段切换；文档页签固定在顶部、滚动长文档时不会滚走。文档定位支持打包进应用的资源目录与仓库 `docs/` 目录两种来源。
- **AWS 实例管理子页**：AWS 页拆分为「概览 / 实例」子页签。概览保持原有免费套餐/费用行；「实例」页为双栏布局 —— 左侧可滚动实例侧栏（实例 ID 截断、状态圆点、类型与运行时长），右侧为选中实例详情（完整 ID、状态徽标、启动时间/运行时长、公网与内网 IP、所属安全组）。
- **实例启动/停止**：详情页对已停止实例提供「启动」、对运行中实例提供「停止」按钮（均带二次确认与进行中指示器），操作后自动延迟刷新以反映状态变化。
- **向我的公网 IP 开放 RDP**：对选中实例的主安全组自动检测「RDP 3389/tcp 是否已对我的 IP 开放」（含 `0.0.0.0/0`、`::/0` 视为已开放），未开放时提供一键「开放 RDP 3389 给我的 IP」——自动获取本机公网 IP，仅在缺失时写入 `AuthorizeSecurityGroupIngress`（描述带日期），重复操作会提示已开放。
- **提供商标签行留白**：AI 用量页顶部提供商图标行增加上下内边距与图标间距，观感更宽松。

### Changed

- **EC2 实例解析重构**：按「实例 ID」锚点切块解析（原按 `<item>` 的扫描在实例含安全组等嵌套 `<item>` 元素时会错位），免费套餐统计（运行小时、实例数、合格/不合格、月底预测、超额估算）统一改为由解析出的实例列表推导，口径与原先一致。
- **AWS IAM 权限提示**：设置 → 服务 → AWS 新增提示——实例管理需在 IAM 策略中授予 `ec2:DescribeSecurityGroups`、`ec2:StartInstances`、`ec2:StopInstances`、`ec2:AuthorizeSecurityGroupIngress`（权限不足的错误信息同步更新）。

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
