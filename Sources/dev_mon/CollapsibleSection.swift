import SwiftUI

/// 可折叠区段：标题栏 + 展开内容，点击标题栏切换展开/收起。
struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if isExpanded {
                content()
                Divider().padding(.horizontal, 14)
            }
        }
    }
}
