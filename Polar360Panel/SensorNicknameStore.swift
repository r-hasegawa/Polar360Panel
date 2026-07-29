import Foundation

/// センサーのdeviceIdと、ユーザーが付けた名前の対応を管理する。
/// UserDefaultsに永続化するので、アプリを再起動しても保持される。
final class SensorNicknameStore: ObservableObject {
    static let shared = SensorNicknameStore()

    /// deviceId -> ニックネーム
    @Published private(set) var nicknames: [String: String] = [:]
    /// これまでにスキャン等で見つかった/手動登録されたdeviceId一覧(見つかった順)
    @Published private(set) var knownDeviceIds: [String] = []

    private let nicknamesKey = "sensorNicknames"
    private let knownIdsKey = "sensorKnownDeviceIds"

    private init() {
        if let data = UserDefaults.standard.data(forKey: nicknamesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            nicknames = decoded
        }
        knownDeviceIds = UserDefaults.standard.stringArray(forKey: knownIdsKey) ?? []
    }

    /// パネル上部などに出す表示名。名前が付いていれば「名前 (ID)」、無ければIDのみ。
    func displayName(for deviceId: String?) -> String {
        guard let deviceId, !deviceId.isEmpty else { return "未接続" }
        if let name = nicknames[deviceId], !name.isEmpty {
            return "\(name) (\(deviceId))"
        }
        return deviceId
    }

    /// スキャンで見つかった等、deviceIdの存在だけを知った時に呼ぶ(名前はまだ無くてよい)。
    func registerKnownDevice(_ deviceId: String) {
        guard !knownDeviceIds.contains(deviceId) else { return }
        knownDeviceIds.append(deviceId)
        UserDefaults.standard.set(knownDeviceIds, forKey: knownIdsKey)
    }

    /// 名前を設定する。戻り値: 成功したかどうか。
    /// このセンサーが現在いずれかのパネルで接続中(＝実際にCSVへ書き込み中の可能性がある)場合は、
    /// フォルダ名リネームとの競合を避けるため変更を拒否する
    /// (計測終了/切断してから変更してもらう)。
    @discardableResult
    func setName(_ name: String, for deviceId: String) -> Bool {
        guard !PolarManager.shared.isDeviceActive(deviceId) else {
            return false
        }
        let oldNickname = nicknames[deviceId]
        registerKnownDevice(deviceId)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: deviceId)
        } else {
            nicknames[deviceId] = trimmed
        }
        persistNicknames()
        renameStorageFolders(
            deviceId: deviceId,
            oldNickname: oldNickname,
            newNickname: trimmed.isEmpty ? nil : trimmed
        )
        return true
    }

    /// 「名前_ID」または(名前が無ければ)「ID」というフォルダ名を組み立てる。
    /// CsvLoggerの保存先フォルダ名と、ここでのリネーム処理の両方で共通して使う。
    static func folderName(deviceId: String, nickname: String?) -> String {
        if let nickname, !nickname.isEmpty {
            return "\(nickname)_\(deviceId)"
        }
        return deviceId
    }

    /// 名前が変わった(付いた/変わった/消えた)時に、Online/Offline両方の保存フォルダを
    /// 実際にリネームする。これにより「後から名前を付けても、既存の記録データが
    /// ちゃんと新しいフォルダ名にまとまる」ようにする。
    private func renameStorageFolders(deviceId: String, oldNickname: String?, newNickname: String?) {
        let oldFolderName = Self.folderName(deviceId: deviceId, nickname: oldNickname)
        let newFolderName = Self.folderName(deviceId: deviceId, nickname: newNickname)
        guard oldFolderName != newFolderName else { return }

        for modeFolder in ["Online", "Offline"] {
            let base = CsvLogger.documentsDirectory.appendingPathComponent(modeFolder)
            let oldURL = base.appendingPathComponent(oldFolderName)
            let newURL = base.appendingPathComponent(newFolderName)
            guard FileManager.default.fileExists(atPath: oldURL.path) else { continue }
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                print("[SensorNicknameStore] フォルダのリネームに失敗: \(error)")
            }
        }
    }

    func removeKnownDevice(_ deviceId: String) {
        knownDeviceIds.removeAll { $0 == deviceId }
        nicknames.removeValue(forKey: deviceId)
        UserDefaults.standard.set(knownDeviceIds, forKey: knownIdsKey)
        persistNicknames()
    }

    private func persistNicknames() {
        if let data = try? JSONEncoder().encode(nicknames) {
            UserDefaults.standard.set(data, forKey: nicknamesKey)
        }
    }
}
