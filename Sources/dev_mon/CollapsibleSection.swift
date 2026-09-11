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
