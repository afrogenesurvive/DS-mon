import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable().frame(width: 64, height: 64)

            Text("DS-mon")
                .font(.title).bold()

            if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(ver)")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            if let ts = Bundle.main.infoDictionary?["DSMonBuildTimestamp"] as? String {
                Text(ts)
                    .font(.caption2)
                    .foregroundColor(.secondary).opacity(0.6)
            }

            Divider()
                .frame(width: 200)

            VStack(spacing: 8) {
                Label(Strings.aboutDesc, systemImage: "eye")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://github.com/cherno/DS-mon")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text("GitHub")
                        }
                        .font(.caption)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
