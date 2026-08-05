import SwiftUI
import Foundation

/// 按来源（sourceIP）+ 时间范围过滤的逐条请求列表（Source Usage → Individual 模式）
struct SourceRequestListView: View {
    let frameWidth: CGFloat
    var sourceIP: String = ""
    var since: Date?

    @State private var records: [UsageRecord] = []
    @State private var isLoading = false
    @State private var reloadTask: Task<Void, Never>?

    @State private var sortKey = "time"
    @State private var sortAsc = false

    private var sortedRecords: [UsageRecord] {
        records.sorted { a, b in
            switch sortKey {
            case "source":
                let sa = sourceName(a), sb = sourceName(b)
                return sortAsc ? sa < sb : sa > sb
            case "model":
                return sortAsc ? a.model < b.model : a.model > b.model
            case "tok":
                return sortAsc ? a.totalTokens < b.totalTokens : a.totalTokens > b.totalTokens
            case "status":
                return sortAsc ? a.statusCode < b.statusCode : a.statusCode > b.statusCode
            default:
                return sortAsc ? a.timestamp < b.timestamp : a.timestamp > b.timestamp
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd:MM:yyyy HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                sortableHeader("Time", key: "time", width: 70, align: .leading)
                sortableHeader("Source", key: "source", width: 52, align: .leading)
                sortableHeader("Model", key: "model", width: nil, align: .leading)
                sortableHeader("Tok", key: "tok", width: 36, align: .trailing)
                sortableHeader("Status", key: "status", width: 32, align: .trailing)
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                Text(Strings.noUsageData)
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
        .frame(width: frameWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { loadRecords() }
        .onChange(of: sourceIP) { _, _ in loadRecords() }
        .onChange(of: since) { _, _ in loadRecords() }
        .onReceive(NotificationCenter.default.publisher(for: .usageRecorded)) { _ in
            reloadTask?.cancel()
            reloadTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                loadRecords()
            }
        }
    }

    private func requestRow(_ record: UsageRecord) -> some View {
        HStack(spacing: 6) {
            Text(Self.timeFormatter.string(from: record.timestamp))
                .font(.system(size: 7).monospacedDigit())
                .frame(width: 70, alignment: .leading)

            Text(sourceName(record))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 52, alignment: .leading)

            Text(record.model)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(record.totalTokens)")
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)

            statusBadge(record.statusCode)
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 8.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func sourceName(_ record: UsageRecord) -> String {
        record.sourceIP.isEmpty ? Strings.localSourceLabel : record.sourceIP
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

    private func statusBadge(_ code: Int) -> some View {
        let color: Color = code == 200 ? .green : (code >= 500 ? .red : .orange)
        return Text("\(code)")
            .foregroundColor(color)
    }

    private func loadRecords() {
        isLoading = true
        Task {
            let result = await UsageStore.shared.records(
                since: since,
                sourceIP: sourceIP,
                limit: 2000,
                perSourceLimit: sourceIP.isEmpty ? 50 : nil
            )
            records = result
            isLoading = false
        }
    }
}
