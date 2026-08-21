import SwiftUI

/// 席位注册表设置：管理 sub/kid/exp/revoked，以及可选注册表文件路径。
/// DS-mon 作为 Hybrid 授权权威，按 sub 回答吊销状态（无签名校验）。
struct LicenseSettingsView: View {
    @State private var seats: [SeatRecord] = SeatRegistry.shared.seats
    @State private var newSub: String = ""
    @State private var newKid: String = ""
    @State private var newExp: String = ""
    @State private var filePath: String = SeatRegistry.shared.registryFilePath

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

            Text(Strings.licenseAddSeat)
                .font(.callout).bold()

            HStack(spacing: 8) {
                TextField(Strings.licenseSubPlaceholder, text: $newSub)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                TextField(Strings.licenseKidPlaceholder, text: $newKid)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 130)
            }

            HStack(spacing: 8) {
                TextField(Strings.licenseExpPlaceholder, text: $newExp)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 170)
                Button(action: addSeat) {
                    Label(Strings.licenseAddButton, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(newSub.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
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

            Spacer()
        }
        .padding(20)
        .padding(.horizontal, 4)
    }

    private func seatRow(_ seat: SeatRecord) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { seat.revoked },
                set: { newVal in
                    SeatRegistry.shared.setRevoked(newVal, for: seat.sub)
                    seats = SeatRegistry.shared.seats
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(Strings.licenseRevokedHint)

            VStack(alignment: .leading, spacing: 2) {
                Text(seat.sub)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("kid: \(seat.kid.isEmpty ? "—" : seat.kid)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(seat.exp == 0 ? Strings.licenseUnlimited : Strings.licenseExpires(Date(timeIntervalSince1970: TimeInterval(seat.exp))))
                        .font(.caption2)
                        .foregroundColor(seat.revoked ? .red : .secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                SeatRegistry.shared.remove(sub: seat.sub)
                seats = SeatRegistry.shared.seats
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help(Strings.licenseRemoveHint)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    private func addSeat() {
        let sub = newSub.trimmingCharacters(in: .whitespaces)
        guard !sub.isEmpty else { return }
        let kid = newKid.trimmingCharacters(in: .whitespaces)
        let exp = Int(newExp.trimmingCharacters(in: .whitespaces)) ?? 0
        SeatRegistry.shared.upsert(SeatRecord(sub: sub, kid: kid, exp: max(0, exp), revoked: false))
        newSub = ""
        newKid = ""
        newExp = ""
        seats = SeatRegistry.shared.seats
    }
}
