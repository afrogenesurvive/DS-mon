import SwiftUI

struct ThresholdView: View {
    let stats: DeepSeekStats
    @State private var thresholdValue: Double = 20
    @State private var apiKeyInput = ""
    @State private var saved = false
    @State private var saveFailed = false
    @AppStorage("app_language") private var appLanguage: String = "auto"

    var body: some View {
        VStack(spacing: 0) {
            thresholdSection
            Divider().padding(.horizontal, 16)
            apiKeySection
            Divider().padding(.horizontal, 16)
            languageSection
        }
        .frame(width: 440)
        .onAppear {
            thresholdValue = stats.threshold
            loadStoredKey()
        }
    }

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
                Text(Strings.balanceAlert)
                    .font(.body).bold()
                Spacer()
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("¥")
                        .foregroundColor(.secondary)
                    TextField("", value: $thresholdValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { stats.threshold = thresholdValue }
                    Stepper("", value: $thresholdValue, in: 1...500, step: 5)
                        .labelsHidden()
                        .onChange(of: thresholdValue) { _, newVal in
                            stats.threshold = newVal
                        }
                }

                Text(Strings.alertHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .foregroundColor(.blue)
                Text(Strings.apiKeyLabel)
                    .font(.body).bold()
                Spacer()
            }

            HStack(spacing: 8) {
                SecureField("sk-...", text: $apiKeyInput)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))

                if !apiKeyInput.isEmpty {
                    Button(action: saveKey) {
                        Label(Strings.saveButton, systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if saved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text(Strings.savedHint)
                        .foregroundColor(.green)
                        .font(.caption)
                }
                .transition(.opacity)
            }

            if saveFailed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(Strings.saveFailedHint)
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                .transition(.opacity)
            }
        }
        .padding(20)
        .animation(.easeInOut(duration: 0.2), value: saved)
        .animation(.easeInOut(duration: 0.2), value: saveFailed)
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundColor(.purple)
                Text(Strings.languageLabel)
                    .font(.body).bold()
                Spacer()
            }

            Picker("", selection: $appLanguage) {
                ForEach(Language.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: appLanguage) { _, _ in
                Strings.notifyLanguageChanged()
            }
        }
        .padding(20)
    }

    private func saveKey() {
        let ok = stats.saveAPIKey(apiKeyInput)
        if ok {
            saved = true
            saveFailed = false
            stats.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                saved = false
            }
        } else {
            saveFailed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                saveFailed = false
            }
        }
    }

    private func loadStoredKey() {
        apiKeyInput = DeepSeekStats.readAPIKeyFromKeychain()
    }
}
