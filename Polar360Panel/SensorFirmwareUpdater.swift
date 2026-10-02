import Foundation
import Network
import UserNotifications
import PolarBleSdk

/// FW更新シートに表示する、今どの段階にいるか。
enum FirmwareUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate(current: String?)
    case available(current: String?, latest: String)
    case updating(step: String, detail: String?, percent: Int?)
    case verifying
    case completed(message: String)
    case failed(message: String)
}

/// continuationを一度だけresumeするためのフラグ(ネットワーク確認用)。
private final class ResumeOnce: @unchecked Sendable {
    var resumed = false
}

/// センサー管理画面の「FW更新」から使う、ファームウェアの確認・更新専用クラス。
/// SensorInfoChecker / SensorMemoryEraser と同じく、処理ごとに接続して終わったら切断する。
///
/// NOTE: SDKのupdateFirmware()は内部で「バックアップ → 工場出荷リセット(ペアリング情報は保持)
/// → FW書き込み → 再起動待ち → バックアップ復元 → 時刻設定」まで行う。工場出荷リセットにより
/// センサー内蔵メモリの記録データは失われるため、未取得の記録が残っている場合は更新させない。
/// また、更新後はFTUもやり直しになるが、これは計測パネル側の接続時に自動で行われる。
@MainActor
final class SensorFirmwareUpdater: ObservableObject, PolarDeviceEventReceiver {

    @Published var phase: FirmwareUpdatePhase = .idle

    // PolarDeviceEventReceiver準拠のため。更新前のバッテリー残量チェックにも使う。
    var batteryLevel: Int?

    /// 更新中の電池切れを避けるための下限。
    static let minimumBatteryPercent = 75

    private var api: PolarBleApi { PolarManager.shared.api }
    private var isConnected = false
    private var pairingErrorOccurred = false
    private var firmwareFeatureReady = false

    var isBusy: Bool {
        switch phase {
        case .checking, .updating, .verifying: return true
        default: return false
        }
    }

    func handleConnecting() {}

    func handleConnected() {
        isConnected = true
    }

    func handleDisconnected(pairingError: Bool) {
        // 更新中はSDKが意図的に切断・再接続を繰り返すが、ここではフラグを落とすだけにする
        // (更新処理自体の成否はupdateFirmware()のストリームで判断する)。
        isConnected = false
        firmwareFeatureReady = false
        if pairingError {
            pairingErrorOccurred = true
        }
    }

    func handleFeatureReady(_ feature: PolarBleSdkFeature) {
        if feature == .feature_polar_firmware_update {
            firmwareFeatureReady = true
        }
    }

    func reset() {
        phase = .idle
    }

    // MARK: - 最新版の問い合わせ

    /// センサーに接続して現在のバージョンを読み、Polarのサーバーに最新版を問い合わせてから切断する。
    func checkForUpdate(deviceId: String) async {
        guard !PolarManager.shared.isDeviceActive(deviceId) else {
            phase = .failed(message: "このセンサーは現在使用中です(計測中の可能性があります)")
            return
        }
        phase = .checking

        guard await Self.isNetworkAvailable() else {
            // SDKはサーバーへの問い合わせに失敗しても「更新なし」を返してくるため、
            // 通信できない状態で「最新です」と誤表示しないよう、先に弾いておく。
            phase = .failed(message: "インターネットに接続されていません。最新版の問い合わせにはインターネット接続が必要です。")
            return
        }

        if let error = await connect(deviceId: deviceId, requireFirmwareFeature: true) {
            phase = .failed(message: error)
            cleanUp(deviceId: deviceId)
            return
        }

        let current = await readFirmwareVersion(deviceId: deviceId, timeoutSeconds: 5)

        do {
            var result: CheckFirmwareUpdateStatus?
            for try await status in api.checkFirmwareUpdate(deviceId) {
                result = status
            }
            switch result {
            case .checkFwUpdateAvailable(let version):
                phase = .available(current: current, latest: version)
            case .checkFwUpdateNotAvailable:
                phase = .upToDate(current: current)
            case .checkFwUpdateFailed(let details):
                phase = .failed(message: "最新版の問い合わせに失敗しました: \(details)")
            case nil:
                phase = .failed(message: "最新版の問い合わせに失敗しました(応答がありませんでした)")
            }
        } catch {
            phase = .failed(message: "最新版の問い合わせに失敗しました: \(error.localizedDescription)")
        }

        cleanUp(deviceId: deviceId)
    }

    // MARK: - 更新

    /// FWを最新版に更新し、終わったら一度切断→再接続してバージョンが変わったことを確認する。
    /// 完了・失敗時にはローカル通知も出す(更新には数分かかり、画面を離れることがあるため)。
    func performUpdate(deviceId: String, expectedVersion: String) async {
        guard !PolarManager.shared.isDeviceActive(deviceId) else {
            phase = .failed(message: "このセンサーは現在使用中です(計測中の可能性があります)")
            return
        }
        phase = .updating(step: "センサーに接続中", detail: nil, percent: nil)
        await Self.requestNotificationAuthorization()

        guard await Self.isNetworkAvailable() else {
            finish(deviceId: deviceId, failure: "インターネットに接続されていません。ファームウェアのダウンロードにはインターネット接続が必要です。")
            return
        }

        if let error = await connect(deviceId: deviceId, requireFirmwareFeature: true) {
            finish(deviceId: deviceId, failure: error)
            return
        }

        phase = .updating(step: "センサーの状態を確認中", detail: nil, percent: nil)
        let versionBefore = await readFirmwareVersion(deviceId: deviceId, timeoutSeconds: 5)
        if let blocker = await updateBlocker(deviceId: deviceId) {
            finish(deviceId: deviceId, failure: blocker)
            return
        }

        var succeeded = false
        var failureDetail: String?
        do {
            for try await status in api.updateFirmware(deviceId) {
                switch status {
                case .fetchingFwUpdatePackage:
                    phase = .updating(step: "ファームウェアをダウンロード中", detail: nil, percent: nil)
                case .preparingDeviceForFwUpdate(let details):
                    phase = .updating(step: "センサーを準備中", detail: Self.translatedDetail(details), percent: nil)
                case .writingFwUpdatePackage(let details):
                    phase = .updating(step: "ファームウェアを書き込み中", detail: nil, percent: Self.percent(in: details))
                case .finalizingFwUpdate(let details):
                    phase = .updating(step: "仕上げ処理中", detail: Self.translatedDetail(details), percent: nil)
                case .fwUpdateCompletedSuccessfully:
                    succeeded = true
                case .fwUpdateNotAvailable:
                    failureDetail = failureDetail ?? "更新できるファームウェアがありませんでした"
                case .fwUpdateFailed(let details):
                    failureDetail = failureDetail ?? details
                }
            }
        } catch {
            failureDetail = failureDetail ?? error.localizedDescription
        }

        guard succeeded else {
            finish(deviceId: deviceId, failure: "ファームウェア更新に失敗しました: \(failureDetail ?? "不明なエラー")")
            return
        }

        // 更新後のバージョン確認: いったん切断し、新しく接続し直してDISを読み直す。
        phase = .verifying
        cleanUp(deviceId: deviceId)
        let versionAfter = await reconnectAndReadVersion(deviceId: deviceId)
        cleanUp(deviceId: deviceId)

        let before = versionBefore ?? "不明"
        guard let versionAfter else {
            finish(deviceId: deviceId, success: "更新処理は完了しましたが、再接続してのバージョン確認ができませんでした。少し待ってから「情報」でバージョンを確認してください。")
            return
        }
        if Self.normalized(versionAfter) == Self.normalized(expectedVersion) {
            finish(deviceId: deviceId, success: "ファームウェアを更新しました(\(before) → \(versionAfter))。再接続して新しいバージョンになっていることを確認しました。")
        } else if let versionBefore, Self.normalized(versionAfter) == Self.normalized(versionBefore) {
            finish(deviceId: deviceId, failure: "更新処理は完了しましたが、再接続後のバージョンが \(versionAfter) のままでした。もう一度お試しください。")
        } else {
            finish(deviceId: deviceId, success: "ファームウェアを更新しました(\(before) → \(versionAfter))。※問い合わせ時の最新版の表記は \(expectedVersion) でした。")
        }
    }

    // MARK: - 内部処理

    /// 更新してはいけない状態なら理由を返す。
    private func updateBlocker(deviceId: String) async -> String? {
        // 通知(batteryLevelReceived)が届かなければgetBatteryLevel()にフォールバックする。
        // 残量が分からない場合も、安全側に倒して更新させない。
        var level = await waitForBatteryLevel(timeoutSeconds: 6)
        if level == nil, let fallback = try? api.getBatteryLevel(identifier: deviceId), fallback >= 0 {
            level = fallback
        }
        guard let level else {
            return "バッテリー残量を確認できなかったため、中止しました。もう一度お試しください。"
        }
        if level < Self.minimumBatteryPercent {
            return "バッテリー残量が\(level)%です。更新中の電池切れを避けるため、\(Self.minimumBatteryPercent)%以上に充電してから実行してください。"
        }

        let dataLossNote = "ファームウェア更新ではセンサーが初期化され、内蔵メモリの記録データが失われます。先にオフラインモードで「計測終了」してデータを取得するか、「メモリ消去」してから実行してください。"

        if let status = await retryingAsyncResult(times: 5, delaySeconds: 1, {
            try? await self.api.getOfflineRecordingStatus(deviceId)
        }), status.values.contains(true) {
            return "センサーが記録中です。\(dataLossNote)"
        }

        do {
            let count = try await offlineRecordingCount(deviceId: deviceId)
            if count > 0 {
                return "センサー内に未取得の記録が\(count)件あります。\(dataLossNote)"
            }
        } catch {
            return "センサー内の記録データの有無を確認できなかったため、中止しました(\(error.localizedDescription))。"
        }
        return nil
    }

    private func connect(deviceId: String, requireFirmwareFeature: Bool) async -> String? {
        isConnected = false
        pairingErrorOccurred = false
        firmwareFeatureReady = false
        batteryLevel = nil
        PolarManager.shared.clearFirmwareVersion(for: deviceId)

        PolarManager.shared.register(slot: self, forDeviceId: deviceId)

        do {
            try api.connectToDevice(deviceId)
        } catch {
            return "接続開始に失敗しました: \(error.localizedDescription)"
        }

        // 接続完了を待つ(最大10秒。ペアリングエラーが分かった時点で早期終了)
        _ = await waitUntil(timeoutSeconds: 10) { [weak self] in
            guard let self else { return true }
            return self.isConnected || self.pairingErrorOccurred
        }
        if !isConnected && !pairingErrorOccurred {
            pairingErrorOccurred = (try? api.checkIfDeviceDisconnectedDueRemovedPairing(deviceId)) ?? false
        }
        if pairingErrorOccurred {
            return "ペアリング解除により接続できませんでした。設定アプリのBluetoothでこのセンサーとのペアリングを解除してから、もう一度お試しください。"
        }
        guard isConnected else {
            return "接続がタイムアウトしました(センサーが見つからない可能性があります)"
        }

        if requireFirmwareFeature {
            let ready = await waitUntil(timeoutSeconds: 15) { [weak self] in
                self?.firmwareFeatureReady ?? true
            }
            if !ready {
                return "センサーのファームウェア更新機能の準備ができませんでした(タイムアウト)"
            }
        }
        return nil
    }

    /// FW更新直後はセンサーがまだ再起動中のことがあるため、間を置きながら数回接続を試みる。
    private func reconnectAndReadVersion(deviceId: String) async -> String? {
        for attempt in 0..<3 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 3_000_000_000 : 8_000_000_000)
            if await connect(deviceId: deviceId, requireFirmwareFeature: false) == nil,
               let version = await readFirmwareVersion(deviceId: deviceId, timeoutSeconds: 10) {
                return version
            }
            cleanUp(deviceId: deviceId)
        }
        return nil
    }

    private func readFirmwareVersion(deviceId: String, timeoutSeconds: Double) async -> String? {
        _ = await waitUntil(timeoutSeconds: timeoutSeconds) {
            PolarManager.shared.firmwareVersion(for: deviceId) != nil
        }
        return PolarManager.shared.firmwareVersion(for: deviceId)
    }

    private func finish(deviceId: String, success message: String) {
        cleanUp(deviceId: deviceId)
        phase = .completed(message: message)
        Self.postNotification(deviceId: deviceId, title: "ファームウェア更新が完了しました", body: message)
    }

    private func finish(deviceId: String, failure message: String) {
        cleanUp(deviceId: deviceId)
        phase = .failed(message: message)
        Self.postNotification(deviceId: deviceId, title: "ファームウェア更新に失敗しました", body: message)
    }

    private func cleanUp(deviceId: String) {
        try? api.disconnectFromDevice(deviceId)
        PolarManager.shared.unregister(deviceId: deviceId)
        isConnected = false
        firmwareFeatureReady = false
    }

    /// listOfflineRecordingsは接続直後だと失敗することがあるため、1回だけ間を置いてリトライする
    /// (SensorMemoryEraserと同じ対処)。
    private func offlineRecordingCount(deviceId: String) async throws -> Int {
        do {
            var count = 0
            for try await _ in api.listOfflineRecordings(deviceId) { count += 1 }
            return count
        } catch {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var count = 0
            for try await _ in api.listOfflineRecordings(deviceId) { count += 1 }
            return count
        }
    }

    private func waitForBatteryLevel(timeoutSeconds: Double) async -> Int? {
        _ = await waitUntil(timeoutSeconds: timeoutSeconds) { [weak self] in
            self?.batteryLevel != nil
        }
        return batteryLevel
    }

    private func waitUntil(timeoutSeconds: Double, condition: @escaping () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return condition()
    }

    private func retryingAsyncResult<T>(times: Int, delaySeconds: Double, _ body: @escaping () async -> T?) async -> T? {
        for attempt in 0..<times {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)) }
            if let value = await body() { return value }
        }
        return nil
    }

    // MARK: - 表示用の変換

    /// "Writing firmware update file X, (42%) bytes written: ..." から 42 を取り出す。
    private static func percent(in details: String) -> Int? {
        guard let open = details.firstIndex(of: "("),
              let close = details[open...].firstIndex(of: "%") else { return nil }
        return Int(details[details.index(after: open)..<close])
    }

    /// SDKの英語の進捗メッセージを、分かるものだけ日本語にする。
    private static func translatedDetail(_ details: String) -> String {
        let table: [(String, String)] = [
            ("Backing up", "設定をバックアップ中"),
            ("Performing factory reset", "センサーを初期化中"),
            ("Reconnecting after factory reset", "初期化後の再接続を待機中"),
            ("Waiting for device to update", "センサーがファームウェアを適用中(数分かかります)"),
            ("Restoring backup", "設定を復元中"),
            ("Setting device time", "時刻を設定中"),
            ("Stopping sync", "同期を終了中"),
            ("Restarting device", "センサーを再起動中"),
            ("Reconnecting after restart", "再起動後の再接続を待機中"),
        ]
        return table.first(where: { details.hasPrefix($0.0) })?.1 ?? details
    }

    private static func normalized(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("v") { v.removeFirst() }
        return v
    }

    // MARK: - ネットワーク・通知

    /// pathUpdateHandlerは専用キューで呼ばれるため、MainActorから切り離しておく。
    nonisolated private static func isNetworkAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = ResumeOnce()
            // pathUpdateHandlerはこのシリアルキュー上でしか呼ばれないため、onceの読み書きは競合しない
            monitor.pathUpdateHandler = { path in
                guard !once.resumed else { return }
                once.resumed = true
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "SensorFirmwareUpdater.network"))
        }
    }

    private static func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// アプリがバックグラウンドにある時に気づけるよう、ローカル通知を出す。
    /// (前面にある時は通知バナーは出ないが、シート上に結果が表示される)
    private static func postNotification(deviceId: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = SensorNicknameStore.shared.displayName(for: deviceId)
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fwupdate-\(deviceId)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
