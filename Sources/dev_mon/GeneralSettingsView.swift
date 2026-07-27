import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(Strings.Keys.showMenuIcon) var showMenuIcon: Bool = true
    @AppStorage(Strings.Keys.showIndicator) var showIndicator: Bool = true
    @AppStorage(Strings.Keys.menuBarTextDisplay) var menuBarTextDisplay: String = "balance"
    @AppStorage(Strings.Keys.appLanguage) var appLanguage: String = "auto"
    @AppStorage(Strings.Keys.currencySymbol) var currencySymbol: String = "¥"

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

            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear {
            menuBarColor = loadSavedColor()
        }
    }
}
