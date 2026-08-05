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
            if infoChecker.isChecking || memoryEraser.isErasing {
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
        } message: {
            if let error = infoChecker.errorText {
                Text(error)
            } else {
                Text(infoChecker.resultLines.joined(separator: "\n"))
            }
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
