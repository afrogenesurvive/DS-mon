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
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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
            let cacheHit = UsageStore.shared.mostRecentCacheHitRate()
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


}

// MARK: - 菜单栏自定义视图 — LED 条阵列

/// 三条 5 格 LED 条从左到右排列
@MainActor
class StatusBarView: NSView {
    weak var target: AnyObject?
    var action: Selector?

    private let icon: NSImage? = {
        let url = Bundle.main.url(forResource: "menu_icon", withExtension: "png")
            ?? Bundle.module.url(forResource: "menu_icon", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.image = icon
        iconView.isEditable = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = CGRect(x: 1, y: 0, width: 18, height: 18)
        iconView.autoresizingMask = [.maxXMargin, .minYMargin]
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

            // 统一容器（裁剪路径 + 背景）
            let containerRect = CGRect(x: bar1x - 1.5, y: topY - 1, width: barsRight - bar1x + 2, height: totalH + 4)
            let containerPath = CGPath(roundedRect: containerRect, cornerWidth: 2, cornerHeight: 2, transform: nil)

            // 容器背景 + 1px 边框（随系统浅色/深色）
            let borderColor: NSColor = isDarkMode ? NSColor.white : NSColor.black
            let bgColor: NSColor = isDarkMode ? NSColor.white : NSColor.black
            ctx.setFillColor(bgColor.withAlphaComponent(0.06).cgColor)
            ctx.addPath(containerPath)
            ctx.fillPath()
            ctx.setStrokeColor(borderColor.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(containerPath)
            ctx.strokePath()



            // 用容器裁剪，让三条柱子填充不溢出圆角
            ctx.saveGState()
            ctx.addPath(containerPath)
            ctx.clip()

            // 条①：VU 电平表
            let vuLevel = CGFloat(ProxyServer.shared.vuLevel)
            let vuActive = hasActivity || vuLevel > 0
            let barFill1: CGFloat = vuActive ? vuLevel : 0
            let vuAvg = CGFloat(ProxyServer.shared.vuAvgLevel)
            drawGradientBar(ctx: ctx, x: bar1x, barH: barH, fillRatio: barFill1,
                           topColor: NSColor.systemOrange, bottomColor: .systemGreen,
                           avgRatio: vuAvg)

            let bar2x = bar1x + barWidth + columnGap
            let hitRatio = cacheHitRatio ?? 0
            let hitFill: CGFloat = hitRatio < 0.70 ? 0.15 : min(1.0, CGFloat((hitRatio - 0.7) / 0.3))
            drawSolidBar(ctx: ctx, x: bar2x, barH: barH, fillRatio: hitFill,
                       color: cacheHitRatio.map { cacheHitColor($0) } ?? .gray)

            // 本日命中率线（红色细线）
            if let todayHit = self.todayHitRate, todayHit > 0 {
                let hitY = topY + totalH * min(max(CGFloat(todayHit), 0), 1)
                let hitLineRect = CGRect(x: bar2x, y: hitY, width: barWidth, height: 1)
                ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
                ctx.fill(hitLineRect)
            }

            let bar3x = bar2x + barWidth + columnGap
            let balColor: NSColor = isLowAlerting ? (blinkOn ? .systemRed : .systemRed.withAlphaComponent(0.3)) : (isWarning ? .systemOrange : .systemGreen)
            drawSolidBar(ctx: ctx, x: bar3x, barH: barH, fillRatio: min(max(CGFloat(balanceRatio), 0), 1),
                       color: balColor)

            ctx.restoreGState()

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

    // MARK: - 渐变柱状图
    private func drawSolidBar(ctx: CGContext, x: CGFloat, barH: CGFloat,
                              fillRatio: CGFloat, color: NSColor,
                              avgRatio: CGFloat = 0) {
        let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
        let topY = (barH - totalH) / 2

        // 柱状背景
        let bgRect = CGRect(x: x, y: topY, width: barWidth, height: totalH)
        ctx.setFillColor(color.withAlphaComponent(0.12).cgColor)
        ctx.fill(bgRect)

        if fillRatio > 0 {
            let fillH = totalH * min(max(fillRatio, 0), 1)
            let fillRect = CGRect(x: x, y: topY, width: barWidth, height: fillH)
            ctx.setFillColor(color.cgColor)
            ctx.fill(fillRect)
        }

        if avgRatio > 0 {
            let avgY = topY + totalH * min(max(CGFloat(avgRatio), 0), 1)
            let avgLineRect = CGRect(x: x, y: avgY, width: barWidth, height: 1)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
            ctx.fill(avgLineRect)
        }
    }

    /// 渐变柱状图（绿→橙，从下往上）
    private func drawGradientBar(ctx: CGContext, x: CGFloat, barH: CGFloat,
                                 fillRatio: CGFloat,
                                 topColor: NSColor, bottomColor: NSColor,
                                 avgRatio: CGFloat = 0) {
        let totalH = CGFloat(7) * barHeight + CGFloat(6) * barGap
        let topY = (barH - totalH) / 2

        let bgRect = CGRect(x: x, y: topY, width: barWidth, height: totalH)
        ctx.setFillColor(NSColor.gray.withAlphaComponent(0.08).cgColor)
        ctx.fill(bgRect)

        if fillRatio > 0 {
            let fillH = totalH * min(max(fillRatio, 0), 1)
            let fillRect = CGRect(x: x, y: topY, width: barWidth, height: fillH)
            let colors = [bottomColor.cgColor, topColor.cgColor]
            let locations: [CGFloat] = [0, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: colors as CFArray,
                                          locations: locations) {
                let ctx2 = ctx
                ctx2.saveGState()
                ctx2.clip(to: fillRect)
                ctx2.drawLinearGradient(gradient,
                                        start: CGPoint(x: x, y: topY),
                                        end: CGPoint(x: x, y: topY + totalH),
                                        options: [])
                ctx2.restoreGState()
            }
        }

        if avgRatio > 0 {
            let avgY = topY + totalH * min(max(CGFloat(avgRatio), 0), 1)
            let avgLineRect = CGRect(x: x, y: avgY, width: barWidth, height: 1)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
            ctx.fill(avgLineRect)
        }
    }

    private func cacheHitColor(_ rate: Double) -> NSColor {
        if rate < 0.70 { return .systemRed }
        if rate < 0.85 { return .systemOrange }
        if rate < 0.95 { return .systemCyan }
        return .systemGreen
    }
}
