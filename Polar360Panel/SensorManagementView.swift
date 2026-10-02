import SwiftUI

struct SensorManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SensorNicknameStore.shared
    @State private var showAddSheet = false
    @State private var newDeviceId = ""
    @State private var newNickname = ""
    @State private var showDuplicateNamedAlert = false

    var body: some View {
        NavigationView {
            List {
                if store.knownDeviceIds.isEmpty {
                    Section {
                        Text("まだ登録されたセンサーがありません。センサーをスキャンすると自動的にここに追加されます。「+」から手動で追加することもできます。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        ForEach(sortedDeviceIds, id: \.self) { deviceId in
                            SensorNicknameRow(deviceId: deviceId)
                        }
                    } header: {
                        Text("センサー一覧")
                    } footer: {
                        Text("名前を付けると、各画面のセンサーID表示が「名前 (ID)」の形になります。行を左にスワイプすると「名前を変更」「情報」「メモリ消去」「一覧から削除」が選べます(削除してもセンサー自体には影響しません)。保存済みのデータがあるセンサーは一覧から削除できません。")
                    }
                }
            }
            .navigationTitle("センサー管理")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                addDeviceSheet
            }
        }
    }

    /// ニックネームがあるものを先(ニックネーム順)、無いものを後(ID順)にして並べ替えたID一覧。
    private var sortedDeviceIds: [String] {
        store.knownDeviceIds.sorted { lhs, rhs in
            let lhsName = store.nicknames[lhs]
            let rhsName = store.nicknames[rhs]
            if (lhsName != nil) != (rhsName != nil) {
                return lhsName != nil
            }
            let lhsKey = lhsName ?? lhs
            let rhsKey = rhsName ?? rhs
            return lhsKey.localizedStandardCompare(rhsKey) == .orderedAscending
        }
    }

    @ViewBuilder
    private var addDeviceSheet: some View {
        NavigationView {
            Form {
                Section("センサーID(本体記載の文字列・必須)") {
                    TextField("例: 0BA66E38", text: $newDeviceId)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                }
                Section("ニックネーム(任意)") {
                    TextField("名前を入力", text: $newNickname)
                }
            }
            .navigationTitle("センサーを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        resetAddSheetFields()
                        showAddSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        addDeviceFromSheet()
                    }
                    .disabled(newDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("追加できません", isPresented: $showDuplicateNamedAlert) {
                Button("OK") {}
            } message: {
                Text("このセンサーIDにはすでに名前が付いています。名前を変更したい場合は、一覧からそのセンサーをスワイプして「名前を変更」を使ってください。")
            }
        }
    }

    private func resetAddSheetFields() {
        newDeviceId = ""
        newNickname = ""
    }

    /// センサーID重複時の扱い:
    /// - 未発見/未登録のID → そのまま登録(ニックネームがあれば設定)
    /// - 登録済みだがニックネーム未設定のID → 入力されたニックネームで上書き設定
    /// - 登録済みでニックネームが既にあるID → 追加させず、エラーメッセージを表示
    private func addDeviceFromSheet() {
        let id = newDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let nickname = newNickname.trimmingCharacters(in: .whitespacesAndNewlines)

        if store.nicknames[id] != nil {
            showDuplicateNamedAlert = true
            return
        }

        if nickname.isEmpty {
            store.registerKnownDevice(id)
        } else {
            store.setName(nickname, for: id)
        }

        resetAddSheetFields()
        showAddSheet = false
    }

    /// Online/Offlineどちらかに、このセンサー用のフォルダ(名前_ID または ID)が
    /// 存在し、かつ中身が空でないかを確認する。
    static func hasStoredData(deviceId: String) -> Bool {
        let nickname = SensorNicknameStore.shared.nicknames[deviceId]
        let folderName = SensorNicknameStore.folderName(deviceId: deviceId, nickname: nickname)
        for modeFolder in ["Online", "Offline"] {
            let url = CsvLogger.documentsDirectory
                .appendingPathComponent(modeFolder)
                .appendingPathComponent(folderName)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path), !contents.isEmpty {
                return true
            }
        }
        return false
    }
}

private struct SensorNicknameRow: View {
    let deviceId: String
    @ObservedObject private var store = SensorNicknameStore.shared
    @StateObject private var infoChecker = SensorInfoChecker()
    @StateObject private var memoryEraser = SensorMemoryEraser()
    @StateObject private var firmwareUpdater = SensorFirmwareUpdater()
    @State private var showFirmwareSheet = false
    @State private var editingName: String = ""
    @State private var showRenameAlert = false
    @State private var showActiveWarning = false
    @State private var showInfoDialog = false
    @State private var showEraseConfirm1 = false
    @State private var showEraseConfirm2 = false
    @State private var showEraseResult = false
    @State private var showDataExistsWarning = false

    private var currentName: String {
        store.nicknames[deviceId] ?? ""
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentName.isEmpty ? "(名前未設定)" : currentName)
                    .foregroundColor(currentName.isEmpty ? .secondary : .primary)
                Text(deviceId)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if infoChecker.isChecking || memoryEraser.isErasing || firmwareUpdater.isBusy {
                ProgressView().scaleEffect(0.8)
            }
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 一番端(最初にスワイプした時点)に出したいものを先頭に書く
            //
            // NOTE: role: .destructiveを付けたボタンは、タップした瞬間に
            // SwiftUI(List)側が「削除された」とみなして、実際に何をしたかに
            // 関わらず行を自動でスライドアウトさせてしまう。保存済みデータが
            // あって実際には削除していないケースでもこれが起きてしまい、
            // 「勝手に一時的に消える」「警告アラートが自分の意思と関係なく閉じる」
            // という表示上の不具合になっていた。
            // → 実際に削除が起きる場合(データが無い場合)だけdestructiveにする。
            Button {
                editingName = currentName
                showRenameAlert = true
            } label: {
                Label("名前を変更", systemImage: "pencil")
            }
            .tint(.indigo)

            if SensorManagementView.hasStoredData(deviceId: deviceId) {
                Button {
                    showDataExistsWarning = true
                } label: {
                    Label("一覧から削除", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    store.removeKnownDevice(deviceId)
                } label: {
                    Label("一覧から削除", systemImage: "trash")
                }
            }

            if store.nicknames[deviceId] != nil {
                Button {
                    showEraseConfirm1 = true
                } label: {
                    Label("メモリ消去", systemImage: "externaldrive.fill.badge.xmark")
                }
                .tint(.orange)

                Button {
                    Task {
                        await infoChecker.check(deviceId: deviceId)
                        showInfoDialog = true
                    }
                } label: {
                    Label("情報", systemImage: "info.circle")
                }
                .tint(.blue)
            }
        }
        .alert("名前を変更", isPresented: $showRenameAlert) {
            TextField("名前を入力", text: $editingName)
            Button("キャンセル", role: .cancel) {}
            Button("変更") { commit() }
        } message: {
            Text("空欄のまま変更すると名前を削除できます。")
        }
        .alert("削除できません", isPresented: $showDataExistsWarning) {
            Button("OK") {}
        } message: {
            Text("このセンサーには保存済みのデータがあるため、一覧から削除できません。データ管理画面で該当データを削除してから、もう一度お試しください。")
        }
        .alert("名前を変更できません", isPresented: $showActiveWarning) {
            Button("OK") {}
        } message: {
            Text("このセンサーは現在接続中です。計測終了または切断してから名前を変更してください。")
        }
        .alert("センサー情報", isPresented: $showInfoDialog) {
            Button("OK") {}
            if infoChecker.errorText == nil {
                Button("FW更新") { showFirmwareSheet = true }
            }
        } message: {
            if let error = infoChecker.errorText {
                Text(error)
            } else {
                Text(infoChecker.resultLines.joined(separator: "\n"))
            }
        }
        .sheet(isPresented: $showFirmwareSheet, onDismiss: { firmwareUpdater.reset() }) {
            FirmwareUpdateSheet(deviceId: deviceId, updater: firmwareUpdater)
        }
        .alert("センサー内蔵メモリを削除しますか?", isPresented: $showEraseConfirm1) {
            Button("キャンセル", role: .cancel) {}
            Button("次へ") { showEraseConfirm2 = true }
        } message: {
            Text("記録中の場合は先に停止します。保存されているデータは取得せずに削除するため、データは失われます。")
        }
        .alert("本当によろしいですか?", isPresented: $showEraseConfirm2) {
            Button("キャンセル", role: .cancel) {}
            Button("削除する", role: .destructive) {
                Task {
                    await memoryEraser.erase(deviceId: deviceId)
                    showEraseResult = true
                }
            }
        } message: {
            Text("この操作は元に戻せません。")
        }
        .alert("メモリ消去", isPresented: $showEraseResult) {
            Button("OK") {}
        } message: {
            if let error = memoryEraser.errorText {
                Text(error)
            } else {
                Text(memoryEraser.resultText ?? "")
            }
        }
    }

    private func commit() {
        let succeeded = store.setName(editingName, for: deviceId)
        if !succeeded {
            showActiveWarning = true
        }
    }
}

/// 「FW更新」から開くシート。開いた時点で最新版を問い合わせ、結果に応じて
/// 「最新です」表示 / 更新の確認 / 進捗 / 完了(再接続でのバージョン確認結果)を表示する。
private struct FirmwareUpdateSheet: View {
    let deviceId: String
    @ObservedObject var updater: SensorFirmwareUpdater
    @ObservedObject private var store = SensorNicknameStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(store.displayName(for: deviceId))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                content
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("ファームウェア更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if !updater.isBusy {
                        Button("閉じる") { dismiss() }
                    }
                }
            }
        }
        // 更新中にスワイプで閉じてしまわないようにする
        .interactiveDismissDisabled(updater.isBusy)
        .task {
            if updater.phase == .idle {
                await updater.checkForUpdate(deviceId: deviceId)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            ProgressView("最新版を問い合わせ中…")

        case .upToDate(let current):
            resultIcon("checkmark.seal.fill", color: .green)
            Text("最新のファームウェアです")
                .font(.title3).bold()
            Text("現在のバージョン: \(current ?? "不明")")
                .foregroundColor(.secondary)

        case .available(let current, let latest):
            resultIcon("arrow.down.circle.fill", color: .blue)
            Text("新しいファームウェアがあります")
                .font(.title3).bold()
            Text("\(current ?? "不明") → \(latest)")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("・更新には数分かかります。完了までセンサーをiPadの近くに置き、アプリを終了しないでください。")
                Text("・更新の途中でセンサーは一度初期化されます(ペアリングは維持されます)。内蔵メモリに未取得の記録がある場合は更新を中止します。")
                Text("・更新後、計測パネルで最初に接続した時に初期設定(FTU)が自動でやり直されます。")
                Text("・バッテリー残量が\(SensorFirmwareUpdater.minimumBatteryPercent)%未満の場合は更新できません。")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 480)
            Button {
                Task { await updater.performUpdate(deviceId: deviceId, expectedVersion: latest) }
            } label: {
                Text("更新する").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)

        case .updating(let step, let detail, let percent):
            if let percent {
                ProgressView(value: Double(percent), total: 100) {
                    Text(step)
                } currentValueLabel: {
                    Text("\(percent)%")
                }
                .frame(maxWidth: 360)
            } else {
                ProgressView(step)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("完了するまでセンサーをiPadの近くに置き、アプリを終了しないでください。")
                .font(.caption)
                .foregroundColor(.orange)

        case .verifying:
            ProgressView("再接続してバージョンを確認中…")

        case .completed(let message):
            resultIcon("checkmark.circle.fill", color: .green)
            Text("更新完了")
                .font(.title3).bold()
            Text(message)

        case .failed(let message):
            resultIcon("exclamationmark.triangle.fill", color: .red)
            Text("ファームウェア更新できませんでした")
                .font(.title3).bold()
            Text(message)
        }
    }

    private func resultIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 48))
            .foregroundColor(color)
    }
}
