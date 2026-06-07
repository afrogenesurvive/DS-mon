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
        statusItem?.length = 80

        updateLabel()

        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuIconChanged), name: .showMenuIconDidChange, object: nil)

        let host = NSHostingView(rootView: StatsPopoverView(stats: s))
        host.frame = NSRect(x: 0, y: 0, width: 290, height: 500)

        // 不透明背景
        let container = NSVisualEffectView(frame: host.frame)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.addSubview(host)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 290, height: 500),
                              styleMask: [.borderless, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = container
        window.level = .popUpMenu
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.delegate = self
        popoverWindow = window

        updateLabel()
        startLabelObservation()
    }

    /// 通过 Observation 跟踪状态变化，替代轮询 Timer
    private func startLabelObservation() {
        guard let stats else { return }
        withObservationTracking {
            _ = stats.balance
            _ = stats.blinkOn
            _ = stats.errorMessage
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateLabel()
                self?.startLabelObservation()
            }
        }
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
            window.setContentSize(NSSize(width: 500, height: 490))
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
            DispatchQueue.main.async { self?.closePopover() }
        }
    }

    private func updateLabel() {
        guard let s = stats else { return }
        statusView?.update(stats: s)

        let statusStr: NSString
        if s.errorMessage != nil { statusStr = Strings.statusError as NSString }
        else if s.isLowBalance { statusStr = Strings.statusLowBalance as NSString }
        else { statusStr = Strings.statusNormal as NSString }
        let textW = statusStr.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        let dotTextW = CGFloat(7 + 4) + textW
        let amtW = (s.balanceText as NSString).size(
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
        ).width
        let showIcon = UserDefaults.standard.object(forKey: "show_menu_icon") as? Bool ?? true
        let iconWidth: CGFloat = showIcon ? (22 + 4) : 0
        let w = CGFloat(2) + iconWidth + max(dotTextW, amtW) + 4
        statusItem?.length = w
        statusView?.setFrameSize(NSSize(width: w, height: statusView?.frame.height ?? 22))
    }

    @objc private func languageChanged() {
        updateLabel()
        // Rebuild popover for language refresh
        guard let s = stats else { return }
        let host = NSHostingView(rootView: StatsPopoverView(stats: s))
        host.frame = NSRect(x: 0, y: 0, width: 290, height: 500)
        let container = NSVisualEffectView(frame: host.frame)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.addSubview(host)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        popoverWindow?.contentView = container
    }

    @objc private func menuIconChanged() {
        let showIcon = UserDefaults.standard.object(forKey: "show_menu_icon") as? Bool ?? true
        statusView?.showIcon = showIcon
        updateLabel()
    }

}

// MARK: - 菜单栏自定义视图

@MainActor
class StatusBarView: NSView {
    weak var target: AnyObject?
    var action: Selector?

    private let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "dslogo", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let w = cgImage.width, h = cgImage.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let px = ctx.data else { return nil }
        let p = px.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in 0..<(w * h) {
            let o = i * 4
            let isW = p[o] > 220 && p[o+1] > 220 && p[o+2] > 220 && p[o+3] > 200
            if isW { p[o] = 0; p[o+1] = 0; p[o+2] = 0; p[o+3] = 0 }
            else { p[o] = 0; p[o+1] = 0; p[o+2] = 0; p[o+3] = 255 }
        }
        guard let n = ctx.makeImage() else { return nil }
        let ic = NSImage(cgImage: n, size: NSSize(width: 22, height: 22))
        ic.isTemplate = true
        return ic
    }()
    private let iconView = NSImageView()

    /// 菜单栏图标是否显示，由设置窗口 Toggle 控制
    var showIcon: Bool = true {
        didSet {
            iconView.isHidden = !showIcon
            needsDisplay = true
        }
    }

    // Cached stable state — never shows loading state
    private var cachedDotColor: NSColor = .systemGreen
    private var cachedStatusStr: NSString = Strings.statusNormal as NSString
    private var cachedAmtStr: NSString = ""
    private var cachedAmtColor: NSColor = .labelColor
    private var cachedTextColor: NSColor = .labelColor
    private var blinkOn_breath = true
    private var blinkFrameCount = 0
    private var blinkThreshold = 10
    override init(frame: NSRect) {
        super.init(frame: frame)

        iconView.image = icon
        iconView.isEditable = false
        iconView.frame = CGRect(x: 2, y: 0, width: 22, height: 22)
        iconView.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        addSubview(iconView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 10, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.blinkFrameCount += 1
                    if self.blinkFrameCount >= self.blinkThreshold {
                        self.blinkFrameCount = 0
                        self.blinkOn_breath.toggle()
                    }
                    self.display()
                }
            }
            RunLoop.current.add(t, forMode: .common)
        }

        // 启动时读取保存的图标显示状态（didSet 在 init 中不触发，手动设置）
        let savedShowIcon = UserDefaults.standard.object(forKey: "show_menu_icon") as? Bool ?? true
        showIcon = savedShowIcon
        iconView.isHidden = !savedShowIcon
    }

    required init?(coder: NSCoder) { nil }

    func update(stats: DeepSeekStats) {
        // Only update display state when NOT loading — avoids text flicker
        if !stats.isLoading {
            if stats.errorMessage != nil {
                cachedDotColor = .systemOrange
                cachedTextColor = .systemOrange
                cachedStatusStr = Strings.statusError as NSString
                blinkThreshold = 5
            } else if stats.isLowBalance {
                cachedDotColor = .systemRed
                cachedTextColor = .systemRed
                cachedStatusStr = Strings.statusLowBalance as NSString
                blinkThreshold = 5
            } else {
                cachedDotColor = .systemGreen
                cachedTextColor = .labelColor
                cachedStatusStr = Strings.statusNormal as NSString
                blinkThreshold = 10
            }
            cachedAmtColor = .labelColor
        }
        cachedAmtStr = stats.balanceText as NSString
    }

    override func mouseDown(with event: NSEvent) {
        if let target = target as? NSObject, let action = action {
            target.perform(action, with: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let barH = bounds.height
        guard barH > 0 else { return }

        let iconMaxX: CGFloat = showIcon ? 24 : 2

        let breathAlpha: CGFloat = blinkOn_breath ? 1.0 : 0.3
        let dotColorWithBreath = cachedDotColor.withAlphaComponent(breathAlpha)

        let isDark = effectiveAppearance.name == .darkAqua || effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resolvedTextColor: NSColor = cachedTextColor == .labelColor
            ? (isDark ? .white : .darkGray)
            : cachedTextColor.withAlphaComponent(breathAlpha)
        let resolvedAmtColor: NSColor = cachedAmtColor == .labelColor
            ? (isDark ? .white : .black)
            : cachedAmtColor.withAlphaComponent(breathAlpha)

        let textFont = NSFont.systemFont(ofSize: 10)
        let amtFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let textStr = NSAttributedString(string: cachedStatusStr as String, attributes: [
            .font: textFont, .foregroundColor: resolvedTextColor
        ])
        let amtStr = NSAttributedString(string: cachedAmtStr as String, attributes: [
            .font: amtFont, .foregroundColor: resolvedAmtColor
        ])

        let dotSize = CGSize(width: 7, height: 3)
        let textSize = textStr.size()
        let amtSize = amtStr.size()

        let textX = iconMaxX + 4
        let textW = max(dotSize.width + 4 + textSize.width, amtSize.width)
        let textH = amtSize.height + textSize.height - 2
        let textY = (barH - textH) / 2
        let textCX = textX + (textW - (dotSize.width + 4 + textSize.width)) / 2

        let dotX: CGFloat = textCX
        let halfDot: CGFloat = (textSize.height - dotSize.height) / 2
        let dotY: CGFloat = textY + amtSize.height - 2 + halfDot
        let dotRect = CGRect(x: dotX, y: dotY, width: dotSize.width, height: dotSize.height)
        drawStatusDot(in: dotRect, baseColor: dotColorWithBreath)

        textStr.draw(at: NSPoint(x: textCX + dotSize.width + 4, y: textY + amtSize.height - 2))
        amtStr.draw(at: NSPoint(x: textX + (textW - amtSize.width) / 2, y: textY))
    }

    /// 矩形指示灯：宽7高3，纯色填充，右下1px深色边缘，闪烁时浅绿外发光
    private func drawStatusDot(in rect: CGRect, baseColor: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
        let isAlerting = (cachedDotColor != .systemGreen) && blinkOn_breath

        // 外发光 — 仅异常闪烁时，浅绿 1px
        if isAlerting {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 1, color: NSColor.green.withAlphaComponent(0.6).cgColor)
            baseColor.setFill()
            path.fill()
            ctx.restoreGState()
        }

        // 主体纯色填充
        baseColor.setFill()
        path.fill()

        // 右下 1px 深色边缘（模拟立体感）
        let edgeColor = baseColor.blended(withFraction: 0.12, of: .black) ?? baseColor
        edgeColor.setFill()
        let rightEdge = NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height)
        NSBezierPath(rect: rightEdge).fill()
        let bottomEdge = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)
        NSBezierPath(rect: bottomEdge).fill()
    }
}
