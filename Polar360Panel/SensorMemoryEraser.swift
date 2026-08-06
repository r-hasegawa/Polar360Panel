import Foundation
import PolarBleSdk

/// センサー管理画面の「メモリ消去」ボタンから使う。
/// - 記録中なら先に停止する
/// - 一覧にある記録を「取得せず」そのまま削除する(データは失われる。容量確保が目的のため)
/// - 完了したら自動で切断する
@MainActor
final class SensorMemoryEraser: ObservableObject, PolarDeviceEventReceiver {

    @Published var isErasing = false
    @Published var resultText: String?
    @Published var errorText: String?

    var batteryLevel: Int? // PolarDeviceEventReceiver準拠のため(未使用)

    private var api: PolarBleApi { PolarManager.shared.api }
    private var isConnected = false
    private var pairingErrorOccurred = false

    func handleConnecting() {}
    func handleConnected() { isConnected = true }
    func handleDisconnected(pairingError: Bool) {
        isConnected = false
        if pairingError {
            pairingErrorOccurred = true
        }
    }
    func handleFeatureReady(_ feature: PolarBleSdkFeature) {}

    func erase(deviceId: String) async {
        guard !PolarManager.shared.isDeviceActive(deviceId) else {
            errorText = "このセンサーは現在使用中です(計測中の可能性があります)"
            return
        }

        isErasing = true
        resultText = nil
        errorText = nil
        isConnected = false
        pairingErrorOccurred = false

        PolarManager.shared.register(slot: self, forDeviceId: deviceId)

        do {
            try api.connectToDevice(deviceId)
        } catch {
            errorText = "接続開始に失敗しました: \(error.localizedDescription)"
            isErasing = false
            PolarManager.shared.unregister(deviceId: deviceId)
            return
        }

        // 接続完了を待つ(最大10秒。ペアリングエラーが分かった時点で早期終了)
        _ = await waitUntil(timeoutSeconds: 10) { [weak self] in
            guard let self else { return true }
            return self.isConnected || self.pairingErrorOccurred
        }
        // 切断コールバック自体が来ないまま(=isConnectedもpairingErrorOccurredもfalseのまま)
        // タイムアウトすることがあるため、諦める前にもう一度確認しておく。
        if !isConnected && !pairingErrorOccurred {
            pairingErrorOccurred = (try? api.checkIfDeviceDisconnectedDueRemovedPairing(deviceId)) ?? false
        }
        if pairingErrorOccurred {
            errorText = "ペアリング解除により接続できませんでした。設定アプリのBluetoothでこのセンサーとのペアリングを解除してから、もう一度お試しください。"
            isErasing = false
            cleanUp(deviceId: deviceId)
            return
        }
        guard isConnected else {
            errorText = "接続がタイムアウトしました(センサーが見つからない可能性があります)"
            isErasing = false
            cleanUp(deviceId: deviceId)
            return
        }

        // 念のため、記録中なら先に停止する(止まっていなくてもエラーは無視してよい)
        for feature: PolarDeviceDataType in [.hr, .skinTemperature, .acc] {
            try? await api.stopOfflineRecording(deviceId, feature: feature)
        }

        var deletedCount = 0
        var failedCount = 0
        do {
            var entries: [PolarOfflineRecordingEntry] = []
            for try await entry in api.listOfflineRecordings(deviceId) {
                entries.append(entry)
            }
            for entry in entries {
                do {
                    // 取得(getOfflineRecord)は行わず、そのまま削除する(データは失われる)
                    try await api.removeOfflineRecord(deviceId, entry: entry)
                    deletedCount += 1
                } catch {
                    failedCount += 1
                }
            }
        } catch {
            errorText = "一覧の取得に失敗しました: \(error.localizedDescription)"
        }

        // このアプリが明示的に取得しているHR/体表温/加速度のオフライン記録とは別に、
        // センサーが自動で集めている活動量・自動サンプリング・睡眠・体表温サマリー等の
        // データも消しておく。このアプリでは一切利用しないデータだが、放置すると
        // センサー内に残り続けてしまう(工場リセットでしか消えない)ため、こちらも対象にする。
        let storedDataTypesToDelete: [PolarStoredDataType.StoredDataType] = [
            .ACTIVITY, .AUTO_SAMPLE, .DAILY_SUMMARY, .NIGHTLY_RECOVERY,
            .SLEEP, .SLEEP_SCORE, .SKIN_CONTACT_CHANGES, .SKINTEMP
        ]
        var storedDataDeletedCount = 0
        var storedDataFailedCount = 0
        for dataType in storedDataTypesToDelete {
            do {
                try await api.deleteStoredDeviceData(deviceId, dataType: dataType, until: nil)
                storedDataDeletedCount += 1
            } catch {
                // 該当データが元々存在しない場合もエラーになりうるため、
                // ここでは「失敗」として数えるだけで処理は継続する。
                storedDataFailedCount += 1
            }
        }

        if errorText == nil {
            var summary = deletedCount > 0 ? "\(deletedCount)件の記録を削除" : "削除対象の記録はありません"
            if failedCount > 0 {
                summary += "(\(failedCount)件失敗)"
            }
            summary += " / センサー内の自動収集データ\(storedDataDeletedCount)種類を削除"
            if storedDataFailedCount > 0 {
                summary += "(\(storedDataFailedCount)種類は対象なしまたは失敗)"
            }
            resultText = summary
        }

        isErasing = false
        cleanUp(deviceId: deviceId)
    }

    private func cleanUp(deviceId: String) {
        try? api.disconnectFromDevice(deviceId)
        PolarManager.shared.unregister(deviceId: deviceId)
        isConnected = false
    }

    private func waitUntil(timeoutSeconds: Double, condition: @escaping () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return condition()
    }
}
