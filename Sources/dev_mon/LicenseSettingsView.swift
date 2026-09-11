import SwiftUI
import AppKit

/// 许可设置：注册表 ▸ 密钥环 ▸ 密钥 三级折叠树，并支持签发 / 吊销。
///
/// - 读取：解析密钥管理器导出的 devmon.json（见 `SeatRegistry`）
/// - 写入：以子进程调用 `pkm`（见 `KeyManager`）——DS-mon 不持有主私钥
/// - 工具不存在时（普通用户机器）整页降级为只读：只展示、不签发
struct LicenseSettingsView: View {
    @ObservedObject private var uiState = UIStateStore.shared

    @State private var registries: [LicenseRegistry] = SeatRegistry.shared.registries
    @State private var filePath: String = SeatRegistry.shared.registryFilePath
    @State private var licenseSourcePath: String = SeatRegistry.defaultLicensesSourceURL.path
    @State private var checkIntervalHours: Double = SeatRegistry.shared.checkIntervalHours
    @State private var toolPath: String = KeyManager.toolRoot
    @State private var writable: Bool = KeyManager.isWritable()
    @State private var toolProblem: String? = KeyManager.unavailableReason()

    @State private var checkResult: String?
    @State private var checkError: String?
    @State private var signature: BundleSignatureVerdict = SeatRegistry.shared.signatureVerdict

    @State private var showIssueSheet = false
    @State private var revokeTarget: SeatRecord?
    @State private var revokeReason: String = ""
    @State private var busy: String?
    @State private var actionError: String?
    @State private var actionInfo: String?
    @State private var issuedKey: KeyManager.IssuedKey?

    // MARK: - 折叠状态

    private func registryExpansion(_ id: String) -> Binding<Bool> {
        uiState.boolBinding(UIStateStore.Key.licenseRegistry(id), default: true)
    }

    private func ringExpansion(_ registryId: String, _ kid: String) -> Binding<Bool> {
        uiState.boolBinding(UIStateStore.Key.licenseRing(registryId, kid), default: true)
    }

    private var allExpandKeys: [String] {
        registries.flatMap { registry in
            [UIStateStore.Key.licenseRegistry(registry.id)]
                + registry.rings.map { UIStateStore.Key.licenseRing(registry.id, $0.kid) }
        }
    }

    private var allExpanded: Bool { uiState.allTrue(allExpandKeys) }

    private func setAllExpanded(_ expanded: Bool) {
        for key in allExpandKeys { uiState.setBool(key, expanded) }
    }

    private var totalSeats: Int { registries.reduce(0) { $0 + $1.allSeats.count } }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if registries.isEmpty {
                emptyState
            } else {
                tree
            }
            Divider().padding(.horizontal, 20)
            actions
            Divider().padding(.horizontal, 20)
            sourceSection
            toolSection
            Spacer(minLength: 12)
        }
        .padding(.bottom, 12)
        .onReceive(NotificationCenter.default.publisher(for: .seatRegistryChanged)) { _ in
            reload()
        }
        .sheet(isPresented: $showIssueSheet) {
            IssueKeySheet(registries: registries) { registry, sub, exp, kid in
                await issue(registry: registry, sub: sub, exp: exp, kid: kid)
            }
        }
        .sheet(item: $issuedKey) { key in
            IssuedKeySheet(key: key)
        }
        .sheet(item: $revokeTarget) { seat in
            RevokeSheet(seat: seat, reason: $revokeReason) {
                await revoke(seat)
            } onCancel: {
                revokeTarget = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill")
                .foregroundColor(.green)
            Text(Strings.licenseSection)
                .font(.body).bold()

            if !writable {
                Text(Strings.licenseReadOnlyBadge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14))
                    .cornerRadius(4)
                    .help(toolProblem ?? "")
            }

            Spacer()

            if !registries.isEmpty {
                Text(Strings.licenseRegistryCount(registries.count) + " · " + Strings.licenseSeatCount(totalSeats))
                    .font(.caption)
                    .foregroundColor(.secondary)
                SectionExpandControls(iconSize: 11,
                                      allExpanded: allExpanded,
                                      toggle: { setAllExpanded(!allExpanded) })
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.caption).foregroundColor(.secondary)
            Text(Strings.licenseNoRegistries)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    // MARK: - Tree

    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(registries) { registry in
                registrySection(registry)
            }
        }
    }

    private func registrySection(_ registry: LicenseRegistry) -> some View {
        CollapsibleSection(title: registry.name,
                           icon: "shippingbox",
                           isExpanded: registryExpansion(registry.id),
                           iconSize: 12,
                           titleFont: .system(size: 13, weight: .semibold),
                           horizontalPadding: 20,
                           accessory: registryAccessory(registry)) {
            VStack(alignment: .leading, spacing: 0) {
                if registry.rings.isEmpty {
                    Text(Strings.licenseNoSeats)
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.leading, 34).padding(.vertical, 4)
                }
                ForEach(registry.rings) { ring in
                    ringSection(ring, in: registry)
                }
            }
        }
    }

    private func registryAccessory(_ registry: LicenseRegistry) -> AnyView {
        AnyView(HStack(spacing: 5) {
            if registry.validCount > 0 { countChip(registry.validCount, .green) }
            if registry.expiredCount > 0 { countChip(registry.expiredCount, .orange) }
            if registry.revokedCount > 0 { countChip(registry.revokedCount, .red) }
            Text(registry.app)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        })
    }

    private func countChip(_ n: Int, _ color: Color) -> some View {
        Text("\(n)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.14))
            .cornerRadius(3)
    }

    private func ringSection(_ ring: KeyRing, in registry: LicenseRegistry) -> some View {
        CollapsibleSection(title: "ring \(ring.kid)",
                           icon: "circle.hexagongrid",
                           isExpanded: ringExpansion(registry.id, ring.kid),
                           iconSize: 10,
                           titleFont: .system(size: 12, weight: .medium),
                           horizontalPadding: 34,
                           showsDivider: false,
                           accessory: ringAccessory(ring)) {
            VStack(alignment: .leading, spacing: 4) {
                if ring.seats.isEmpty {
                    Text(Strings.licenseNoSeats)
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.leading, 12).padding(.vertical, 2)
                }
                ForEach(ring.seats) { seat in
                    keyRow(seat)
                }
            }
            .padding(.leading, 40)
            .padding(.trailing, 20)
            .padding(.bottom, 6)
        }
    }

    private func ringAccessory(_ ring: KeyRing) -> AnyView {
        AnyView(HStack(spacing: 5) {
            if let pub = ring.publicKey {
                Text(String(pub.prefix(10)) + "…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(Strings.licenseSeatCount(ring.seats.count))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            if ring.isRetired {
                Text(Strings.licenseRingRetiredBadge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.red)
            } else if let label = ring.notAfterLabel {
                Text(Strings.licenseRingRetires(label))
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
        })
    }

    /// 钥匙行：sub · kid · 签发日期 · 剩余有效期 · 状态 · 吊销
    private func keyRow(_ seat: SeatRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: seat.revoked ? "xmark.circle.fill"
                              : (seat.isExpired ? "clock.badge.exclamationmark.fill" : "checkmark.circle.fill"))
                .font(.system(size: 10))
                .foregroundColor(seat.revoked ? .red : (seat.isExpired ? .orange : .green))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(seat.sub)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text("kid: \(seat.kid.isEmpty ? "—" : seat.kid)")
                        .font(.caption2).foregroundColor(.secondary)
                    // 签发日期（requirement: each key carries its issue date）
                    Text("\(Strings.licenseIssuedAtLabel): \(Strings.licenseIssuedOn(seat.issuedAt))")
                        .font(.caption2)
                        .foregroundColor(seat.issuedAt == nil ? .secondary : .secondary)
                    Text(Strings.licenseCountdown(seat.exp))
                        .font(.caption2)
                        .foregroundColor(seat.revoked ? .red : .secondary)
                }
            }

            Spacer(minLength: 4)

            if busy == seat.sub {
                ProgressView().controlSize(.small)
            } else {
                Text(seat.revoked ? Strings.licenseRevokedBadge : Strings.licenseActiveBadge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(seat.revoked ? .red : .green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((seat.revoked ? Color.red : Color.green).opacity(0.12))
                    .cornerRadius(4)

                if writable && !seat.revoked {
                    Button {
                        revokeReason = ""
                        revokeTarget = seat
                    } label: {
                        Text(Strings.licenseRevokeAction).font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .help(Strings.licenseRevokeConfirmTitle(seat.sub))
                }
            }
        }
        .padding(6)
        .background(seat.revoked ? Color.red.opacity(0.06) : Color.gray.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showIssueSheet = true
                } label: {
                    Label(Strings.licenseIssueAction, systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!writable || registries.isEmpty)

                Button(action: checkLicenses) {
                    Label(Strings.licenseCheckButton, systemImage: "checkmark.shield")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                if let busy {
                    ProgressView().controlSize(.small)
                    Text(Strings.licenseIssueBusy(busy)).font(.caption2).foregroundColor(.secondary)
                }

                Spacer()
            }

            if let err = actionError {
                messageRow(err, color: .red, icon: "exclamationmark.triangle.fill")
            } else if let info = actionInfo {
                messageRow(info, color: .green, icon: "checkmark.circle.fill")
            } else if let err = checkError {
                messageRow(err, color: .red, icon: "exclamationmark.triangle.fill")
            } else if let res = checkResult {
                messageRow(res, color: .green, icon: "checkmark.circle.fill")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func messageRow(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2).foregroundColor(color)
            Text(text).font(.caption2).foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Source / interval

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Strings.licenseSourceLabel)
                    .font(.caption).foregroundColor(.secondary)
                TextField("~/…/export/devmon.json", text: $licenseSourcePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: licenseSourcePath) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: SeatRegistry.checkSourceKey)
                    }
            }

            signatureRow

            HStack(spacing: 8) {
                Text(Strings.licenseFileLabel)
                    .font(.caption).foregroundColor(.secondary)
                TextField("~/path/to/mirror.json", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: filePath) { _, newVal in
                        SeatRegistry.shared.setFilePath(newVal)
                        reload()
                    }
            }
            Text(Strings.licenseFileHint)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(Strings.licenseCheckIntervalLabel)
                    .font(.caption).foregroundColor(.secondary)
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
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Tool

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundColor(.secondary)
                Text(Strings.licenseToolSection).font(.callout).bold()
                Spacer()
                Circle()
                    .fill(writable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(writable ? "pkm" : Strings.licenseReadOnlyBadge)
                    .font(.caption2)
                    .foregroundColor(writable ? .green : .orange)
            }

            HStack(spacing: 8) {
                Text(Strings.licenseToolPathLabel)
                    .font(.caption).foregroundColor(.secondary)
                TextField(SeatRegistry.defaultToolRoot, text: $toolPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onChange(of: toolPath) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: KeyManager.toolPathKey)
                        refreshToolState()
                    }
            }
            Text(Strings.licenseToolPathHint)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = toolProblem {
                messageRow(problem, color: .orange, icon: "exclamationmark.triangle.fill")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Logic

    private func reload() {
        registries = SeatRegistry.shared.registries
        checkIntervalHours = SeatRegistry.shared.checkIntervalHours
        signature = SeatRegistry.shared.signatureVerdict
    }

    // MARK: - 签名状态

    @ViewBuilder
    private var signatureRow: some View {
        HStack(spacing: 5) {
            Image(systemName: signatureIcon)
                .font(.caption2)
                .foregroundColor(signatureColor)
            Text(signatureText)
                .font(.caption2)
                .foregroundColor(signatureColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var signatureIcon: String {
        switch signature {
        case .valid:   return "checkmark.seal.fill"
        case .absent:  return "exclamationmark.triangle.fill"
        case .invalid: return "xmark.seal.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var signatureColor: Color {
        switch signature {
        case .valid:   return .green
        case .absent:  return .orange
        case .invalid: return .red
        case .unknown: return .secondary
        }
    }

    private var signatureText: String {
        switch signature {
        case .valid(let kid):   return Strings.licenseSignatureValid(kid)
        case .absent:           return Strings.licenseSignatureAbsent
        case .invalid(let why): return Strings.licenseSignatureRefused(why)
        case .unknown:          return Strings.licenseSignatureUnknown
        }
    }

    private func refreshToolState() {
        writable = KeyManager.isWritable()
        toolProblem = KeyManager.unavailableReason()
    }

    private func checkLicenses() {
        let url = URL(fileURLWithPath: (licenseSourcePath as NSString).expandingTildeInPath)
        let result = SeatRegistry.shared.checkLicenses(from: url)
        reload()
        if let err = result.error {
            checkError = err
            checkResult = nil
        } else {
            checkResult = Strings.licenseCheckResult(result.imported, result.updatedAt)
            checkError = nil
        }
    }

    private func issue(registry: String, sub: String, exp: String, kid: String?) async {
        busy = sub
        actionError = nil
        actionInfo = nil
        do {
            let issued = try await KeyManager.issue(registry: registry, sub: sub, exp: exp, kid: kid)
            _ = KeyManager.reloadFromExport()
            reload()
            issuedKey = issued
            actionInfo = Strings.licenseIssueDone
        } catch {
            actionError = error.localizedDescription
        }
        busy = nil
    }

    private func revoke(_ seat: SeatRecord) async {
        guard let registryId = seat.registryId else { return }
        busy = seat.sub
        actionError = nil
        actionInfo = nil
        revokeTarget = nil
        do {
            let outcome = try await KeyManager.revoke(registry: registryId,
                                                      sub: seat.sub,
                                                      reason: revokeReason)
            _ = KeyManager.reloadFromExport()
            reload()
            actionInfo = Strings.licenseRevokeDone(outcome.sub, outcome.blocklistSize)
        } catch {
            actionError = error.localizedDescription
        }
        busy = nil
    }
}

// MARK: - 签发弹窗

private struct IssueKeySheet: View {
    let registries: [LicenseRegistry]
    /// (registryId, sub, exp, kid) —— exp 为日期字符串或 "unlimited"
    let onSubmit: (String, String, String, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var registryId: String = ""
    @State private var kid: String = ""
    @State private var sub: String = ""
    @State private var expDate: String = ""
    @State private var unlimited: Bool = false

    private var selectedRegistry: LicenseRegistry? {
        registries.first { $0.id == registryId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.licenseIssueTitle).font(.body).bold()

            HStack(spacing: 8) {
                Text(Strings.licenseRegistryLabel).font(.caption).foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Picker("", selection: $registryId) {
                    ForEach(registries) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: registryId) { _, _ in resetKid() }
            }

            HStack(spacing: 8) {
                Text(Strings.licenseRingLabel).font(.caption).foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Picker("", selection: $kid) {
                    ForEach(selectedRegistry?.rings ?? []) { ring in
                        Text(ring.kid).tag(ring.kid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack(spacing: 8) {
                Text(Strings.licenseIssueSubLabel).font(.caption).foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField(Strings.licenseIssueSubPlaceholder, text: $sub)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            HStack(spacing: 8) {
                Text(Strings.licenseIssueExpLabel).font(.caption).foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField(Strings.licenseIssueExpPlaceholder, text: $expDate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(unlimited)
                Toggle(Strings.licenseIssueUnlimited, isOn: $unlimited)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(Strings.licenseIssueCancel) { dismiss() }
                    .buttonStyle(.bordered)
                Button(Strings.licenseIssueConfirm) {
                    let exp = unlimited ? "unlimited" : expDate
                    let target = registryId
                    let seat = sub
                    let ring = kid
                    dismiss()
                    Task { await onSubmit(target, seat, exp, ring.isEmpty ? nil : ring) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sub.trimmingCharacters(in: .whitespaces).isEmpty
                          || registryId.isEmpty
                          || (!unlimited && expDate.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: initialise)
    }

    private func initialise() {
        if registryId.isEmpty { registryId = registries.first?.id ?? "" }
        resetKid()
    }

    private func resetKid() {
        kid = selectedRegistry?.rings.first?.kid ?? ""
    }
}

// MARK: - 新密钥展示（仅一次）

private struct IssuedKeySheet: View {
    let key: KeyManager.IssuedKey

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundColor(.green)
                Text(Strings.licenseIssueDone).font(.body).bold()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("\(Strings.licenseIssueSubLabel): \(key.sub)")
                    .font(.caption).monospaced()
                Text("\(Strings.licenseRegistryLabel): \(key.registry) · kid: \(key.kid)")
                    .font(.caption2).foregroundColor(.secondary)
                Text("\(Strings.licenseIssuedAtLabel): \(Strings.licenseIssuedOn(key.issuedAt))")
                    .font(.caption2).foregroundColor(.secondary)
            }

            ScrollView {
                Text(key.licenseKey)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .padding(8)
            .background(Color.gray.opacity(0.10))
            .cornerRadius(6)

            Text(Strings.licenseIssueCopyHint)
                .font(.caption2).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.licenseKey, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? Strings.licenseIssueCopied : Strings.licenseIssueCopy,
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button(Strings.licenseIssueClose) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 吊销确认

private struct RevokeSheet: View {
    let seat: SeatRecord
    @Binding var reason: String
    let onConfirm: () async -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(Strings.licenseRevokeConfirmTitle(seat.sub)).font(.body).bold()
            }

            Text(Strings.licenseRevokeConfirmHint)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(Strings.licenseRevokeReasonLabel)
                    .font(.caption).foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("", text: $reason)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button(Strings.licenseRevokeCancel) {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button(Strings.licenseRevokeConfirm) {
                    dismiss()
                    Task { await onConfirm() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
