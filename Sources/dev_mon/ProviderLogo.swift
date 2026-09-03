import SwiftUI
import AppKit

/// 商标资源缓存 + 加载。资源名不带扩展名，支持 pdf / png（NSImage 不可靠地支持 svg，故不列入）。
@MainActor
enum ProviderLogoStore {
    /// 值为 nil 表示"已查过且不存在"，避免每次重绘重复读盘。
    private static var cache: [String: NSImage?] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let loaded = load(named: name)
        cache[name] = loaded
        return loaded
    }

    /// 与 StatusBarView 一致的查找顺序：先 Bundle.main（打包后的 .app），再 Bundle.module（SPM 直接运行）。
    private static func load(named name: String) -> NSImage? {
        for ext in ["pdf", "png"] {
            let url = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.module.url(forResource: name, withExtension: ext)
            if let url, let image = NSImage(contentsOf: url) {
                // 模板图使商标继承 foregroundColor，从而跟随选中(白)/未选中(着色)状态
                image.isTemplate = true
                return image
            }
        }
        return nil
    }
}

/// 提供商商标图标：优先使用打包的商标资源（模板渲染，跟随 foregroundColor），
/// 资源缺失时回退到 provider.iconName 对应的 SF Symbol，保证界面不留空白。
struct ProviderLogo: View {
    let provider: any Provider
    var size: CGFloat = 12

    var body: some View {
        if let logoAsset = provider.logoAsset,
           let image = ProviderLogoStore.image(named: logoAsset) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.iconName)
                .font(.system(size: size, weight: .medium))
        }
    }
}

/// 各提供商的强调色。未知提供商回退到蓝色。
func providerTint(_ providerId: String) -> Color {
    switch providerId {
    case "deepseek":  return .blue
    case "kimi":      return .indigo
    case "openai":    return .teal
    case "anthropic": return .orange
    case "zai":       return .purple
    default:          return .blue
    }
}
