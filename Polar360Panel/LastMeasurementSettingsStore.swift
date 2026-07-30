import Foundation

/// センサーID(deviceId)ごとに、オフラインモードで最後に選択した体表温・加速度のHzを記憶する。
/// センサー本体に問い合わせて「今実際に何Hzで記録中か」を取得するAPIが無いため、
/// 代わりに「このアプリから最後に指示した値」として参考表示するために使う。
/// (オンラインモードはセンサー側に何も持続しないため、ここでは記憶しない)
final class LastMeasurementSettingsStore {
    static let shared = LastMeasurementSettingsStore()

    private struct Entry: Codable {
        let skinTempHz: UInt32
        let accHz: UInt32
        let measureAcc: Bool
    }

    private let key = "lastOfflineMeasurementSettings"
    private var storage: [String: Entry] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            storage = decoded
        }
    }

    /// mode == .offline の時だけ呼ぶこと。
    func record(deviceId: String, skinTempHz: UInt32, accHz: UInt32, measureAcc: Bool) {
        storage[deviceId] = Entry(skinTempHz: skinTempHz, accHz: accHz, measureAcc: measureAcc)
        if let data = try? JSONEncoder().encode(storage) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func lastSkinTempHz(for deviceId: String) -> UInt32? {
        storage[deviceId]?.skinTempHz
    }

    /// 加速度を計測しない設定で保存されていた場合はnilを返す。
    func lastAccHz(for deviceId: String) -> UInt32? {
        guard let entry = storage[deviceId], entry.measureAcc else { return nil }
        return entry.accHz
    }
}
