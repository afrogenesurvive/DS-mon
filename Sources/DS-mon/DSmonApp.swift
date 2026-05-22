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

    func setup() {
        guard statusItem == nil, let s = stats else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let icon = createMenuBarIcon() {
            statusItem?.button?.image = icon
        }

        let host = NSHostingView(rootView: StatsPopoverView(stats: s))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 250)

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 240, height: 250)
        popover?.contentViewController = NSViewController()
        popover?.contentViewController?.view = host
        popover?.behavior = .transient

        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)

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
            window.title = "余额预警"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 310))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        guard let btn = statusItem?.button, let pop = popover else { return }
        if pop.isShown { pop.performClose(nil) }
        else { pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) }
    }

    private func updateLabel() {
        guard let s = stats, let btn = statusItem?.button else { return }
        let text = s.balanceText
        let color: NSColor = s.isLowBalance ? (s.blinkOn ? .red : .gray) : .labelColor
        btn.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func createMenuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "dslogo", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return nil }
        let pixels = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        for i in 0..<(width * height) {
            let offset = i * 4
            let r = pixels[offset]
            let g = pixels[offset + 1]
            let b = pixels[offset + 2]
            let a = pixels[offset + 3]

            let isWhite = r > 220 && g > 220 && b > 220 && a > 200

            if isWhite {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 0
            } else {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }

        guard let newCGImage = context.makeImage() else { return nil }
        let icon = NSImage(cgImage: newCGImage, size: NSSize(width: 22, height: 22))
        icon.isTemplate = true
        return icon
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
        if stats.isLoading { return "查询中..." }
        if stats.errorMessage != nil { return "异常" }
        return "正常"
    }

    private var statusBadgeBackground: Color {
        if stats.isLoading { return Color.gray.opacity(0.1) }
        if stats.errorMessage != nil { return Color.orange.opacity(0.1) }
        if stats.isLowBalance { return Color.red.opacity(0.08) }
        return Color.green.opacity(0.1)
    }

    private var balanceSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("当前余额")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("¥")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(stats.balanceText.replacingOccurrences(of: "¥", with: ""))
                        .font(.system(size: 28, weight: .bold))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var balanceColor: Color {
        if stats.isLowBalance { return stats.blinkOn ? .red : .red.opacity(0.4) }
        return Color(nsColor: .labelColor)
    }

    private var infoSection: some View {
        VStack(spacing: 6) {
            infoRow(icon: "bell.fill", iconColor: .orange, label: "预警线", value: String(format: "¥%.0f", stats.threshold), valueColor: .orange)
            infoRow(icon: "cube.2.fill", iconColor: .blue, label: "可用模型", value: stats.modelsText)
            if let error = stats.errorMessage {
                infoRow(icon: "exclamationmark.triangle.fill", iconColor: .orange, label: "错误", value: error, valueColor: .orange)
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
        HStack(spacing: 2) {
            Text(stats.lastUpdate)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            Spacer()

            actionButton(icon: "arrow.clockwise", label: "刷新", color: .blue) {
                stats.refresh()
            }
            actionButton(icon: "gearshape", label: "设置", color: .secondary) {
                StatusBarController.shared.showSettings()
            }
            actionButton(icon: "power", label: "退出", color: .red) {
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
    }
}