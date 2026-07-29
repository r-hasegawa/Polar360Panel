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
                        .onDelete { indexSet in
                            for index in indexSet {
                                store.removeKnownDevice(store.knownDeviceIds[index])
                            }
                        }
                    } header: {
                        Text("センサー一覧")
                    } footer: {
                        Text("名前を入力すると、各画面のセンサーID表示が「名前 (ID)」の形になります。スワイプで一覧から削除できます(削除してもセンサー自体には影響しません)。")
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
}

private struct SensorNicknameRow: View {
    let deviceId: String
    @ObservedObject private var store = SensorNicknameStore.shared
    @State private var name: String = ""
    @State private var showActiveWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("名前を入力", text: $name, onCommit: {
                commit()
            })
            Text(deviceId)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            name = store.nicknames[deviceId] ?? ""
        }
        .onDisappear {
            // 1文字ごとにリネームすると保存フォルダ名も1文字ごとに変わってしまうため、
            // Returnキー(onCommit)か、この行が画面から消える時(スクロールアウト・画面を閉じる)
            // にまとめて保存する。
            commit()
        }
        .alert("名前を変更できません", isPresented: $showActiveWarning) {
            Button("OK") {
                name = store.nicknames[deviceId] ?? ""
            }
        } message: {
            Text("このセンサーは現在接続中です。計測終了または切断してから名前を変更してください。")
        }
    }

    private func commit() {
        let succeeded = store.setName(name, for: deviceId)
        if !succeeded {
            showActiveWarning = true
        }
    }
}
