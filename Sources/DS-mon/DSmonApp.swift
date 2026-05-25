import SwiftUI
import AppKit

@main
struct DSmonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static let sharedStats = DeepSeekStats()

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusBarController.shared.stats = Self.sharedStats
        StatusBarController.shared.setup()
    }
}

// MARK: - AppKit 状态栏

@MainActor
class StatusBarController: NSObject {
    static let shared = StatusBarController()
    var stats: DeepSeekStats?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var statusView: StatusBarView?

    func setup() {
        guard statusItem == nil, let s = stats else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusView = StatusBarView(frame: .zero)
        statusView?.target = self
        statusView?.action = #selector(togglePopover)
        statusItem?.view = statusView
        statusItem?.length = 80

        updateLabel()

        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuIconChanged), name: .showMenuIconDidChange, object: nil)

        let host = NSHostingView(rootView: StatsPopoverView(stats: s))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 280)

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 260, height: 280)
        popover?.contentViewController = NSViewController()
        popover?.contentViewController?.view = host
        popover?.behavior = .transient

        updateLabel()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLabel()
            }
        }
    }

    func showSettings() {
        if settingsWindow == nil, let s = stats {
            let view = ThresholdView(stats: s)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = Strings.settingsTitle
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 440, height: 460))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        guard let v = statusItem?.view, let pop = popover else { return }
        if pop.isShown { pop.performClose(nil) }
        else { pop.show(relativeTo: v.bounds, of: v, preferredEdge: .minY) }
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
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 280)
        popover?.contentViewController = NSViewController()
        popover?.contentViewController?.view = host
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
    }

    required init?(coder: NSCoder) { nil }

    func update(stats: DeepSeekStats) {
        // Only update display state when NOT loading — avoids text flicker
        if !stats.isLoading {
            if stats.errorMessage != nil {
                cachedDotColor = .systemOrange
                cachedStatusStr = Strings.statusError as NSString
                blinkThreshold = 5
            } else if stats.isLowBalance {
                cachedDotColor = .systemRed
                cachedStatusStr = Strings.statusLowBalance as NSString
                blinkThreshold = 5
            } else {
                cachedDotColor = .systemGreen
                cachedStatusStr = Strings.statusNormal as NSString
                blinkThreshold = 10
            }
            cachedAmtColor = stats.isLowBalance ? .systemRed : .labelColor
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
        let resolvedTextColor: NSColor = isDark ? .white : .darkGray
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

        let dotSize = CGSize(width: 7, height: 7)
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
        dotColorWithBreath.setFill()
        NSBezierPath(roundedRect: dotRect, xRadius: dotSize.width / 2, yRadius: dotSize.height / 2).fill()

        textStr.draw(at: NSPoint(x: textCX + dotSize.width + 4, y: textY + amtSize.height - 2))
        amtStr.draw(at: NSPoint(x: textX + (textW - amtSize.width) / 2, y: textY))
    }
}

// MARK: - SwiftUI 弹出内容

struct StatsPopoverView: View {
    let stats: DeepSeekStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.horizontal, 12)
            balanceSection
            Divider().padding(.horizontal, 12)
            infoSection
            Spacer()
            Divider().padding(.horizontal, 12)
            actionBar
        }
        .padding(.vertical, 12)
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "chart.pie.fill")
                .foregroundColor(.blue)
                .font(.caption)
            Text("DS-mon")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusIndicatorColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusBadgeBackground)
        .cornerRadius(8)
    }

    private var statusIndicatorColor: Color {
        if stats.isLoading { return .gray }
        if stats.errorMessage != nil { return .orange }
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return .green
    }

    private var statusText: String {
        if stats.isLoading { return Strings.badgeLoading }
        if stats.errorMessage != nil { return Strings.badgeError }
        return Strings.badgeNormal
    }

    private var statusBadgeBackground: Color {
        if stats.isLoading { return Color.gray.opacity(0.1) }
        if stats.errorMessage != nil { return Color.orange.opacity(0.1) }
        if stats.isLowBalance { return Color.red.opacity(0.08) }
        return Color.green.opacity(0.1)
    }

    private var balanceSection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 7, height: 7)
                        Text(Strings.currentBalance)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("¥")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(stats.balanceText.replacingOccurrences(of: "¥", with: ""))
                            .font(.system(size: 22, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(balanceColor)
                    }
                }

                Spacer()

                if stats.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20)
                }
            }

            if stats.grantedBalance > 0 || stats.toppedUpBalance > 0 {
                HStack(spacing: 16) {
                    Label(stats.grantedText, systemImage: "gift.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Label(stats.toppedUpText, systemImage: "creditcard.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusDotColor: Color {
        if stats.isLoading { return .gray }
        if stats.errorMessage != nil { return .orange }
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return .green
    }

    private var balanceColor: Color {
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return Color(nsColor: .labelColor)
    }

    private var infoSection: some View {
        VStack(spacing: 6) {
            infoRow(icon: "bell.fill", iconColor: .orange, label: Strings.thresholdLabel, value: String(format: "¥%.0f", stats.threshold), valueColor: .orange)
            infoRow(icon: "cube.2.fill", iconColor: .blue, label: Strings.availableModels, value: stats.modelsText)
            infoRow(icon: stats.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    iconColor: stats.isAvailable ? .green : .red,
                    label: Strings.accountStatus,
                    value: stats.availabilityText,
                    valueColor: stats.isAvailable ? .green : .red)
            if let error = stats.errorMessage {
                infoRow(icon: "exclamationmark.triangle.fill", iconColor: .orange, label: Strings.errorLabel, value: error, valueColor: .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func infoRow(icon: String, iconColor: Color, label: String, value: String, valueColor: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(iconColor)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            Text(stats.lastUpdate)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            Spacer()

            actionButton(icon: "arrow.clockwise", label: Strings.refresh, color: .blue) {
                stats.refresh()
            }
            actionButton(icon: "gearshape", label: Strings.settings, color: .secondary) {
                StatusBarController.shared.showSettings()
            }
            actionButton(icon: "power", label: Strings.quit, color: .red) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}