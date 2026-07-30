import Foundation
import PolarBleSdk

/// センサー管理画面の「i」ボタンから使う、単発の情報確認専用クラス。
/// - 記録の開始/停止コマンドは一切呼ばない(read-only APIのみ)
/// - FTUも呼ばない
/// - 情報が取得できたら(または失敗したら)すぐに自動で切断する
@MainActor
final class SensorInfoChecker: ObservableObject, PolarDeviceEventReceiver {

    @Published var isChecking = false
    @Published var resultLines: [String] = []
    @Published var errorText: String?

    // PolarDeviceEventReceiver準拠のため(このクラスでは表示に使わない)
    var batteryLevel: Int?

    private var api: PolarBleApi { PolarManager.shared.api }
    private var isConnected = false

    func handleConnecting() {}

    func handleConnected() {
        isConnected = true
    }

    func handleDisconnected(pairingError: Bool) {
        isConnected = false
    }

    func handleFeatureReady(_ feature: PolarBleSdkFeature) {
        // 今回は特定の機能を待つ必要はない(read-only APIは接続後に個別リトライで対応する)
    }

    /// 指定したセンサーに接続し、read-only情報を集めてから自動切断する。
    func check(deviceId: String) async {
        guard !PolarManager.shared.isDeviceActive(deviceId) else {
            errorText = "このセンサーは現在使用中です(計測中の可能性があります)"
            isChecking = false
            return
        }
        isChecking = true
        resultLines = []
        errorText = nil
        isConnected = false
        batteryLevel = nil

        PolarManager.shared.register(slot: self, forDeviceId: deviceId)

        do {
            try api.connectToDevice(deviceId)
        } catch {
            errorText = "接続開始に失敗しました: \(error.localizedDescription)"
            isChecking = false
            PolarManager.shared.unregister(deviceId: deviceId)
            return
        }

        // 接続完了を待つ(最大10秒)
        let connected = await waitUntil(timeoutSeconds: 10) { [weak self] in self?.isConnected == true }
        guard connected else {
            errorText = "接続がタイムアウトしました"
            isChecking = false
            cleanUp(deviceId: deviceId)
            return
        }

        await gatherInfo(deviceId: deviceId)

        if resultLines.isEmpty {
            errorText = "情報を取得できませんでした"
        }

        isChecking = false
        cleanUp(deviceId: deviceId)
    }

    private func gatherInfo(deviceId: String) async {
        var lines: [String] = []

        if let rssi = try? api.getRSSIValue(deviceId) {
            lines.append("RSSI: \(rssi) dBm")
        }

        // バッテリーは、能動的にgetBatteryLevel()を呼ぶより、PolarManager経由で届く
        // 通知(batteryLevelReceived → self.batteryLevel)を待つ方が、実際の値が
        // 届くタイミングに沿っている。届かなければgetBatteryLevel()にフォールバックする。
        if let battery = await waitForBatteryLevel(timeoutSeconds: 6) {
            lines.append("バッテリー: \(battery)%")
        } else if let fallback = await retryingResult(times: 5, delaySeconds: 1, { () -> Int? in
            guard let level = try? self.api.getBatteryLevel(identifier: deviceId), level >= 0 else { return nil }
            return level
        }) {
            lines.append("バッテリー: \(fallback)%")
        } else {
            lines.append("バッテリー: 取得できず(通知が届きませんでした)")
        }

        if let chargeState = await retryingResult(times: 5, delaySeconds: 1, { () -> BleBasClient.ChargeState? in
            guard let state = try? self.api.getChargerState(identifier: deviceId) else { return nil }
            let description = "\(state)"
            // "unknown"は「まだ実際の値が届いていない」状態の可能性が高いため、
            // リトライ対象として扱う(nilを返して再試行させる)。
            return description.lowercased().contains("unknown") ? nil : state
        }) {
            lines.append("充電状態: \(chargeState)")
        } else {
            lines.append("充電状態: 取得できず(unknownのまま)")
        }

        if let status = await retryingAsyncResult(times: 5, delaySeconds: 1, {
            try? await self.api.getOfflineRecordingStatus(deviceId)
        }) {
            let hr = status[.hr] == true
            let temp = status[.skinTemperature] == true
            let acc = status[.acc] == true

            var tempLabel = "体表温=\(temp ? "○" : "×")"
            if temp, let hz = LastMeasurementSettingsStore.shared.lastSkinTempHz(for: deviceId) {
                tempLabel += "(\(hz)Hz)"
            }
            var accLabel = "加速度=\(acc ? "○" : "×")"
            if acc, let hz = LastMeasurementSettingsStore.shared.lastAccHz(for: deviceId) {
                accLabel += "(\(hz)Hz)"
            }

            lines.append("記録中: HR=\(hr ? "○" : "×") \(tempLabel) \(accLabel)")
        }

        if let disk = await retryingAsyncResult(times: 5, delaySeconds: 1, {
            try? await self.api.getDiskSpace(deviceId)
        }) {
            let mb = Double(disk.freeSpace) / 1_048_576.0
            let percent = disk.totalSpace > 0 ? Double(disk.freeSpace) / Double(disk.totalSpace) * 100 : 0
            lines.append(String(format: "残り容量: %.1f MB (%.0f%%)", mb, percent))
        }

        resultLines = lines
    }

    private func cleanUp(deviceId: String) {
        try? api.disconnectFromDevice(deviceId)
        PolarManager.shared.unregister(deviceId: deviceId)
        isConnected = false
    }

    /// PolarManager経由で届くbatteryLevelReceived通知を待つ。
    private func waitForBatteryLevel(timeoutSeconds: Double) async -> Int? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if let value = batteryLevel { return value }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return batteryLevel
    }

    /// 条件が満たされるまで、タイムアウトまでポーリングする。
    private func waitUntil(timeoutSeconds: Double, condition: @escaping () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return condition()
    }

    /// 同期関数を、成功するまで(nilでなくなるまで)一定回数リトライする。
    private func retryingResult<T>(times: Int, delaySeconds: Double, _ body: @escaping () -> T?) async -> T? {
        for attempt in 0..<times {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)) }
            if let value = body() { return value }
        }
        return nil
    }

    /// async関数を、成功するまで(nilでなくなるまで)一定回数リトライする。
    private func retryingAsyncResult<T>(times: Int, delaySeconds: Double, _ body: @escaping () async -> T?) async -> T? {
        for attempt in 0..<times {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)) }
            if let value = await body() { return value }
        }
        return nil
    }
}
