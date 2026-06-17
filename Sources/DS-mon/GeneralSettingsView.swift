import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(Strings.Keys.showMenuIcon) var showMenuIcon: Bool = true
    @AppStorage(Strings.Keys.showIndicator) var showIndicator: Bool = true
    @AppStorage(Strings.Keys.menuBarTextDisplay) var menuBarTextDisplay: String = "balance"
    @AppStorage(Strings.Keys.appLanguage) var appLanguage: String = "auto"

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

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
