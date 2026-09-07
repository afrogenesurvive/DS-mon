import SwiftUI
import AppKit
import Charts

/// 无边框弹出窗口。默认的无边框 NSWindow 无法成为 key window（没有标题栏），
/// 这会导致其中的 SwiftUI TextField 永远拿不到焦点/键盘输入。这里显式允许成为 key。
private final class PopoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

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
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarColorChanged), name: .menuBarColorDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(currencyChanged), name: .currencyDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(peakSettingsChanged), name: .peakSettingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverResizeRequested(_:)), name: .popoverResizeRequested, object: nil)

        let scale = AppConfig.savedPopoverScale()
        let window = PopoverWindow(contentRect: NSRect(x: 0, y: 0,
                                                       width: AppConfig.popoverWidth * scale,
                                                       height: AppConfig.popoverHeight * scale),
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

    @objc private func popoverResizeRequested(_ note: Notification) {
        guard let scaleNum = note.object as? NSNumber else { return }
        resizePopover(to: CGFloat(scaleNum.doubleValue))
    }

    /// 按缩放倍数调整弹窗窗口大小（保持顶部中心点不变、不超出屏幕）。
    private func resizePopover(to rawScale: CGFloat) {
        guard let window = popoverWindow else { return }
        let screen = statusView?.window?.screen ?? window.screen ?? NSScreen.main
        let maxH = (screen?.visibleFrame.height ?? 1200) - 24
        let maxAllowed = min(AppConfig.popoverScaleMax, maxH / AppConfig.popoverHeight)
        let scale = AppConfig.clampedPopoverScale(min(rawScale, maxAllowed))
        AppConfig.setSavedPopoverScale(scale)

        let newSize = NSSize(width: AppConfig.popoverWidth * scale,
                             height: AppConfig.popoverHeight * scale)
        let oldFrame = window.frame
        let centerX = oldFrame.midX
        var newFrame = NSRect(origin: oldFrame.origin, size: newSize)
        // 保持顶部（上边缘）不动：Cocoa 坐标原点在左下，故用 maxY 固定顶部。
        newFrame.origin.y = oldFrame.maxY - newSize.height
        // 保持水平居中。
        newFrame.origin.x = centerX - newSize.width / 2
        // 夹到屏幕可见区域内。
        if let sf = screen?.visibleFrame {
            if newFrame.minX < sf.minX { newFrame.origin.x = sf.minX }
            if newFrame.maxX > sf.maxX { newFrame.origin.x = sf.maxX - newFrame.width }
            if newFrame.minY < sf.minY { newFrame.origin.y = sf.minY }
        }
        window.setFrame(newFrame, display: true, animate: false)
    }

    private func startEventMonitor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self,
                      let statusView = self.statusView,
                      let win = statusView.window else { return }
                let winPt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                let viewPt = statusView.convert(winPt, from: nil)
                if statusView.bounds.contains(viewPt) { return }
                Task { @MainActor in self.closePopover() }
            }
        }
    }

/// 请求完成后刷新缓存命中率（SQLite 读取较慢，不在 updateLabel 循环中执行）
    private var hitRateDebounceTask: Task<Void, Never>?

    func refreshCacheHitRate() {
        hitRateDebounceTask?.cancel()
        hitRateDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let cacheHit = await UsageStore.shared.mostRecentCacheHitRate()
            let todayHit = await UsageStore.shared.todayCacheHitRate()
            let cost = await UsageStore.shared.todayCost()
            self.statusView?.cacheHitRatio = cacheHit
            self.statusView?.todayHitRate = todayHit
            self.statusView?.costText = Strings.costShort(cost)
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
        let costText = statusView?.costText ?? ""

        // 高峰/低谷状态点：仅 DeepSeek 且开启设置时显示
        let showPeakDot = UserDefaults.standard.object(forKey: Strings.Keys.showPeakDot) as? Bool ?? false
        let isDeepSeek = s.providerID == "deepseek"
        statusView?.isPeakHour = (isDeepSeek && showPeakDot) ? DeepSeekPricing.isPeak() : nil

        applyLabel(balanceRatio: ratio, balanceAmount: balanceText, hitRateText: hitRateText, costText: costText, isError: isError, isLow: isLow, blinkOn: blinkOn, isWarning: isWarning)
    }

    private func applyLabel(balanceRatio: Double, balanceAmount: String = "", hitRateText: String = "", costText: String = "", isError: Bool, isLow: Bool, blinkOn: Bool, isWarning: Bool = false) {
        statusView?.update(balanceRatio: balanceRatio, balanceAmount: balanceAmount, hitRateText: hitRateText, costText: costText, isError: isError, isLowAlerting: isLow, blinkOn: blinkOn, isWarning: isWarning)

        // 计算总宽度
        let showIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? false
        let showIndicator = UserDefaults.standard.object(forKey: Strings.Keys.showIndicator) as? Bool ?? false
        let textMode = UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance"

        var w: CGFloat = showIcon ? 21 : 2  // leftX
        if showIndicator {
            w += 23  // leadingGap + 3bars + 2columnGaps + border + padding
        }
        let textModes = (textMode as String).components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }
        if !textModes.isEmpty {
            let font = NSFont.menuFont(ofSize: 0)
            for (i, mode) in textModes.enumerated() {
                if i > 0 { w += (" | " as NSString).size(withAttributes: [.font: font]).width }
                let t: String = switch mode {
                case "balance": balanceAmount.isEmpty ? "\(Strings.currencySymbol)0" : balanceAmount
                case "hitRate": hitRateText.isEmpty ? "0%" : hitRateText
                case "cost": costText.isEmpty ? "\(Strings.currencySymbol)0" : costText
                default: ""
                }
                w += (t as NSString).size(withAttributes: [.font: font]).width
            }
            w += 4
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

    /// 构建弹出面板内容视图（带系统效果视图，自动跟随明暗模式）
    private func buildPopoverContentView(stats: DeepSeekStats) -> NSView {
        let scale = AppConfig.savedPopoverScale()
        let size = NSSize(width: AppConfig.popoverWidth * scale, height: AppConfig.popoverHeight * scale)
        let host = NSHostingView(rootView: StatsPopoverView(stats: stats))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        let effectView = NSVisualEffectView(frame: container.bounds)
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        container.addSubview(effectView)
        container.addSubview(host)
        return container
    }

    @objc private func menuIconChanged() {
        let showIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? false
        statusView?.showIcon = showIcon
        updateLabel()
    }

    @objc private func peakSettingsChanged() {
        updateLabel()
    }

    @objc private func indicatorChanged() {
        let show = UserDefaults.standard.object(forKey: Strings.Keys.showIndicator) as? Bool ?? false
        statusView?.showIndicator = show
        updateLabel()
    }

    @objc private func menuBarTextDisplayChanged() {
        let mode = UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance"
        statusView?.menuBarTextDisplay = mode
        updateLabel()
    }

    @objc private func menuBarColorChanged() {
        statusView?.needsDisplay = true
    }

    @objc private func currencyChanged() {
        refreshCacheHitRate()
        updateLabel()
    }

}
