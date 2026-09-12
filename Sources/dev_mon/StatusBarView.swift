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

    var showIcon: Bool = false {
        didSet { iconView.isHidden = !showIcon; needsDisplay = true }
    }
    var showIndicator: Bool = false
    /// 未读通知红点开关（设置项，默认开）。
    var showUnreadDot: Bool = true {
        didSet { if oldValue != showUnreadDot { needsDisplay = true } }
    }
    var menuBarTextDisplay: String = "balance"
    var hitRateText: String = ""
    var balanceAmount: String = ""
    var costText: String = ""
    /// 高峰/低谷状态点：nil = 不显示；true = 高峰（黄）；false = 低谷（绿）
    var isPeakHour: Bool?
    /// 菜单栏 "Peak" 文字芯片内容（DeepSeek：当前窗口 + 距下次切换倒计时）；非 DeepSeek 或未启用时为空。
    var peakText: String = ""
    /// 未读通知数：> 0 时在内容最左侧（leading 槽位）绘制**红点 + 红色数字徽标**。
    /// 与高峰/低谷点区分：leading 槽位在**左**、垂直居中、红底白字（数字徽标**无**描边）；
    /// 状态点在**右**、贴顶、黄/绿、带白色描边。
    var unreadAlertCount: Int = 0 {
        didSet { if oldValue != unreadAlertCount { needsDisplay = true } }
    }

    /// 未读红点是否点亮：设置开启且存在未读通知。
    /// 绘制与宽度计算共用此判定（`StatusBarController.applyLabel` 直接读它），避免两处漂移。
    var isUnreadDotOn: Bool { showUnreadDot && unreadAlertCount > 0 }

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

    // MARK: - 未读通知徽标

    // 尺寸算法放在这里并提供 static 接口，StatusBarController 预留宽度时直接复用，
    // 避免「绘制」与「宽度计算」两处各写一份而漂移。

    /// 徽标数字字体：等宽数字，位数变化时宽度不抖动。
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold)
    /// 徽标高度（视图高 18，垂直居中）。
    private static let badgeHeight: CGFloat = 11
    /// 徽标内左右内边距。
    private static let badgeHPad: CGFloat = 3.5
    /// 徽标与右侧内容之间的间距。
    private static let badgeGap: CGFloat = 3

    /// 未读红点直径 —— 与高峰/低谷点同尺寸，保持同一套视觉语言。
    static let unreadDotSize: CGFloat = 6
    /// 红点与右侧数字徽标之间的间距。
    static let unreadDotGap: CGFloat = 4

    /// 红点占用的 leading 槽位宽度（含与后续内容的间距）；未点亮时为 0（不占位）。
    static func unreadDotGutter(_ visible: Bool) -> CGFloat {
        visible ? unreadDotSize + unreadDotGap : 0
    }

    /// 徽标文本：超过 9 条显示 "9+"（菜单栏空间有限）。
    static func unreadBadgeText(_ count: Int) -> String {
        count > 9 ? "9+" : "\(max(count, 0))"
    }

    /// 徽标自身宽度；count <= 0 时为 0。
    static func unreadBadgeWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let text = unreadBadgeText(count) as NSString
        return ceil(text.size(withAttributes: [.font: badgeFont]).width + badgeHPad * 2)
    }

    /// 徽标占用的 leading 槽位总宽（含与内容的间距）；0 = 不占位。
    static func unreadBadgeGutter(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return unreadBadgeWidth(count) + badgeGap
    }

    /// 指示器区域总宽度（不含左右边距）

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.image = icon
        iconView.isEditable = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = CGRect(x: 1, y: 0, width: 18, height: 18)
        iconView.autoresizingMask = [.maxXMargin, .minYMargin]
        addSubview(iconView)

        let savedShowIcon = UserDefaults.standard.object(forKey: Strings.Keys.showMenuIcon) as? Bool ?? false
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

    func update(balanceRatio: Double, balanceAmount: String = "", hitRateText: String = "", costText: String = "", peakText: String = "", isError: Bool, isLowAlerting: Bool, blinkOn: Bool, isWarning: Bool = false) {
        self.balanceRatio = balanceRatio
        self.balanceAmount = balanceAmount
        self.costText = costText
        self.peakText = peakText
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
        


        // 内容基础起点：有图标时为 21（图标 x=1 宽 18 → maxX 19，再留 2pt），否则贴最左侧。
        let baseX: CGFloat = showIcon ? 21 : 2
        // leading 槽位：未读红点（左）→ 未读数字徽标（右）。任一存在都让内容整体右移，
        // 避免与图标 / 文字重叠；两者都不存在时不占位（菜单栏不会平白多出空隙）。
        let dotGutter = Self.unreadDotGutter(isUnreadDotOn)
        let leftX: CGFloat = baseX + dotGutter + Self.unreadBadgeGutter(unreadAlertCount)
        var cursorX = leftX

        // ── 未读红点（红底 + 白描边圆点，垂直居中；无未读 / 关闭设置时不绘制）──
        if isUnreadDotOn {
            let size = Self.unreadDotSize
            let dotRect = CGRect(x: baseX + 1, y: (barH - size) / 2, width: size, height: size)
            drawStatusDot(ctx: ctx, color: .systemRed, dotRect: dotRect)
        }

        // ── 未读通知徽标（红底白字胶囊，垂直居中）──
        if unreadAlertCount > 0 {
            drawUnreadBadge(ctx: ctx, x: baseX + 1 + dotGutter, barH: barH)
        }

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
            .components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" && !($0 == "peak" && peakText.isEmpty) }
        let baseColor: NSColor = {
            if let data = UserDefaults.standard.data(forKey: Strings.Keys.menuBarColor),
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                return color
            }
            return isDarkMode ? NSColor.white : NSColor.black
        }()
        let font = NSFont.menuFont(ofSize: 0)
        var textDrawn = false

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
                text = costText.isEmpty ? "\(Strings.currencySymbol)0" : costText
                color = baseColor
            case "peak":
                text = peakText
                color = DeepSeekPricing.isPeak() ? NSColor.systemOrange : NSColor.systemGreen
            default:
                text = ""
                color = baseColor
            }

            if !text.isEmpty {
                textDrawn = true
                let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let s = text as NSString
                let size = s.size(withAttributes: attr)
                s.draw(at: NSPoint(x: cursorX, y: (barH - size.height) / 2), withAttributes: attr)
                cursorX += size.width
            }
        }

        // ── 高峰/低谷状态点：贴文字块右上角；无文字但有图标时回退到图标右上角 ──
        if let peak = isPeakHour {
            let dotSize: CGFloat = 6
            if textDrawn {
                let dotRect = CGRect(x: cursorX - dotSize - 1,
                                     y: barH - dotSize - 1,
                                     width: dotSize, height: dotSize)
                drawPeakDot(ctx: ctx, peak: peak, dotRect: dotRect)
            } else if showIcon {
                let iconFrame = iconView.frame
                let dotRect = CGRect(x: iconFrame.maxX - dotSize - 1,
                                     y: iconFrame.maxY - dotSize - 1,
                                     width: dotSize, height: dotSize)
                drawPeakDot(ctx: ctx, peak: peak, dotRect: dotRect)
            }
        }
    }

    /// 未读通知徽标：红底白字胶囊，垂直居中。
    /// 颜色（红 / 黄绿）、位置（左 / 右）、描边（无 / 有白描边）与高峰/低谷点都不同，不会混淆。
    private func drawUnreadBadge(ctx: CGContext, x: CGFloat, barH: CGFloat) {
        let label = Self.unreadBadgeText(unreadAlertCount) as NSString
        let attr: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: NSColor.white]
        let textSize = label.size(withAttributes: attr)
        let h = Self.badgeHeight
        let w = Self.unreadBadgeWidth(unreadAlertCount)
        let rect = CGRect(x: x, y: (barH - h) / 2, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)

        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        // 数字裁剪在胶囊内并居中绘制。
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        label.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                               y: rect.midY - textSize.height / 2),
                   withAttributes: attr)
        ctx.restoreGState()
    }

    /// 状态点通用绘制：彩色实心圆 + 白色描边环（深浅色菜单栏下都清晰）。
    /// 高峰/低谷点与未读通知红点共用，保证两者尺寸与描边完全一致。
    private func drawStatusDot(ctx: CGContext, color: NSColor, dotRect: CGRect) {
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: dotRect.insetBy(dx: -1, dy: -1))
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: dotRect)
    }

    /// 高峰/低谷点：黄色 = 高峰；绿色 = 低谷。
    private func drawPeakDot(ctx: CGContext, peak: Bool, dotRect: CGRect) {
        drawStatusDot(ctx: ctx, color: peak ? .systemYellow : .systemGreen, dotRect: dotRect)
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

