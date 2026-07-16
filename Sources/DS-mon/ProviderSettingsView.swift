import SwiftUI

struct ProviderSettingsView: View {
    let stats: DeepSeekStats

    @State private var selectedDefaultModel: String?
    @State private var showBaseURLHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(Strings.providerTitle, systemImage: "cube.fill")
                    .font(.body).bold()
                Spacer()
                Button(action: { showBaseURLHelp.toggle() }) {
                    Image(systemName: "questionmark.circle")
                        .font(.body)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showBaseURLHelp, arrowEdge: .trailing) {
                    BaseURLHelpView(providers: ProviderManager.shared.providers)
                }
            }
            .padding(.top, 20)

            ForEach(ProviderManager.shared.providers, id: \.id) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.accentColor)
                        Text("\(provider.name) API Key")
                            .font(.body).bold()
                    }

                    HStack(spacing: 8) {
                        SecureField("sk-...", text: Binding(
                            get: { ProviderManager.shared.apiKey(for: provider.id) },
                            set: { newValue in
                                ProviderManager.shared.saveAPIKey(newValue, for: provider.id)
                                stats.refresh()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    }

                    Text(Strings.apiKeyHint(provider.name))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if provider.id != ProviderManager.shared.providers.last?.id {
                    Divider()
                }
            }

            Divider()

            ThresholdSectionView(stats: stats)

            Spacer()
        }
        .padding(.horizontal, 24)
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
                    Text(Strings.currencySymbol).foregroundColor(.secondary)
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
                        Text(Strings.currencySymbol).foregroundColor(.secondary)
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

struct BaseURLHelpView: View {
    let providers: [any Provider]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.baseURLHelpTitle)
                .font(.headline)
            Text(Strings.baseURLHelpDesc)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(configExample)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(maxHeight: 200)
        }
        .padding()
        .frame(width: 360)
    }

    private var configExample: String {
        var lines: [String] = ["{"]
        for (i, p) in providers.enumerated() {
            let comma = i < providers.count - 1 ? "," : ""
            lines.append("  \"\(p.opencodeProviderId)\": {")
            lines.append("    \"options\": {")
            lines.append("      \"baseURL\": \"http://localhost:18080\"")
            lines.append("    }")
            lines.append("  }\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}
