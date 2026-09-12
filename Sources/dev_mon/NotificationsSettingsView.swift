import SwiftUI

/// Settings → Notifications：把所有通知开关集中成一张可勾选列表。
///
/// 这里用的是**同一批 UserDefaults 键**，所以与 General / Services 页里的
/// 行内开关完全同步（两边改任一处都能立即生效）。
struct NotificationsSettingsView: View {

    @AppStorage(Strings.Keys.peakNotificationEnabled) private var peakNotify: Bool = false
    @AppStorage(Strings.Keys.balanceAlertEnabled) private var balanceAlert: Bool = false
    @AppStorage(Strings.Keys.tunnelDownNotificationEnabled) private var tunnelDownAlert: Bool = true
    @AppStorage(Strings.Keys.netlifyDeployNotifyEnabled) private var netlifyDeployAlert: Bool = true
    @AppStorage(Strings.Keys.localDBsNotifyEnabled) private var localDBsAlert: Bool = true
    @AppStorage(Strings.Keys.repoStoresNotifyEnabled) private var repoStoresAlert: Bool = true
    @AppStorage(Strings.Keys.awsRunNotifyEnabled) private var awsRunAlert: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .foregroundColor(.orange)
                Text(Strings.notificationsSection).font(.body).bold()
                Spacer()
            }

            Text(Strings.notificationsHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                row(isOn: $awsRunAlert,
                    icon: "clock.badge.exclamationmark",
                    color: .orange,
                    label: Strings.notifyAWSRunningLabel,
                    hint: Strings.notifyAWSRunningHint)

                row(isOn: $balanceAlert,
                    icon: "yensign.circle.fill",
                    color: .orange,
                    label: Strings.balanceAlertLabel,
                    hint: Strings.balanceAlertHint)

                row(isOn: $peakNotify,
                    icon: "sun.max.fill",
                    color: .yellow,
                    label: Strings.peakNotifyLabel,
                    hint: Strings.notifyPeakHint)

                row(isOn: $tunnelDownAlert,
                    icon: "cloud.bolt.rain.fill",
                    color: .red,
                    label: Strings.tunnelDownNotifyLabel,
                    hint: Strings.tunnelDownNotifyHint)

                row(isOn: $netlifyDeployAlert,
                    icon: "diamond.fill",
                    color: .teal,
                    label: Strings.netlifyDeployNotifyLabel,
                    hint: Strings.netlifyDeployNotifyHint)

                row(isOn: $localDBsAlert,
                    icon: "cylinder.split.1x2",
                    color: .teal,
                    label: Strings.localDBsNotifyLabel,
                    hint: Strings.localDBsNotifyHint)

                row(isOn: $repoStoresAlert,
                    icon: "shippingbox",
                    color: .indigo,
                    label: Strings.repoStoresNotifyLabel,
                    hint: Strings.repoStoresNotifyHint)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    AppAlertCenter.fire(.test,
                                        title: Strings.alertTestTitle,
                                        body: Strings.alertTestBody)
                } label: {
                    Label(Strings.notificationsSendTestLabel, systemImage: "bell.badge")
                        .font(.callout)
                }
                .buttonStyle(.bordered)

                Text(Strings.notificationsSendTestHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text(Strings.notificationsSessionNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
    }

    /// 一行勾选：复选框 + 图标 + 标题 + 说明。
    @ViewBuilder
    private func row(isOn: Binding<Bool>, icon: String, color: Color,
                     label: String, hint: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.callout)
                    Text(hint).font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
