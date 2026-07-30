import SwiftUI

struct SensorManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SensorNicknameStore.shared
    @State private var showAddSheet = false
    @State private var newDeviceId = ""

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
                        ForEach(store.knownDeviceIds, id: \.self) { deviceId in
                            SensorNicknameRow(deviceId: deviceId)
                        }
                    } header: {
                        Text("センサー一覧")
                    } footer: {
                        Text("名前を入力すると、各画面のセンサーID表示が「名前 (ID)」の形になります。行を左にスワイプすると「情報」「メモリ消去」「一覧から削除」が選べます(削除してもセンサー自体には影響しません)。保存済みのデータがあるセンサーは一覧から削除できません。")
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

    @ViewBuilder
    private var addDeviceSheet: some View {
        NavigationView {
            Form {
                Section("センサーID(本体記載の文字列)") {
                    TextField("例: 0BA66E38", text: $newDeviceId)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("センサーを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        newDeviceId = ""
                        showAddSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        let id = newDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !id.isEmpty {
                            store.registerKnownDevice(id)
                        }
                        newDeviceId = ""
                        showAddSheet = false
                    }
                }
            }
        }
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
    @State private var name: String = ""
    @State private var showActiveWarning = false
    @State private var showInfoDialog = false
    @State private var showEraseConfirm1 = false
    @State private var showEraseConfirm2 = false
    @State private var showEraseResult = false
    @State private var showDataExistsWarning = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("名前を入力", text: $name, onCommit: {
                    commit()
                })
                Text(deviceId)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if infoChecker.isChecking || memoryEraser.isErasing {
                ProgressView().scaleEffect(0.8)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 一番端(最初にスワイプした時点)に出したいものを先頭に書く
            Button(role: .destructive) {
                if SensorManagementView.hasStoredData(deviceId: deviceId) {
                    showDataExistsWarning = true
                } else {
                    store.removeKnownDevice(deviceId)
                }
            } label: {
                Label("一覧から削除", systemImage: "trash")
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
        .onAppear {
            name = store.nicknames[deviceId] ?? ""
        }
        .onDisappear {
            // スワイプで削除された直後もこのonDisappearは発火する。
            // 既にリストから削除済みなら、ここでcommit()すると
            // registerKnownDevice経由で自分自身を再登録してしまい、
            // 削除したはずのセンサーが復活してしまう。それを防ぐガード。
            guard store.knownDeviceIds.contains(deviceId) else { return }
            commit()
        }
        .alert("削除できません", isPresented: $showDataExistsWarning) {
            Button("OK") {}
        } message: {
            Text("このセンサーには保存済みのデータがあるため、一覧から削除できません。データ管理画面で該当データを削除してから、もう一度お試しください。")
        }
        .alert("名前を変更できません", isPresented: $showActiveWarning) {
            Button("OK") {
                name = store.nicknames[deviceId] ?? ""
            }
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
        let succeeded = store.setName(name, for: deviceId)
        if !succeeded {
            showActiveWarning = true
        }
    }
}
