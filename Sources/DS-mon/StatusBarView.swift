import Cocoa

// MARK: - 菜单栏自定义视图

/// 三条 LED 条阵列
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
    var costText: String = ""

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

    func update(balanceRatio: Double, balanceAmount: String = "", hitRateText: String = "", costText: String = "", isError: Bool, isLowAlerting: Bool, blinkOn: Bool, isWarning: Bool = false) {
        self.balanceRatio = balanceRatio
        self.balanceAmount = balanceAmount
        self.costText = costText
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
        let textModes = (UserDefaults.standard.string(forKey: Strings.Keys.menuBarTextDisplay) ?? "balance")
            .components(separatedBy: ",").filter { !$0.isEmpty }
        let baseColor: NSColor = isDarkMode ? NSColor.white : NSColor.black
        let font = NSFont.menuFont(ofSize: 0)

        for (i, mode) in textModes.enumerated() {
            if i > 0 {
                let sep = " | " as NSString
                let sepAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor.withAlphaComponent(0.3)]
                let sepSize = sep.size(withAttributes: sepAttr)
                sep.draw(at: NSPoint(x: cursorX, y: (barH - sepSize.height) / 2), withAttributes: sepAttr)
                cursorX += sepSize.width
            }

            let text: String
            let color: NSColor
            switch mode {
            case "balance":
                text = balanceAmount
                color = isLowAlerting
                    ? (blinkOn ? NSColor.systemRed : NSColor.systemRed.withAlphaComponent(0.3))
                    : baseColor
            case "hitRate":
                text = hitRateText.isEmpty ? "0%" : hitRateText
                color = baseColor
            case "cost":
                text = costText.isEmpty ? "¥0" : costText
                color = baseColor
            default:
                text = ""
                color = baseColor
            }

            if !text.isEmpty {
                let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let s = text as NSString
                let size = s.size(withAttributes: attr)
                s.draw(at: NSPoint(x: cursorX, y: (barH - size.height) / 2), withAttributes: attr)
                cursorX += size.width
            }
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

