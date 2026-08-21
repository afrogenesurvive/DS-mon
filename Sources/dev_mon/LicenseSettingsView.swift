import SwiftUI

/// 席位注册表设置：管理 sub/kid/exp/revoked，以及可选注册表文件路径。
/// DS-mon 作为 Hybrid 授权权威，按 sub 回答吊销状态（无签名校验）。
struct LicenseSettingsView: View {
    @State private var seats: [SeatRecord] = SeatRegistry.shared.seats
    @State private var filePath: String = SeatRegistry.shared.registryFilePath
    @State private var licenseSourcePath: String = SeatRegistry.defaultLicensesSourceURL.path
    @State private var checkIntervalHours: Double = SeatRegistry.shared.checkIntervalHours
    @State private var checkResult: String?
    @State private var checkError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                Text(Strings.licenseSection)
                    .font(.body).bold()
                Spacer()
                Text(Strings.licenseSeatCount(seats.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            if seats.isEmpty {
                Text(Strings.licenseNoSeats)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(seats) { seat in
                            seatRow(seat)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Divider()

            HStack(spacing: 8) {
                Text(Strings.licenseFileLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("~/path/to/seats.json", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: filePath) { _, newVal in
                        SeatRegistry.shared.setFilePath(newVal)
                        seats = SeatRegistry.shared.seats
                    }
            }
            Text(Strings.licenseFileHint)
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            Text(Strings.licenseCheckTitle)
                .font(.callout).bold()

            HStack(spacing: 8) {
                Text(Strings.licenseSourceLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("~/.../seats.json", text: $licenseSourcePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: licenseSourcePath) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: SeatRegistry.checkSourceKey)
                    }
            }

            HStack(spacing: 8) {
                Button(action: checkLicenses) {
                    Label(Strings.licenseCheckButton, systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)

                if let err = checkError {
                    Text(err).font(.caption2).foregroundColor(.red).lineLimit(2)
                } else if let res = checkResult {
                    Text(res).font(.caption2).foregroundColor(.green).lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text(Strings.licenseCheckIntervalLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("6", value: $checkIntervalHours, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { SeatRegistry.shared.setCheckInterval(hours: checkIntervalHours) }
                Stepper("", value: $checkIntervalHours, in: 1...168, step: 1)
                    .labelsHidden()
                    .onChange(of: checkIntervalHours) { _, newVal in
                        SeatRegistry.shared.setCheckInterval(hours: newVal)
                    }
                Spacer()
            }
            Text(Strings.licenseCheckIntervalHint)
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(20)
        .padding(.horizontal, 4)
        .onReceive(NotificationCenter.default.publisher(for: .seatRegistryChanged)) { _ in
            seats = SeatRegistry.shared.seats
        }
    }

    private func seatRow(_ seat: SeatRecord) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(seat.sub)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("kid: \(seat.kid.isEmpty ? "—" : seat.kid)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(Strings.licenseCountdown(seat.exp))
                        .font(.caption2)
                        .foregroundColor(seat.revoked ? .red : .secondary)
                }
            }
            Spacer()
            Text(seat.revoked ? Strings.licenseRevokedBadge : Strings.licenseActiveBadge)
                .font(.caption2)
                .foregroundColor(seat.revoked ? .red : .green)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    private func checkLicenses() {
        let url = URL(fileURLWithPath: (licenseSourcePath as NSString).expandingTildeInPath)
        let result = SeatRegistry.shared.checkLicenses(from: url)
        seats = SeatRegistry.shared.seats
        if let err = result.error {
            checkError = err
            checkResult = nil
        } else {
            checkResult = Strings.licenseCheckResult(result.imported, result.updatedAt)
            checkError = nil
        }
    }
}
