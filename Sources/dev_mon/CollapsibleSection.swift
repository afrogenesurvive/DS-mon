import SwiftUI

/// 可折叠区段：标题栏 + 展开内容，点击标题栏切换展开/收起。
///
/// 默认尺寸是 popover 的小号样式；设置窗口通过 `iconSize` / `titleFont` /
/// `horizontalPadding` 覆盖为常规尺寸。
struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    var iconSize: CGFloat = 9
    var titleFont: Font = .system(size: 10, weight: .semibold)
    var horizontalPadding: CGFloat = 14
    var showsDivider: Bool = true
    /// 标题栏右侧的常驻小附件（如运行状态点），折叠时依然可见。
    var accessory: AnyView? = nil
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: iconSize))
                        .foregroundColor(.secondary)
                        .frame(width: iconSize + 5)
                    Text(title)
                        .font(titleFont)
                        .foregroundColor(.primary)
                    Spacer()
                    if let accessory {
                        accessory
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: max(8, iconSize - 1)))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isExpanded {
                content()
                if showsDivider {
                    Divider().padding(.horizontal, horizontalPadding)
                }
            }
        }
    }
}

/// 「全部展开 / 全部收起」按钮（**单个图标**，按当前状态在两者之间切换）。
///
/// 放在含多个可折叠区段的页面标题行右侧：作用域未全展开时显示「全部展开」，
/// 已全展开时显示「全部收起」；点击把作用域内所有区段设为相反状态。
struct SectionExpandControls: View {
    var iconSize: CGFloat = 10
    /// 当前作用域是否已全部展开 —— 决定图标与提示。
    let allExpanded: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(hovering ? .primary : .secondary)
                .frame(width: iconSize + 6, height: iconSize + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(allExpanded ? Strings.sectionsCollapseAll : Strings.sectionsExpandAll)
    }
}
