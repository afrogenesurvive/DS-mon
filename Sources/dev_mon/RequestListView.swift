import SwiftUI

struct RequestListView: View {
    let frameWidth: CGFloat
    @State private var records: [UsageRecord] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Time").frame(width: 48, alignment: .leading)
                Text("Client").frame(width: 64, alignment: .leading)
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            if records.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(records, id: \.uuid) { record in
                            requestRow(record)
                            if record.uuid != records.last?.uuid {
                                Divider().padding(.leading, 8)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: frameWidth, height: 120)
        .onAppear { loadRecords() }
        .onReceive(NotificationCenter.default.publisher(for: .usageRecorded)) { _ in
            loadRecords()
        }
    }

    private func requestRow(_ record: UsageRecord) -> some View {
        HStack(spacing: 6) {
            Text(Self.timeFormatter.string(from: record.timestamp))
                .frame(width: 48, alignment: .leading)

            Text(clientLabel(for: record.userAgent))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 64, alignment: .leading)

            Text(record.model)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            statusBadge(record.statusCode)
                .frame(width: 36, alignment: .trailing)
        }
        .font(.system(size: 8.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func clientLabel(for ua: String) -> String {
        if ua.contains("opencode") { return "opencode" }
        if ua.contains("Codex Desktop") { return "Codex Desktop" }
        if ua.isEmpty { return "—" }
        let parts = ua.split(separator: "/")
        if let first = parts.first { return String(first) }
        return "—"
    }

    private func statusBadge(_ code: Int) -> some View {
        let color: Color = code == 200 ? .green : (code >= 500 ? .red : .orange)
        return Text("\(code)")
            .foregroundColor(color)
    }

    private func loadRecords() {
        Task {
            records = await UsageStore.shared.recentRecords(limit: 5)
        }
    }
}
