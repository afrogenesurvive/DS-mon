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

        applyLabel(balanceRatio: ratio, balanceAmount: balanceText, hitRateText: hitRateText, costText: costText, isError: isError, isLow: isLow, blinkOn: blinkOn, isWarning: isWarning)
    }

    private func applyLabel(balanceRatio: Double, balanceAmount: String = "", hitRateText: String = "", costText: String = "", isError: Bool, isLow: Bool, blinkOn: Bool, isWarning: Bool = false) {
        statusView?.update(balanceRatio: balanceRatio, balanceAmount: balanceAmount, hitRateText: hitRateText, costText: costText, isError: isError, isLowAlerting: isLow, blinkOn: blinkOn, isWarning: isWarning)

        // 计算总宽度
        let showIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? true
        let showIndicator = UserDefaults.standard.object(forKey: Strings.Keys.showIndicator) as? Bool ?? true
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
                case "balance": balanceAmount.isEmpty ? "¥0" : balanceAmount
                case "hitRate": hitRateText.isEmpty ? "0%" : hitRateText
                case "cost": costText.isEmpty ? "¥0" : costText
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
        let host = NSHostingView(rootView: StatsPopoverView(stats: stats))
        host.frame = NSRect(x: 0, y: 0, width: AppConfig.popoverWidth, height: AppConfig.popoverHeight)
        let container = NSView(frame: host.frame)
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
