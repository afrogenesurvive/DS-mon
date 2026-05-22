import SwiftUI

struct ThresholdView: View {
    let stats: DeepSeekStats
    @State private var thresholdValue: Double = 20
    @State private var apiKeyInput = ""
    @State private var saved = false
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            formContent
        }
        .frame(width: 380, height: 280)
        .onAppear {
            thresholdValue = stats.threshold
            loadStoredKey()
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.secondary)
            Text("DS-mon 设置")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 预警阈值
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("余额预警阈值")
                        .font(.subheadline).bold()
                }

                HStack {
                    Text("余额低于此值时菜单栏红色闪烁提醒")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("¥")
                            .foregroundColor(.secondary)
                            .font(.body)
                        TextField("", value: $thresholdValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { stats.threshold = thresholdValue }
                        Stepper("", value: $thresholdValue, in: 1...500, step: 5)
                            .labelsHidden()
                            .onChange(of: thresholdValue) { _, newVal in
                                stats.threshold = newVal
                            }
                    }
                }
            }

            Divider()

            // API Key
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("API Key")
                        .font(.subheadline).bold()
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
                            Label("保存", systemImage: "checkmark.circle")
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
                        Text("已保存，正在刷新...")
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
                        Text("保存失败，请在钥匙串弹窗中点击「始终允许」")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(20)
        .animation(.easeInOut(duration: 0.2), value: saved)
        .animation(.easeInOut(duration: 0.2), value: saveFailed)
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