import SwiftUI

struct ThresholdView: View {
    let stats: DeepSeekStats

    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general  = "通用"
        case provider = "DeepSeek"
        case services = "服务"
        case about    = "关于"

        var icon: String {
            switch self {
            case .general:  return "switch.2"
            case .provider: return "cube.fill"
            case .services: return "network"
            case .about:    return "info.circle"
            }
        }

        var displayName: String {
            switch self {
            case .general:  return Strings.settingsTabGeneral
            case .provider: return "DeepSeek"
            case .services: return Strings.settingsTabServices
            case .about:    return Strings.settingsTabAbout
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 16))
                            Text(tab.displayName)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedTab == tab ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().padding(.horizontal, 12)

            ScrollView {
                switch selectedTab {
                case .general:  GeneralSettingsView()
                case .provider: ProviderSettingsView(stats: stats)
                case .services: ServicesSettingsView(stats: stats)
                case .about:    AboutSettingsView()
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 520, height: 480)
    }
}
