import SwiftUI

struct ProviderSettingsView: View {
    let stats: DeepSeekStats

    @State private var selectedDefaultModel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(Strings.providerTitle, systemImage: "cube.fill")
                .font(.body).bold()
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.accentColor)
                    Text("DeepSeek API Key")
                        .font(.body).bold()
                }

                let provider = ProviderManager.shared.provider
                HStack(spacing: 8) {
                    SecureField("sk-...", text: Binding(
                        get: { ProviderManager.shared.apiKey(for: provider) },
                        set: { newValue in
                            _ = ProviderManager.shared.saveAPIKey(newValue, for: provider)
                            stats.refresh()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                }

                Text(Strings.apiKeyHint("DeepSeek"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                    Text(Strings.defaultModelLabel2)
                        .font(.body).bold()
                }

                let models = ProviderConfig.default.pricingOverrides.keys.sorted()
                Picker("", selection: Binding(
                    get: { selectedDefaultModel ?? models.first ?? "" },
                    set: { newVal in
                        selectedDefaultModel = newVal.isEmpty ? nil : newVal
                        var cfg = ProviderConfig.load()
                        cfg.defaultModel = selectedDefaultModel
                        cfg.save()
                        ProviderManager.shared.load()
                    }
                )) {
                    ForEach(models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            ThresholdSectionView(stats: stats)

            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear {
            let cfg = ProviderConfig.load()
            selectedDefaultModel = cfg.defaultModel
        }
    }
}

struct ThresholdSectionView: View {
    let stats: DeepSeekStats

    @State private var thresholdValue: Double = 20
    @State private var maxBalanceValue: Double = AppConfig.defaultMaxBalanceAmount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.orange)
                Text(Strings.balanceAlert)
                    .font(.body).bold()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("¥").foregroundColor(.secondary)
                    TextField("", value: $thresholdValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { stats.threshold = thresholdValue }
                    Stepper("", value: $thresholdValue, in: 1...500, step: 5)
                        .labelsHidden()
                        .onChange(of: thresholdValue) { _, newVal in stats.threshold = newVal }
                }
                Text(Strings.alertHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("¥").foregroundColor(.secondary)
                        TextField("", value: $maxBalanceValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { saveMaxBalance() }
                        Stepper("", value: $maxBalanceValue, in: 10...10000, step: 10)
                            .labelsHidden()
                            .onChange(of: maxBalanceValue) { _, _ in saveMaxBalance() }
                    }
                    Text(Strings.maxBalanceHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            thresholdValue = stats.threshold
            maxBalanceValue = UserDefaults.standard.double(forKey: Strings.Keys.maxBalanceAmount)
            if maxBalanceValue <= 0 { maxBalanceValue = AppConfig.defaultMaxBalanceAmount }
        }
    }

    private func saveMaxBalance() {
        let val = max(10, min(maxBalanceValue, 10000))
        maxBalanceValue = val
        UserDefaults.standard.set(val, forKey: Strings.Keys.maxBalanceAmount)
    }
}
