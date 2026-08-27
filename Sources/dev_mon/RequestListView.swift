import SwiftUI

struct RequestListView: View {
    let frameWidth: CGFloat
    let providerId: String?
    let since: Date?
    @State private var records: [UsageRecord] = []

    @State private var sortKey = "time"
    @State private var sortAsc = false

    private var sortedRecords: [UsageRecord] {
        records.sorted { a, b in
            switch sortKey {
            case "client":
                let ca = clientLabel(for: a.userAgent)
                let cb = clientLabel(for: b.userAgent)
                return sortAsc ? ca < cb : ca > cb
            case "model":
                return sortAsc ? a.model < b.model : a.model > b.model
            case "status":
                return sortAsc ? a.statusCode < b.statusCode : a.statusCode > b.statusCode
            default:
                return sortAsc ? a.timestamp < b.timestamp : a.timestamp > b.timestamp
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                sortableHeader("Time", key: "time", width: 48, align: .leading)
                sortableHeader("Client", key: "client", width: 64, align: .leading)
                sortableHeader("Model", key: "model", width: nil, align: .leading)
                sortableHeader("Status", key: "status", width: 36, align: .trailing)
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
                    LazyVStack(spacing: 0) {
                        ForEach(sortedRecords, id: \.uuid) { record in
                            requestRow(record)
                            if record.uuid != sortedRecords.last?.uuid {
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
        .onChange(of: providerId ?? "") { _, _ in loadRecords() }
        .onChange(of: since?.timeIntervalSince1970 ?? 0) { _, _ in loadRecords() }
    }

    @ViewBuilder
    private func sortableHeader(_ title: String, key: String, width: CGFloat?, align: Alignment) -> some View {
        let label = HStack(spacing: 2) {
            Text(title)
            if sortKey == key {
                Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7))
            }
        }
        if let width {
            Button {
                toggleSort(key)
            } label: {
                label.frame(width: width, alignment: align)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        } else {
            Button {
                toggleSort(key)
            } label: {
                label.frame(maxWidth: .infinity, alignment: align)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

    private func toggleSort(_ key: String) {
        if sortKey == key {
            sortAsc.toggle()
        } else {
            sortKey = key
            sortAsc = false
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
            records = await UsageStore.shared.recentRecords(limit: 50, providerId: providerId, since: since)
        }
    }
}
