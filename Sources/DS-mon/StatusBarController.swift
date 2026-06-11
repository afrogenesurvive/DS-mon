import SwiftUI
import AppKit
import Charts

// MARK: - AppKit 状态栏

@MainActor
class StatusBarController: NSObject, NSWindowDelegate {
    static let shared = StatusBarController()
    var stats: DeepSeekStats?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusView: StatusBarView?
    private var eventMonitor: Any?

    func setup() {
        guard statusItem == nil, let s = stats else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusView = StatusBarView(frame: .zero)
        statusView?.target = self
        statusView?.action = #selector(togglePopover)
        statusItem?.setValue(statusView, forKey: "view")
        statusItem?.length = 60
        let savedMode = UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance"
        statusView?.menuBarTextDisplay = savedMode

        updateLabel()

        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuIconChanged), name: .showMenuIconDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(indicatorChanged), name: .showIndicatorDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarTextDisplayChanged), name: .menuBarTextDisplayDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(providerChanged), name: .activeProviderDidChange, object: nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: AppConfig.popoverWidth, height: AppConfig.popoverHeight),
                              styleMask: [.borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = buildPopoverContentView(stats: s)
        window.level = .popUpMenu
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.delegate = self
        popoverWindow = window

        updateLabel()
        refreshCacheHitRate()
        startUpdateTimer()
    }

    /// 定时器驱动更新：每 1 秒检查一次状态，替代 withObservationTracking
    private var updateTimer: Timer?

    private func startUpdateTimer() {
        stopUpdateTimer()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            ProxyServer.shared.decayVU()
            Task { @MainActor in self?.updateLabel() }
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func showSettings() {
        guard let s = stats else { return }
        // 窗口已关闭或首次打开 — 创建新窗口以刷新状态
        if settingsWindow?.isVisible != true {
            settingsWindow = nil
            let view = ThresholdView(stats: s)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = Strings.settingsTitle
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: AppConfig.settingsWidth, height: AppConfig.settingsHeight))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        guard let v = statusItem?.value(forKey: "view") as? NSView,
              let window = popoverWindow else { return }
        if window.isVisible {
            closePopover()
        } else {
            let vFrame = v.window?.convertToScreen(v.convert(v.bounds, to: nil)) ?? .zero
            let wFrame = window.frame
            let x = vFrame.midX - wFrame.width / 2
            let y = vFrame.minY - wFrame.height - 4
            window.setFrameOrigin(NSPoint(x: x, y: y))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            startEventMonitor()
        }
    }

    func closePopover() {
        popoverWindow?.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func startEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

/// 请求完成后刷新缓存命中率（SQLite 读取较慢，不在 updateLabel 循环中执行）
    private var hitRateDebounceTask: Task<Void, Never>?

    func refreshCacheHitRate() {
        hitRateDebounceTask?.cancel()
        hitRateDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let cacheHit = UsageStore.shared.currentHourCacheHitRate()
            let todayHit = UsageStore.shared.todayCacheHitRate()
            self.statusView?.cacheHitRatio = cacheHit
            self.statusView?.todayHitRate = todayHit
            self.statusView?.needsDisplay = true
        }
    }

    private func updateLabel() {
        guard let s = stats else { return }
        let balance = s.balance
        let blinkOn = s.blinkOn
        let isError = s.errorMessage != nil
        let isLow = s.isLowBalance
        let isWarning = s.isWarningBalance
        let balanceText = s.balanceText

        let maxAmount = UserDefaults.standard.double(forKey: Strings.Keys.maxBalanceAmount)
        let cap = maxAmount > 0 ? maxAmount : AppConfig.defaultMaxBalanceAmount
        let ratio = cap > 0 ? min(balance / cap, 1.0) : 0
        let hr = statusView?.cacheHitRatio ?? 0
        let hitRateText = hr > 0 ? String(format: "%.1f%%", hr * 100) : ""

        applyLabel(balanceRatio: ratio, balanceAmount: balanceText, hitRateText: hitRateText, isError: isError, isLow: isLow, blinkOn: blinkOn, isWarning: isWarning)
    }

    private func applyLabel(balanceRatio: Double, balanceAmount: String = "", hitRateText: String = "", isError: Bool, isLow: Bool, blinkOn: Bool, isWarning: Bool = false) {
        statusView?.update(balanceRatio: balanceRatio, balanceAmount: balanceAmount, hitRateText: hitRateText, isError: isError, isLowAlerting: isLow, blinkOn: blinkOn, isWarning: isWarning)

        // 计算总宽度
        let showIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? true
        let showIndicator = UserDefaults.standard.object(forKey: Strings.Keys.showIndicator) as? Bool ?? true
        let textMode = UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance"

        var w: CGFloat = showIcon ? 21 : 2  // leftX
        if showIndicator {
            w += 23  // leadingGap + 3bars + 2columnGaps + border + padding
        }
        if textMode == "balance", !balanceAmount.isEmpty {
            let amtFont = NSFont.menuFont(ofSize: 0)
            let amtW = (balanceAmount as NSString).size(withAttributes: [.font: amtFont]).width
            w += amtW + 4
        } else if textMode == "hitRate" {
            let hrFont = NSFont.menuFont(ofSize: 0)
            let hrText = hitRateText.isEmpty ? "0%" : hitRateText
            let hrW = (hrText as NSString).size(withAttributes: [.font: hrFont]).width
            w += hrW + 4
        }
        w += 2  // trailing padding
        statusItem?.length = w
        statusView?.setFrameSize(NSSize(width: w, height: 18))
        statusView?.needsDisplay = true
    }

    @objc private func languageChanged() {
        updateLabel()
        guard let s = stats else { return }
        popoverWindow?.contentView = buildPopoverContentView(stats: s)
    }

    /// 构建弹出面板内容视图（带不透明背景）
    private func buildPopoverContentView(stats: DeepSeekStats) -> NSView {
        let host = NSHostingView(rootView: StatsPopoverView(stats: stats))
        host.frame = NSRect(x: 0, y: 0, width: AppConfig.popoverWidth, height: AppConfig.popoverHeight)
        let container = NSVisualEffectView(frame: host.frame)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.addSubview(host)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        return container
    }

    @objc private func menuIconChanged() {
        let showIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? true
        statusView?.showIcon = showIcon
        updateLabel()
    }

    @objc private func indicatorChanged() {
        let show = UserDefaults.standard.object(forKey: Strings.Keys.showIndicator) as? Bool ?? true
        statusView?.showIndicator = show
        updateLabel()
    }

    @objc private func menuBarTextDisplayChanged() {
        let mode = UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance"
        statusView?.menuBarTextDisplay = mode
        updateLabel()
    }


    @objc private func providerChanged() {
        updateLabel()
        refreshCacheHitRate()
    }
}

// MARK: - 菜单栏自定义视图 — LED 条阵列

/// 三条 5 格 LED 条从左到右排列
@MainActor
class StatusBarView: NSView {
    weak var target: AnyObject?
    var action: Selector?

    private let icon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "menu_icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
    private let iconView = NSImageView()

    var showIcon: Bool = true {
        didSet { iconView.isHidden = !showIcon; needsDisplay = true }
    }
    var showIndicator: Bool = true
    var menuBarTextDisplay: String = "balance"
    var hitRateText: String = ""
    var balanceAmount: String = ""

    // MARK: 数据
    private var balanceRatio: Double = 0
    var cacheHitRatio: Double?
    var todayHitRate: Double?
    private var isError = false
    private var isLowAlerting = false
    private var isWarning = false
    private var blinkOn = true

    // MARK: 动画
    private var animCounter: Int { Int(Date().timeIntervalSinceReferenceDate / 1.0) % 2 == 0 ? 0 : 1 }  // 呼吸节奏 ~2s/cycle

    // MARK: 布局常量
    private let barWidth: CGFloat = 5.0
    private let barHeight: CGFloat = 2.0
    private let barGap: CGFloat = 0.333
    private let columnGap: CGFloat = 1.0
    private let leadingGap: CGFloat = 1

    /// 指示器区域总宽度（不含左右边距）

    private var barCount: Int { showIcon ? 3 : 3 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.image = icon
        iconView.isEditable = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = CGRect(x: 1, y: 0, width: 18, height: 18)
        iconView.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        addSubview(iconView)

        let savedShowIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? true
        showIcon = savedShowIcon
        iconView.isHidden = !savedShowIcon

    }

    required init?(coder: NSCoder) { nil }

    override func removeFromSuperview() {
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        iconView.frame.origin.y = (bounds.height - 18) / 2
    }

    func update(balanceRatio: Double, balanceAmount: String = "", hitRateText: String = "", isError: Bool, isLowAlerting: Bool, blinkOn: Bool, isWarning: Bool = false) {
        self.balanceRatio = balanceRatio
        self.balanceAmount = balanceAmount
        self.isError = isError
        self.isLowAlerting = isLowAlerting
        self.isWarning = isWarning
        self.hitRateText = hitRateText
        self.blinkOn = blinkOn
    }

    override func mouseDown(with event: NSEvent) {
        if let target = target as? NSObject, let action = action {
            target.perform(action, with: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let barH = bounds.height
        guard barH > 0 else { return }

        let leftX: CGFloat = showIcon ? 21 : 2
        var cursorX = leftX

        // ── 三个指示灯条 ──
        if showIndicator {
            let bar1x = cursorX + leadingGap
            let hasActivity = ProxyServer.shared.hasActiveConnection

            let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
            let topY = (barH - totalH) / 2 - 1
            let barsRight = bar1x + 3 * barWidth + 2 * columnGap + 1
            let containerRect = CGRect(x: bar1x - 1, y: topY, width: barsRight - bar1x + 1, height: totalH + 2)
            let containerPath = CGPath(roundedRect: containerRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)

            // 极浅背景
            ctx.setFillColor(NSColor.gray.withAlphaComponent(0.06).cgColor)
            ctx.addPath(containerPath)
            ctx.fillPath()

            // 条①：VU 电平表 — 反映最近访问频率
            let barColor1: NSColor
            let barFill1: CGFloat
            if hasActivity {
                let isCodex = ProxyServer.shared.hasActiveCodexConnection
                barColor1 = isCodex ? NSColor(red: 0x10/255.0, green: 0xB9/255.0, blue: 0x81/255.0, alpha: 1) : NSColor(red: 0x3B/255.0, green: 0x82/255.0, blue: 0xF6/255.0, alpha: 1)
                barFill1 = CGFloat(ProxyServer.shared.vuLevel)
            } else {
                barColor1 = .gray; barFill1 = 0
            }
            let vuPeak = CGFloat(ProxyServer.shared.vuPeakLevel)
            let vuPrevPeak = CGFloat(ProxyServer.shared.vuPrevPeakLevel)
            drawSolidBar(ctx: ctx, x: bar1x, barH: barH, fillRatio: barFill1, color: barColor1,
                        peakRatio: vuPeak, prevPeakRatio: vuPrevPeak)

            let bar2x = bar1x + barWidth + columnGap
            let hitRatio = cacheHitRatio ?? 0
            let hitFill: CGFloat = hitRatio < 0.70 ? 0.15 : min(1.0, CGFloat((hitRatio - 0.7) / 0.3))
            drawSolidBar(ctx: ctx, x: bar2x, barH: barH, fillRatio: hitFill,
                       color: cacheHitRatio.map { cacheHitColor($0) } ?? .gray)

            // 本日命中率线（红色细线）
            if let todayHit = self.todayHitRate, todayHit > 0 {
                let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
                let topY = (barH - totalH) / 2 - 1
                let hitY = topY + totalH * min(max(CGFloat(todayHit), 0), 1)
                let hitLineRect = CGRect(x: bar2x, y: hitY, width: barWidth, height: 1)
                ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
                ctx.fill(hitLineRect)
            }

            let bar3x = bar2x + barWidth + columnGap
            let balColor: NSColor = isLowAlerting ? (blinkOn ? .systemRed : .systemRed.withAlphaComponent(0.3)) : (isWarning ? .systemOrange : .systemGreen)
            drawSolidBar(ctx: ctx, x: bar3x, barH: barH, fillRatio: min(max(CGFloat(balanceRatio), 0), 1),
                       color: balColor)
            cursorX = barsRight + 4  // 条区结束 + padding
        }

        // ── 菜单栏文字 ──
        let textMode = UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance"
        if textMode == "balance", !balanceAmount.isEmpty {
            let amtFont = NSFont.menuFont(ofSize: 0)
            let amtAttr: [NSAttributedString.Key: Any] = [
                .font: amtFont,
                .foregroundColor: isLowAlerting
                    ? (blinkOn ? NSColor.systemRed : NSColor.systemRed.withAlphaComponent(0.3))
                    : (isDarkMode ? NSColor.white : NSColor.black)
            ]
            let amtStr = balanceAmount as NSString
            let amtSize = amtStr.size(withAttributes: amtAttr)
            let amtY = (barH - amtSize.height) / 2
            amtStr.draw(at: NSPoint(x: cursorX, y: amtY), withAttributes: amtAttr)
            cursorX += amtSize.width + 4
        } else if textMode == "hitRate" {
            let hrFont = NSFont.menuFont(ofSize: 0)
            let hrColor: NSColor = isDarkMode ? NSColor.white : NSColor.black
            let hrAttr: [NSAttributedString.Key: Any] = [
                .font: hrFont,
                .foregroundColor: hrColor
            ]
            let hrStr = hitRateText.isEmpty ? "0%" : hitRateText as NSString
            let hrSize = hrStr.size(withAttributes: hrAttr)
            let hrY = (barH - hrSize.height) / 2
            hrStr.draw(at: NSPoint(x: cursorX, y: hrY), withAttributes: hrAttr)
            cursorX += hrSize.width + 4
        }
    }

    private var isDarkMode: Bool {
        effectiveAppearance.name == .darkAqua
        || effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - 方条绘制

    /// 数据条（从下往上填充）
    private func drawBarColumn(ctx: CGContext, x: CGFloat, barH: CGFloat,
                               filledCount: Int, color: NSColor) {
        drawBarRects(ctx: ctx, x: x, barH: barH, filled: filledCount, color: color, bgAlpha: 0.15)
    }

    /// 单呼吸条（替代条 1 的 5 段 LED）
    /// animPhase 0-5 控制呼吸相位：偶数为亮，奇数为暗
    private func drawBreathingBar(ctx: CGContext, x: CGFloat, barH: CGFloat,
                                  animPhase: Int, color: NSColor, alerting: Bool, blinkOn: Bool) {
        let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
        let topY = (barH - totalH) / 2
        let barRect = CGRect(x: x, y: topY, width: barWidth, height: totalH)

        // 呼吸亮度：偶数为亮(1.0)，奇数为暗(0.4)
        let isBright = animPhase % 2 == 0
        // 空闲灰色时不用呼吸，保持静态
        let hasBreath = color != .gray
        let breathAlpha: CGFloat
        if alerting {
            breathAlpha = blinkOn ? 1.0 : 0.3
        } else if hasBreath {
            breathAlpha = isBright ? 1.0 : 0.35
        } else {
            breathAlpha = 0.15
        }

        let drawColor = color.withAlphaComponent(breathAlpha)
        let roundPath = CGPath(roundedRect: barRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)

        if breathAlpha > 0.5 {
            ctx.setFillColor(drawColor.cgColor)
        }

        // 主体
        ctx.setFillColor(drawColor.cgColor)
        ctx.addPath(roundPath)
        ctx.fillPath()
    }

    /// 一列方块
    private func drawBarRects(ctx: CGContext, x: CGFloat, barH: CGFloat, filled: Int, color: NSColor, bgAlpha: CGFloat) {
        let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
        let topY = (barH - totalH) / 2
        for i in 0..<5 {
            let y = topY + CGFloat(4 - i) * (barHeight + barGap)
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let roundPath = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)

            if i >= (5 - filled) {
                // 主体
                ctx.setFillColor(color.cgColor)
                ctx.addPath(roundPath)
                ctx.fillPath()
            }
        }
    }

    /// 整条柱状图（从下往上填充）
    private func drawSolidBar(ctx: CGContext, x: CGFloat, barH: CGFloat,
                              fillRatio: CGFloat, color: NSColor,
                              peakRatio: CGFloat = 0, prevPeakRatio: CGFloat = 0) {
        let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
        let topY = (barH - totalH) / 2
        let barRect = CGRect(x: x, y: topY, width: barWidth, height: totalH)
        let corner: CGFloat = 1.5

        // 背景
        let bgPath = CGPath(roundedRect: barRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // 从下往上填充（逐格）
        if fillRatio > 0 {
            let filledCount = Int(CGFloat(7) * min(max(fillRatio, 0), 1))
            let segH = barHeight
            let segGap = barGap
            for i in 0..<filledCount {
                let y = topY + CGFloat(i) * (segH + segGap)
                let segRect = CGRect(x: x, y: y, width: barWidth, height: segH)
                ctx.setFillColor(color.cgColor)
                ctx.fill(segRect)
            }
        }

        // 峰值线（在填充之上绘制，防止被覆盖）
        if peakRatio > 0 {
            let peakY = topY + totalH * min(max(CGFloat(peakRatio), 0), 1)
            let peakLineRect = CGRect(x: x, y: peakY, width: barWidth, height: 1)
            let peakColor = NSColor.systemRed
            ctx.setFillColor(peakColor.withAlphaComponent(0.9).cgColor)
            ctx.fill(peakLineRect)
        }
        // 上一个峰值线
        if prevPeakRatio > 0 {
            let prevY = topY + totalH * min(max(CGFloat(prevPeakRatio), 0), 1)
            let prevLineRect = CGRect(x: x, y: prevY, width: barWidth, height: 1)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
            ctx.fill(prevLineRect)
        }
    }

    private func cacheHitColor(_ rate: Double) -> NSColor {
        if rate < 0.70 { return .systemRed }
        if rate < 0.85 { return .systemOrange }
        if rate < 0.95 { return .systemCyan }
        return .systemGreen
    }
}
