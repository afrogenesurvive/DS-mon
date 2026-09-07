import SwiftUI
import AppKit

/// 应用外观主题：System / Light / Dark。通过设置 NSApp.appearance 生效，
/// System 时置 nil（完全跟随 macOS 系统外观）。
enum Theme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return uiIsZH ? "跟随系统" : "System"
        case .light: return uiIsZH ? "浅色" : "Light"
        case .dark: return uiIsZH ? "深色" : "Dark"
        }
    }

    private var uiIsZH: Bool {
        let saved = UserDefaults.standard.string(forKey: Strings.Keys.appLanguage) ?? "auto"
        if saved == "auto" {
            let locale = Locale.preferredLanguages.first ?? "en"
            return locale.hasPrefix("zh-Hans") || locale == "zh-CN" || locale == "zh"
        }
        return saved == "zh-Hans"
    }

    static var current: Theme {
        Theme(rawValue: UserDefaults.standard.string(forKey: Strings.Keys.appTheme) ?? "") ?? .system
    }

    /// 读取已保存主题并应用到整个 app（nil = 跟随系统）。
    @MainActor
    static func apply() {
        let theme = current
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        UserDefaults.standard.set(theme.rawValue, forKey: Strings.Keys.appTheme)
    }

    @MainActor
    static func set(_ theme: Theme) {
        UserDefaults.standard.set(theme.rawValue, forKey: Strings.Keys.appTheme)
        apply()
        NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(Strings.Keys.showMenuIcon) var showMenuIcon: Bool = false
    @AppStorage(Strings.Keys.showIndicator) var showIndicator: Bool = false
    @AppStorage(Strings.Keys.menuBarTextDisplay) var menuBarTextDisplay: String = "balance"
    @AppStorage(Strings.Keys.appLanguage) var appLanguage: String = "auto"
    @AppStorage(Strings.Keys.appTheme) var appTheme: String = Theme.system.rawValue
    @AppStorage(Strings.Keys.currencySymbol) var currencySymbol: String = "¥"
    @AppStorage(Strings.Keys.showPeakDot) var showPeakDot: Bool = false
    @AppStorage(Strings.Keys.peakNotificationEnabled) var peakNotificationEnabled: Bool = false

    @State private var menuBarColor: Color = Color(nsColor: .labelColor)

    private func loadSavedColor() -> Color {
        if let data = UserDefaults.standard.data(forKey: Strings.Keys.menuBarColor),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return Color(nsColor: color)
        }
        return Color(nsColor: .labelColor) // auto
    }

    private func saveColor(_ color: Color) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: Strings.Keys.menuBarColor)
        }
        NotificationCenter.default.post(name: .menuBarColorDidChange, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(Strings.menuBarDisplay, systemImage: "menubar.rectangle")
                .font(.body).bold()
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $showMenuIcon) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").font(.caption)
                        Text(Strings.menuIconLabel)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showMenuIcon) {
                    NotificationCenter.default.post(name: .showMenuIconDidChange, object: nil)
                }

                Toggle(isOn: $showIndicator) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill").font(.caption)
                        Text(Strings.indicatorLabel)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showIndicator) {
                    NotificationCenter.default.post(name: .showIndicatorDidChange, object: nil)
                }

                Toggle(isOn: $showPeakDot) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.max.fill").font(.caption)
                        Text(Strings.peakDotLabel)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showPeakDot) {
                    NotificationCenter.default.post(name: .peakSettingsDidChange, object: nil)
                }

                Toggle(isOn: $peakNotificationEnabled) {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge.fill").font(.caption)
                        Text(Strings.peakNotifyLabel)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: peakNotificationEnabled) {
                    PeakNotifier.scheduleNextTransition()
                }

                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft").font(.caption)
                    Text(Strings.textDisplayLabel)

                    var modes = menuBarTextDisplay.components(separatedBy: ",").filter { !$0.isEmpty && $0 != "none" }
                    let hasBalance = modes.contains("balance")
                    let hasHitRate = modes.contains("hitRate")
                    let hasCost = modes.contains("cost")

                    Button(action: {
                        if hasBalance { modes.removeAll { $0 == "balance" } } else { modes.append("balance") }
                        menuBarTextDisplay = modes.isEmpty ? "none" : modes.joined(separator: ",")
                        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
                    }) {
                        Text(Strings.balanceLabel)
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(hasBalance ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(hasBalance ? .white : .primary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        if hasHitRate { modes.removeAll { $0 == "hitRate" } } else { modes.append("hitRate") }
                        menuBarTextDisplay = modes.isEmpty ? "none" : modes.joined(separator: ",")
                        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
                    }) {
                        Text(Strings.hitRateLabel)
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(hasHitRate ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(hasHitRate ? .white : .primary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        if hasCost { modes.removeAll { $0 == "cost" } } else { modes.append("cost") }
                        menuBarTextDisplay = modes.isEmpty ? "none" : modes.joined(separator: ",")
                        NotificationCenter.default.post(name: .menuBarTextDisplayDidChange, object: nil)
                    }) {
                        Text(Strings.costLabel)
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(hasCost ? Color.accentColor : Color.gray.opacity(0.12))
                            .foregroundColor(hasCost ? .white : .primary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }

            Divider()

            Label(Strings.menuBarColorLabel, systemImage: "paintpalette.fill")
                .font(.body).bold()

            HStack(spacing: 8) {
                ColorPicker(Strings.menuBarColorLabel, selection: Binding(
                    get: { menuBarColor },
                    set: { newColor in
                        menuBarColor = newColor
                        saveColor(newColor)
                    }
                ))
                .labelsHidden()

                Button(Strings.menuBarColorAuto) {
                    menuBarColor = Color(nsColor: .labelColor)
                    UserDefaults.standard.removeObject(forKey: Strings.Keys.menuBarColor)
                    NotificationCenter.default.post(name: .menuBarColorDidChange, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(menuBarColor == Color(nsColor: .labelColor) ? Color.accentColor : .gray.opacity(0.2))

                Button(Strings.menuBarColorWhite) {
                    let c = Color.white
                    menuBarColor = c
                    saveColor(c)
                }
                .buttonStyle(.borderedProminent)
                .tint(menuBarColor == Color.white ? Color.accentColor : .gray.opacity(0.2))

                Button(Strings.menuBarColorBlack) {
                    let c = Color.black
                    menuBarColor = c
                    saveColor(c)
                }
                .buttonStyle(.borderedProminent)
                .tint(menuBarColor == Color.black ? Color.accentColor : .gray.opacity(0.2))

                Spacer()
            }

            Divider()

            Label(Strings.currencyLabel, systemImage: "dollarsign.circle.fill")
                .font(.body).bold()

            HStack(spacing: 12) {
                Button(action: {
                    currencySymbol = "¥"
                    NotificationCenter.default.post(name: .currencyDidChange, object: nil)
                }) {
                    Text("¥ CNY")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(currencySymbol == "¥" ? Color.accentColor : .gray.opacity(0.2))

                Button(action: {
                    currencySymbol = "$"
                    NotificationCenter.default.post(name: .currencyDidChange, object: nil)
                }) {
                    Text("$ USD")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(currencySymbol == "$" ? Color.accentColor : .gray.opacity(0.2))

                Spacer()
            }

            Divider()

            Label(Strings.languageLabel, systemImage: "globe")
                .font(.body).bold()

            Picker(Strings.languageLabel, selection: $appLanguage) {
                ForEach(Language.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: appLanguage) {
                Strings.notifyLanguageChanged()
            }

            Divider()

            Label(Strings.themeLabel, systemImage: "circle.lefthalf.filled")
                .font(.body).bold()

            Picker(Strings.themeLabel, selection: $appTheme) {
                ForEach(Theme.allCases) { theme in
                    Text(theme.displayName).tag(theme.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: appTheme) { _, newVal in
                Theme.set(Theme(rawValue: newVal) ?? .system)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear {
            menuBarColor = loadSavedColor()
            Theme.apply()
        }
    }
}
