import Foundation
import PolarBleSdk

enum SlotState: Equatable {
    case idle
    case connecting
    case settingUp        // doFirstTimeUse実行中
    case configuring      // 接続完了後、計測開始前のHz設定画面
    case connected
    case measurementStopped // オンラインモードで「計測終了」した後、グラフを見返せる状態
    case pendingOfflineData(hrCount: Int, skinTempCount: Int, accCount: Int) // 記録は止まっているが、センサー内に未取得データが残っている状態
    case unexpectedDisconnect(String) // 電波切れ等、ユーザー操作によらない切断
    case error(String)
}

/// 体表温・加速度の計測モード。HRは常に両方(オンライン+オフライン)併用なので対象外。
enum SensorMode: String, CaseIterable, Identifiable {
    case online = "オンライン"
    case offline = "オフライン"
    var id: String { rawValue }
}

struct HrPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let bpm: Int
}

struct SkinTempPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let celsius: Double
}

struct AccPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let x: Int32
    let y: Int32
    let z: Int32
}

/// 「計測終了」処理の、今どの工程にいるかを表す。
enum OfflineStopPhase: Equatable {
    case idle
    case stoppingRecording
    case fetchingEntry(type: String)
    case savingCsv(type: String)
    case erasingMemory(type: String)
    case done
}

/// データ種別ごとの取得進捗。
struct TypeProgress: Equatable {
    var completedCount: Int = 0
    var totalCount: Int = 0
    var currentPercent: Int = 0

    /// 表示用の「今何個目」(1始まり、totalCountを超えない)
    var displayIndex: Int {
        totalCount == 0 ? 0 : min(completedCount + 1, totalCount)
    }
}

/// 切断が「何によって起きたか」を区別するための内部フラグ。
private enum DisconnectReason {
    case none              // ユーザー操作によらない(電波切れ等) = 予期しない切断
    case userDisconnect    // 「切断」ボタン
    case measurementStop   // 「計測終了」ボタン(オンラインモード)
}

/// 「いつ・残りどれだけ容量があったか」のチェックポイント。
/// UserDefaultsにJSONとして保存し、アプリを再起動しても消費レート計算を引き継ぐ。
struct DiskCheckpoint: Codable, Equatable {
    let date: Date
    let freeSpace: UInt64
    let totalSpace: UInt64
}

/// 4分割パネルのうち1枠分を担当するViewModel。
/// PolarBleApiのobserverには自分自身はならず、PolarManagerからの通知(handle*)を受けて状態遷移する。
/// SDK 8.x では各種ストリーミングAPIが AsyncThrowingStream を返すため、
/// RxSwiftではなく Task + for-await-in で処理する。
/// SensorSlotViewModel(4分割パネル用)と、SensorInfoChecker(センサー管理画面の
/// 単発情報確認用)の両方が、PolarManagerからのコールバックを受け取れるようにするための
/// 共通プロトコル。
@MainActor
protocol PolarDeviceEventReceiver: AnyObject {
    var batteryLevel: Int? { get set }
    func handleConnecting()
    func handleConnected()
    func handleDisconnected(pairingError: Bool)
    func handleFeatureReady(_ feature: PolarBleSdkFeature)
}

final class SensorSlotViewModel: ObservableObject, Identifiable, PolarDeviceEventReceiver {

    let id = UUID()
    let slotIndex: Int

    @Published var state: SlotState = .idle
    @Published var deviceId: String?
    @Published var deviceName: String = ""
    @Published var heartRate: Int?
    @Published var skinTemperature: Double?
    @Published var batteryLevel: Int?
    @Published var isAccStreaming: Bool = false
    @Published var lastOfflineSyncDate: Date?
    @Published var pendingOfflineEntries: Int = 0
    @Published var errorMessage: String?
    @Published var diskCheckpoint: DiskCheckpoint?
    @Published var diskConsumptionRateBytesPerSecond: Double?
    @Published var isSyncing: Bool = false
    @Published var stopPhase: OfflineStopPhase = .idle
    @Published var hrProgress = TypeProgress()
    @Published var skinTempProgress = TypeProgress()
    @Published var accProgress = TypeProgress()
    @Published var lastSyncSummary: String?
    @Published var mode: SensorMode
    @Published var offlineRecordingConflictDetected: Bool = false
    @Published var configuringSkinTempRateOptions: [UInt32] = []
    @Published var configuringAccRateOptions: [UInt32] = []
    @Published var selectedSkinTempRateHz: UInt32 = 1
    @Published var selectedAccRateHz: UInt32 = 10
    @Published var measureAcc: Bool = true
    @Published var showAccRiskWarning: Bool = false

    /// オフライン加速度で破損バグ(SDK Issue #716, #652)の懸念が少ないと確認できているレート。
    /// これを超えるレートを選んだ場合、計測開始前に警告を出す。
    private let safeOfflineAccRateHz: UInt32 = 10
    @Published var hrHistory: [HrPoint] = []
    @Published var skinTempHistory: [SkinTempPoint] = []
    @Published var accHistory: [AccPoint] = []

    /// 保持している履歴から、historyRetentionMinutesより古い点を間引く。
    /// 加速度は高頻度(最大50Hz×3軸)なので、HR/体表温より短い保持時間(accHistoryRetentionMinutes)にする。
    private func trimOldHistory() {
        let cutoff = Date().addingTimeInterval(-historyRetentionMinutes * 60)
        let accCutoff = Date().addingTimeInterval(-accHistoryRetentionMinutes * 60)
        hrHistory.removeAll { $0.date < cutoff }
        skinTempHistory.removeAll { $0.date < cutoff }
        accHistory.removeAll { $0.date < accCutoff }
    }

    private var api: PolarBleApi { PolarManager.shared.api }

    private var ftuTask: Task<Void, Never>?
    private var hrTask: Task<Void, Never>?
    private var tempTask: Task<Void, Never>?
    private var accTask: Task<Void, Never>?
    private var diskCheckTask: Task<Void, Never>?

    private var csvLogger: CsvLogger?
    private var disconnectReason: DisconnectReason = .none

    /// グラフに表示する過去何分間か。保持自体は最大60分まで(historyRetentionMinutes)行い、
    /// 表示だけこの分数でフィルタする。
    @Published var graphWindowMinutes: Double = 5
    private let historyRetentionMinutes: Double = 60
    private let accHistoryRetentionMinutes: Double = 3 // 50Hz×3軸なので短め
    private var pendingOnlineDeviceId: String? // オフライン記録競合の確認待ちdeviceId

    private var lastDeviceIdKey: String { "lastDeviceId_slot_\(slotIndex)" }
    private var lastDeviceNameKey: String { "lastDeviceName_slot_\(slotIndex)" }

    /// modeはアプリ起動時のモード選択画面で決まり、以降このセッション中は固定。
    init(slotIndex: Int, mode: SensorMode) {
        self.slotIndex = slotIndex
        self.mode = mode
    }

    // MARK: - アプリ起動時の自動再接続

    /// UserDefaultsに前回接続していたdeviceIdが残っていれば、
    /// スキャン画面を経由せず直接そのデバイスへの再接続を試みる。
    func autoReconnectIfPossible() {
        guard deviceId == nil,
              let savedDeviceId = UserDefaults.standard.string(forKey: lastDeviceIdKey) else { return }
        let savedName = UserDefaults.standard.string(forKey: lastDeviceNameKey) ?? savedDeviceId
        reconnect(toDeviceId: savedDeviceId, deviceName: savedName)
    }

    private func reconnect(toDeviceId savedDeviceId: String, deviceName savedName: String) {
        deviceId = savedDeviceId
        deviceName = savedName
        csvLogger = CsvLogger(deviceId: savedDeviceId, mode: mode)
        csvLogger?.logEvent("auto_reconnect_attempt")
        PolarManager.shared.register(slot: self, forDeviceId: savedDeviceId)
        state = .connecting
        do {
            try api.connectToDevice(savedDeviceId)
        } catch {
            state = .error("自動再接続に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 接続

    func connect(to info: PolarDeviceInfo) {
        deviceId = info.deviceId
        deviceName = info.name
        csvLogger = CsvLogger(deviceId: info.deviceId, mode: mode)
        csvLogger?.logEvent("connect_requested")
        PolarManager.shared.register(slot: self, forDeviceId: info.deviceId)
        state = .connecting
        do {
            try api.connectToDevice(info.deviceId)
        } catch {
            state = .error("接続開始に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - PolarManagerからのコールバック
    // (SDK初期化時にDispatchQueue.mainを渡しているため、これらはメインスレッドで呼ばれる想定)

    func handleConnecting() {
        state = .connecting
        csvLogger?.logEvent("gatt_connecting")
    }

    func handleConnected() {
        // NOTE: ここでは即FTUを呼ばない。feature_polar_device_control の
        // 準備完了通知(handleFeatureReady)を待ってから呼び出す。
        state = .settingUp
        csvLogger?.logEvent("gatt_connected")
    }

    func handleDisconnected(pairingError: Bool) {
        stopAllStreams()
        if pairingError {
            state = .error("ペアリング解除により切断されました")
            csvLogger?.logEvent("disconnected_pairing_error")
            disconnectReason = .none
            return
        }
        switch disconnectReason {
        case .userDisconnect:
            state = .idle
            csvLogger?.logEvent("disconnected")
        case .measurementStop:
            state = .measurementStopped
            csvLogger?.logEvent("measurement_stopped")
        case .none:
            // ユーザーが切断/計測終了ボタンを押したわけではないのに切断された
            // = 電波が届いていない可能性が高い。画面上ではっきり分かるようにする。
            state = .unexpectedDisconnect("予期しない切断です(電波が届いていない可能性があります)")
            csvLogger?.logEvent("disconnected_unexpected")
        }
        disconnectReason = .none
    }

    /// 予期しない切断(電波切れ等)からの再接続。スキャンをやり直さず、
    /// 同じdeviceIdへ直接再接続を試みる。
    func retryReconnect() {
        guard let deviceId else { return }
        state = .connecting
        csvLogger?.logEvent("retry_reconnect_requested")
        do {
            try api.connectToDevice(deviceId)
        } catch {
            state = .unexpectedDisconnect("再接続に失敗: \(error.localizedDescription)")
        }
    }

    func handleFeatureReady(_ feature: PolarBleSdkFeature) {
        print("[Feature] ready: \(feature) (state=\(state))")
        guard feature == .feature_polar_device_control,
              let deviceId,
              state == .settingUp else { return }
        ftuTask?.cancel()
        ftuTask = Task { @MainActor [weak self] in
            await self?.prepareDeviceAndStartStreams(deviceId: deviceId)
        }
    }

    /// 再接続の度に必ず行う処理をまとめたもの:
    /// 1. FTU済みか確認し、未実施なら実行
    /// 2. デバイス時刻を再同期
    /// 3. ストリーミング開始
    /// 4. オフライン記録の自動同期
    /// 5. 次回起動時の自動再接続用にdeviceIdを保存
    @MainActor
    private func prepareDeviceAndStartStreams(deviceId: String) async {
        do {
            let ftuDone = try await api.isFtuDone(deviceId)
            if ftuDone {
                csvLogger?.logEvent("ftu_already_done")
            } else {
                await performFirstTimeUse(deviceId: deviceId)
            }
        } catch {
            // 確認自体が失敗した場合は、安全側に倒して実行しておく
            await performFirstTimeUse(deviceId: deviceId)
        }

        do {
            try await api.setLocalTime(deviceId, time: Date(), zone: TimeZone.current)
            csvLogger?.logEvent("time_synced")
        } catch {
            print("[Time] setLocalTime failed for \(deviceId): \(error)")
        }

        // オンラインモードの場合、以前オフラインモードで使っていたセンサーだと
        // 実際にまだセンサー側で記録が動いている可能性がある。問答無用で止めず、
        // 実際に記録中かどうかを確認してから、必要な場合だけユーザーに確認を取る。
        if mode == .online {
            do {
                let status = try await api.getOfflineRecordingStatus(deviceId)
                let hasActiveRecording = [PolarDeviceDataType.hr, .skinTemperature, .acc]
                    .contains { status[$0] == true }
                print("[Config] online conflict check status=\(status) hasActiveRecording=\(hasActiveRecording)")
                if hasActiveRecording {
                    pendingOnlineDeviceId = deviceId
                    offlineRecordingConflictDetected = true
                    csvLogger?.logEvent("online_mode_conflict_detected_awaiting_confirmation")
                    return // ユーザーの確認待ち。設定画面にはまだ進まない。
                }
            } catch {
                print("[Offline] getOfflineRecordingStatus failed(オンライン開始続行): \(error)")
            }
        } else {
            // オフラインモード: 既にHR・体表温が記録中(=切断/モード変更を挟んだだけで、
            // 記録自体は止めていない再接続)であれば、今さらHzを選び直させても意味が無い
            // (既に記録中のものはstartOfflineRecordingを呼んでもスキップされ、設定は反映されない)。
            // 加速度は「計測しない」選択もあり得るため、この判定には含めない。
            // その場合は設定画面を飛ばし、そのまま計測継続扱いにする。
            do {
                let status = try await api.getOfflineRecordingStatus(deviceId)
                let allActive = [PolarDeviceDataType.hr, .skinTemperature]
                    .allSatisfy { status[$0] == true }
                print("[Config] offline resume check status=\(status) allActive=\(allActive)")
                if allActive {
                    csvLogger?.logEvent("offline_recording_already_active_resuming")
                    startMeasurementAfterConfiguring()
                    return
                }
                // 記録は動いていない。センサー内に前回未取得のまま残っているデータがないか確認する。
                let counts = try await offlineEntryCounts(deviceId: deviceId)
                if counts.total > 0 {
                    print("[Offline] pending unfetched data found hr=\(counts.hr) skinTemp=\(counts.skinTemp) acc=\(counts.acc)")
                    csvLogger?.logEvent("pending_offline_data_detected hr=\(counts.hr) skinTemp=\(counts.skinTemp) acc=\(counts.acc)")
                    UserDefaults.standard.set(deviceId, forKey: lastDeviceIdKey)
                    UserDefaults.standard.set(deviceName, forKey: lastDeviceNameKey)
                    state = .pendingOfflineData(hrCount: counts.hr, skinTempCount: counts.skinTemp, accCount: counts.acc)
                    return
                }
            } catch {
                print("[Offline] getOfflineRecordingStatus failed(設定画面へ続行): \(error)")
            }
        }

        print("[Config] transitioning to .configuring for deviceId=\(deviceId)")
        state = .configuring
        csvLogger?.logEvent("awaiting_measurement_settings")
        await loadRateOptions(deviceId: deviceId)

        UserDefaults.standard.set(deviceId, forKey: lastDeviceIdKey)
        UserDefaults.standard.set(deviceName, forKey: lastDeviceNameKey)
    }

    /// 設定画面(.configuring)で選べる体表温・加速度のHz候補を、
    /// センサーから実際に取得して反映する。モードに応じて取得元のAPIを切り替える。
    @MainActor
    private func loadRateOptions(deviceId: String) async {
        do {
            let tempSettings: PolarSensorSetting
            let accSettings: PolarSensorSetting
            switch mode {
            case .online:
                tempSettings = try await api.requestStreamSettings(deviceId, feature: .skinTemperature)
                accSettings = try await api.requestStreamSettings(deviceId, feature: .acc)
            case .offline:
                tempSettings = try await api.requestOfflineRecordingSettings(deviceId, feature: .skinTemperature)
                accSettings = try await api.requestOfflineRecordingSettings(deviceId, feature: .acc)
            }
            configuringSkinTempRateOptions = Array(tempSettings.settings[.sampleRate] ?? []).sorted()
            configuringAccRateOptions = Array(accSettings.settings[.sampleRate] ?? []).sorted()
            print("[Config] mode=\(mode) skinTempOptions=\(configuringSkinTempRateOptions) accOptions=\(configuringAccRateOptions)")

            // デフォルトは「候補にあれば1Hz/10Hz、無ければ最小値」を選んでおく
            selectedSkinTempRateHz = configuringSkinTempRateOptions.contains(1) ? 1 : (configuringSkinTempRateOptions.min() ?? 1)
            selectedAccRateHz = configuringAccRateOptions.contains(10) ? 10 : (configuringAccRateOptions.min() ?? 10)
        } catch {
            print("[Config] loadRateOptions failed: \(error)")
            errorMessage = "設定候補の取得に失敗しました: \(error.localizedDescription)"
        }
    }

    /// 設定画面で「測定開始」が押された時に呼ぶ。
    /// オフラインモードで危険な加速度レートが選ばれている場合は、先に警告を出す。
    func confirmMeasurementSettings() {
        if measureAcc, mode == .offline, selectedAccRateHz > safeOfflineAccRateHz {
            showAccRiskWarning = true
            return
        }
        startMeasurementAfterConfiguring()
    }

    /// 警告で「続行する」を選んだ時に呼ぶ。
    func proceedDespiteAccRiskWarning() {
        showAccRiskWarning = false
        startMeasurementAfterConfiguring()
    }

    /// 警告で「設定をやり直す」を選んだ時に呼ぶ。設定画面に留まる。
    func dismissAccRiskWarningToReconfigure() {
        showAccRiskWarning = false
    }

    private func startMeasurementAfterConfiguring() {
        guard let deviceId else { return }
        state = .connected
        csvLogger?.logEvent("measurement_started skinTempHz=\(selectedSkinTempRateHz) accHz=\(selectedAccRateHz)")
        if mode == .offline {
            LastMeasurementSettingsStore.shared.record(
                deviceId: deviceId,
                skinTempHz: selectedSkinTempRateHz,
                accHz: selectedAccRateHz,
                measureAcc: measureAcc
            )
        }
        startStreams(deviceId: deviceId)
        Task { @MainActor [weak self] in
            await self?.updateDiskSpaceEstimate(deviceId: deviceId)
        }
    }

    // MARK: - 残り記録可能時間の推定
    // getDiskSpace()で取得した残り容量を「チェックポイント」として記録し、
    // 前回チェックポイントとの差分から消費レート(bytes/秒)を計算する。
    // チェックポイントとレートはUserDefaultsに永続化し、アプリ再起動後も引き継ぐ。

    private func diskCheckpointKey(deviceId: String) -> String { "diskCheckpoint_\(deviceId)" }
    private func diskRateKey(deviceId: String) -> String { "diskRateBytesPerSecond_\(deviceId)" }

    @MainActor
    private func updateDiskSpaceEstimate(deviceId: String) async {
        do {
            let disk = try await api.getDiskSpace(deviceId)
            let now = Date()

            if let savedData = UserDefaults.standard.data(forKey: diskCheckpointKey(deviceId: deviceId)),
               let previous = try? JSONDecoder().decode(DiskCheckpoint.self, from: savedData) {
                let elapsed = now.timeIntervalSince(previous.date)
                // 容量が実際に減っていて、かつある程度の時間が経っている場合だけレートを更新する。
                // (同期でデータを削除すると容量が増えることがあるため、そのケースは無視する)
                if elapsed > 15, disk.freeSpace < previous.freeSpace {
                    let consumedBytes = Double(previous.freeSpace - disk.freeSpace)
                    let newRate = consumedBytes / elapsed
                    let oldRate = diskConsumptionRateBytesPerSecond ?? UserDefaults.standard.double(forKey: diskRateKey(deviceId: deviceId))
                    // 簡単な指数移動平均でならして、1回のブレに引っ張られすぎないようにする
                    let smoothedRate = oldRate > 0 ? (oldRate * 0.5 + newRate * 0.5) : newRate
                    diskConsumptionRateBytesPerSecond = smoothedRate
                    UserDefaults.standard.set(smoothedRate, forKey: diskRateKey(deviceId: deviceId))
                }
            } else {
                // 初回はUserDefaultsに保存済みのレートがあれば復元しておく
                let savedRate = UserDefaults.standard.double(forKey: diskRateKey(deviceId: deviceId))
                if savedRate > 0 {
                    diskConsumptionRateBytesPerSecond = savedRate
                }
            }

            let checkpoint = DiskCheckpoint(date: now, freeSpace: disk.freeSpace, totalSpace: disk.totalSpace)
            diskCheckpoint = checkpoint
            if let encoded = try? JSONEncoder().encode(checkpoint) {
                UserDefaults.standard.set(encoded, forKey: diskCheckpointKey(deviceId: deviceId))
            }
            csvLogger?.logEvent("disk_free_bytes=\(disk.freeSpace)")
        } catch {
            print("[Disk] getDiskSpace failed for \(deviceId): \(error)")
        }
    }

    /// 現在時刻を基準に、最後のチェックポイントと消費レートから残り記録可能時間を推定する。
    /// レートがまだ計算できていない(チェックポイントが1回分しかない)場合はnilを返す。
    func estimatedRemainingSeconds(asOf now: Date = Date()) -> TimeInterval? {
        guard let checkpoint = diskCheckpoint,
              let rate = diskConsumptionRateBytesPerSecond,
              rate > 0 else { return nil }
        let elapsed = now.timeIntervalSince(checkpoint.date)
        let remainingBytes = Double(checkpoint.freeSpace) - rate * elapsed
        guard remainingBytes > 0 else { return 0 }
        return remainingBytes / rate
    }

    // MARK: - FTU
    // NOTE: PolarFirstTimeUseConfigの正確なプロパティ名・必須項目は、
    // 導入時に一度 Xcode の自動補完 / FirstTimeUse.md ドキュメントで必ず確認すること。
    // ここでは「値の中身自体は今回の用途では使わない」前提でダミー値を入れている。

    @MainActor
    private func performFirstTimeUse(deviceId: String) async {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let ftuConfig = PolarFirstTimeUseConfig(
            gender: .male,
            birthDate: Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date(),
            height: 170,
            weight: 65,
            maxHeartRate: 190,
            vo2Max: 40,
            restingHeartRate: 60,
            trainingBackground: .occasional,
            deviceTime: isoFormatter.string(from: Date()),
            typicalDay: .mostlySitting,
            sleepGoalMinutes: 480
        )

        do {
            try await api.doFirstTimeUse(deviceId, ftuConfig: ftuConfig)
            print("[FTU] doFirstTimeUse succeeded for \(deviceId)")
            csvLogger?.logEvent("ftu_succeeded")
        } catch {
            // NOTE: 一旦エラーを握りつぶさず、必ずコンソールと画面の両方に出す。
            // (センサーのLEDがペアリングモードのまま = FTUが実際には失敗している可能性が高いため)
            print("[FTU] doFirstTimeUse FAILED for \(deviceId): \(error)")
            csvLogger?.logEvent("ftu_failed: \(error.localizedDescription)")
            self.errorMessage = "FTU失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - ストリーミング開始

    private func startStreams(deviceId: String) {
        // HRも含めて、オンラインモードは「接続中のみ」、オフラインモードは
        // 「センサー内蔵記録+定期同期」に完全に統一する。
        startHrStreaming(deviceId: deviceId)
        startTempAccForCurrentMode(deviceId: deviceId)
    }

    private func startTempAccForCurrentMode(deviceId: String) {
        switch mode {
        case .online:
            startSkinTemperatureStreamingOnline(deviceId: deviceId)
            if measureAcc {
                startAccStreamingOnline(deviceId: deviceId)
            }
        case .offline:
            startHrOfflineRecordingIfNeeded(deviceId: deviceId)
            startOfflineRecordingIfNeeded(deviceId: deviceId)
            // 少し待ってから状態確認する(記録開始コマンドが反映されるまでの猶予)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.checkOfflineRecordingStatus(deviceId: deviceId)
            }
            startPeriodicDiskSpaceCheck(deviceId: deviceId)
        }
    }

    /// 記録の停止/開始とは無関係に、残り容量(getDiskSpace)だけを定期的に確認する。
    /// これは読み取り専用の問い合わせで、記録には一切影響しない
    /// (停止/開始を伴う同期とは完全に別の仕組み)。
    private func startPeriodicDiskSpaceCheck(deviceId: String) {
        diskCheckTask?.cancel()
        diskCheckTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30秒間隔
                guard let self, !Task.isCancelled, self.deviceId == deviceId else { return }
                await self.updateDiskSpaceEstimate(deviceId: deviceId)
            }
        }
    }

    /// センサー側で実際に記録が動いているかどうかだけを確認する(停止・取得は行わない)。
    /// 20秒ごとの自動同期は記録の空白を作ってしまうため廃止し、
    /// 代わりにこの軽量な確認 + 手動の「同期」ボタンに一本化した。
    @Published var recordingStatusText: String?

    private func checkOfflineRecordingStatus(deviceId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.api.getOfflineRecordingStatus(deviceId)
                let hr = status[.hr] == true
                let temp = status[.skinTemperature] == true
                // 加速度を計測しない設定なら、記録されていなくても正常なので判定対象から外す
                let acc = self.measureAcc ? (status[.acc] == true) : true
                self.isAccStreaming = hr && temp && acc
                if hr && temp && acc {
                    self.recordingStatusText = self.measureAcc ? "記録中(HR・体表温・加速度)" : "記録中(HR・体表温、加速度は計測なし)"
                } else {
                    var missing: [String] = []
                    if !hr { missing.append("HR") }
                    if !temp { missing.append("体表温") }
                    if self.measureAcc, !acc { missing.append("加速度") }
                    self.recordingStatusText = "記録停止中: \(missing.joined(separator: "・"))"
                    self.errorMessage = "一部のセンサー記録が開始されていません: \(missing.joined(separator: "・"))"
                }
                self.csvLogger?.logEvent("recording_status hr=\(hr) temp=\(temp) acc=\(acc) measureAcc=\(self.measureAcc)")
            } catch {
                self.recordingStatusText = "記録状況の確認に失敗しました"
                print("[Offline] checkOfflineRecordingStatus failed: \(error)")
            }
        }
    }

    /// 確認ダイアログで「記録を停止して続行」を選んだ時に呼ぶ。
    /// 記録を停止してから、設定画面(.configuring)へ進む。
    func confirmStopOfflineRecordingAndProceed() {
        guard let deviceId = pendingOnlineDeviceId else { return }
        offlineRecordingConflictDetected = false
        pendingOnlineDeviceId = nil
        csvLogger?.logEvent("user_confirmed_stop_offline_for_online_mode")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for feature: PolarDeviceDataType in [.hr, .skinTemperature, .acc] {
                do {
                    try await self.api.stopOfflineRecording(deviceId, feature: feature)
                    print("[Offline] stopped \(feature) offline recording for online mode")
                    self.csvLogger?.logEvent("offline_recording_stopped_for_online_mode feature=\(feature)")
                } catch {
                    print("[Offline] stopOfflineRecording(\(feature)) failed(無視可): \(error)")
                }
            }
            self.state = .configuring
            self.csvLogger?.logEvent("awaiting_measurement_settings")
            await self.loadRateOptions(deviceId: deviceId)
        }
    }

    /// 確認ダイアログで「キャンセル」を選んだ時に呼ぶ。記録は止めず、接続だけ切る。
    func cancelOnlineConnectionDueToConflict() {
        offlineRecordingConflictDetected = false
        pendingOnlineDeviceId = nil
        csvLogger?.logEvent("user_cancelled_online_connection_due_to_offline_conflict")
        disconnectAndForget()
    }

    /// 候補(available.settings)の中に希望のサンプルレートがあればそれを選び、
    /// 無ければ最大値にフォールバックする。サンプルレート以外の項目(解像度・レンジ等)は
    /// 最大値を選ぶ(データ量への影響が小さいため)。
    private func polarSensorSetting(from available: PolarSensorSetting, preferredSampleRate: UInt32) -> PolarSensorSetting {
        var chosen: [PolarSensorSetting.SettingType: UInt32] = [:]
        for (key, values) in available.settings {
            if key == .sampleRate {
                chosen[key] = values.contains(preferredSampleRate) ? preferredSampleRate : (values.max() ?? preferredSampleRate)
            } else {
                chosen[key] = values.max() ?? 0
            }
        }
        return (try? PolarSensorSetting(chosen)) ?? available.maxSettings()
    }

    /// HRのオフライン記録開始(モードに関わらず常時。HRはオンライン+オフライン併用可能なため)
    private func startHrOfflineRecordingIfNeeded(deviceId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.api.getOfflineRecordingStatus(deviceId)
                if status[.hr] != true {
                    try await self.api.startOfflineRecording(deviceId, feature: .hr, settings: nil, secret: nil)
                    print("[Offline] started hr recording for \(deviceId)")
                }
            } catch {
                print("[Offline] hr start failed for \(deviceId): \(error)")
            }
        }
    }

    /// 体表温・加速度のオフライン記録開始(offlineモード時のみ呼ばれる)。
    /// 既に記録中なら何もしない(getOfflineRecordingStatusで確認)。
    private func startOfflineRecordingIfNeeded(deviceId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.api.getOfflineRecordingStatus(deviceId)

                if status[.skinTemperature] != true {
                    let settings = try await self.api.requestOfflineRecordingSettings(deviceId, feature: .skinTemperature)
                    let chosen = self.polarSensorSetting(from: settings, preferredSampleRate: self.selectedSkinTempRateHz)
                    try await self.api.startOfflineRecording(deviceId, feature: .skinTemperature, settings: chosen, secret: nil)
                    print("[Offline] started skinTemperature recording for \(deviceId) settings=\(chosen)")
                }

                // 加速度もHR/体表温と同様、切断中の欠測を防ぐためオフライン記録の対象にする
                // NOTE: Polar 360のオフライン加速度記録には、取得時にクラッシュ/エラーになる
                // 既知の不具合報告がある(SDK Issue #716, #652)。設定画面で選ばれたレートを使う
                // (safeOfflineAccRateHzを超える場合は、事前に警告済み)。
                // measureAccがfalseの場合は、加速度は計測しない選択なので何もしない。
                if self.measureAcc, status[.acc] != true {
                    let settings = try await self.api.requestOfflineRecordingSettings(deviceId, feature: .acc)
                    let chosen = self.polarSensorSetting(from: settings, preferredSampleRate: self.selectedAccRateHz)
                    try await self.api.startOfflineRecording(deviceId, feature: .acc, settings: chosen, secret: nil)
                    print("[Offline] started acc recording for \(deviceId) settings=\(chosen)")
                }
            } catch {
                print("[Offline] start failed for \(deviceId): \(error)")
            }
        }
    }

    private func startHrStreaming(deviceId: String) {
        hrTask?.cancel()
        hrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await dataList in self.api.startHrStreaming(deviceId) {
                    if let sample = dataList.first {
                        let bpm = Int(sample.hr)
                        let now = Date()
                        self.heartRate = bpm
                        // オフラインモードでは、センサー内蔵の記録から後で正しいHRが
                        // 抽出・保存されるため、ここでライブ書き込みすると同じ時間帯が
                        // 二重にCSVへ記録されてしまう。画面表示の更新のみに留める。
                        if self.mode == .online {
                            self.csvLogger?.logHr(bpm)
                        }
                        self.hrHistory.append(HrPoint(date: now, bpm: bpm))
                        self.trimOldHistory()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "HR取得エラー: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - オンラインモード(体表温・加速度)

    private func startSkinTemperatureStreamingOnline(deviceId: String) {
        // 重要: firmware 2.0.8以降は `.temperature`/`startTemperatureStreaming` ではなく
        // `.skinTemperature`/`startSkinTemperatureStreaming` を使う必要がある
        // (返り値の型は変わらず PolarTemperatureData)。SDK issue #656 参照。
        tempTask?.cancel()
        tempTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let settings = try await self.api.requestStreamSettings(deviceId, feature: .skinTemperature)
                let chosen = self.polarSensorSetting(from: settings, preferredSampleRate: self.selectedSkinTempRateHz)
                for try await data in self.api.startSkinTemperatureStreaming(deviceId, settings: chosen) {
                    for sample in data.samples {
                        let celsius = Double(sample.temperature)
                        // 受信時刻ではなく、センサー側が付与した正確なタイムスタンプを使う
                        let date = self.polarEpochDate(nanoseconds: sample.timeStamp)
                        self.csvLogger?.logSkinTemperature(celsius, at: date)
                        self.skinTempHistory.append(SkinTempPoint(date: date, celsius: celsius))
                    }
                    if let last = data.samples.last {
                        self.skinTemperature = Double(last.temperature)
                    }
                    self.trimOldHistory()
                }
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "体表温取得エラー: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startAccStreamingOnline(deviceId: String) {
        accTask?.cancel()
        accTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let settings = try await self.api.requestStreamSettings(deviceId, feature: .acc)
                let chosen = self.polarSensorSetting(from: settings, preferredSampleRate: self.selectedAccRateHz)
                for try await data in self.api.startAccStreaming(deviceId, settings: chosen) {
                    self.isAccStreaming = true
                    // NOTE: PolarAccDataも体表温と同様、サンプルごとに正確なタイムスタンプ
                    // (sample.timeStamp、ナノ秒・エポックは2000/1/1)を持っているので、
                    // それをそのまま使う(以前は誤って受信時刻からの近似値を使っていた)。
                    for sample in data {
                        let date = self.polarEpochDate(nanoseconds: sample.timeStamp)
                        self.csvLogger?.logAcc(x: Int(sample.x), y: Int(sample.y), z: Int(sample.z), at: date)
                    }
                    // グラフも全サンプルを反映する(以前は1回の通知につき1点だけに
                    // 間引いていたため、実際のHzより粗くカクカクして見えていた)。
                    // その代わり保持時間をaccHistoryRetentionMinutes(短め)に抑えて負荷を軽減する。
                    for sample in data {
                        let date = self.polarEpochDate(nanoseconds: sample.timeStamp)
                        self.accHistory.append(AccPoint(date: date, x: sample.x, y: sample.y, z: sample.z))
                    }
                    self.trimOldHistory()
                }
            } catch {
                self.isAccStreaming = false
                if !Task.isCancelled {
                    self.errorMessage = "加速度取得エラー: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - オフライン記録(取りこぼし防止の保険)
    // NOTE: PolarOfflineRecordingApiの正確なメソッド名(開始/一覧取得/取得/削除)は
    // HR/体表温/加速度と同じ要領(Cmdクリックでジャンプ)で実物を確認してから実装すること。
    // ここではUI側の受け口だけ用意し、中身は未実装。

    /// 記録の停止は呼び出し側の責任。一覧取得→(進捗付き)取得→CSV保存→削除を行い、
    /// 結果のサマリー情報を返す。途中経過はstopPhase/hrProgress等のPublishedプロパティに反映する。
    @MainActor
    private func fetchAndSaveAllOfflineEntries(deviceId: String) async -> (successCount: Int, failCount: Int, tally: [String: Int], earliest: Date?, latest: Date?) {
        var successCount = 0
        var failCount = 0
        var tally: [String: Int] = [:]
        var earliest: Date?
        var latest: Date?
        do {
            // センサーが返す一覧の順序が必ずしも時系列順とは限らないため、
            // 一旦すべて集めてから記録開始時刻(entry.date)順に並べ替えて処理する。
            // (そうしないとCSV内の行が時系列で前後し、グラフの折れ線が
            // おかしく繋がって見える原因になる)
            var entries: [PolarOfflineRecordingEntry] = []
            for try await entry in api.listOfflineRecordings(deviceId) {
                entries.append(entry)
            }
            // 種類優先(データ量が軽く処理が速いHR→体表温→加速度の順)で並べ、
            // 同じ種類内では記録開始時刻の早い順にする。
            // 万が一途中で処理が滞っても、少なくとも軽いHR・体表温は先に
            // 回収・消去し終えられるようにするための優先順位。
            entries.sort { lhs, rhs in
                let lhsPriority = typePriority(lhs.type)
                let rhsPriority = typePriority(rhs.type)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.date < rhs.date
            }

            // 種類ごとの合計件数を先に数えておく(「(1/2件)」のような表示のため)
            hrProgress = TypeProgress(totalCount: entries.filter { $0.type == .hr }.count)
            skinTempProgress = TypeProgress(totalCount: entries.filter { $0.type == .skinTemperature }.count)
            accProgress = TypeProgress(totalCount: entries.filter { $0.type == .acc }.count)

            for entry in entries {
                let typeLabel = displayLabel(for: entry.type)
                do {
                    stopPhase = .fetchingEntry(type: typeLabel)
                    print("[Offline] ▶ fetchingEntry start type=\(typeLabel) path=\(entry.path)")
                    var finalData: PolarOfflineRecordingData?
                    for try await progressResult in api.getOfflineRecordWithProgress(deviceId, entry: entry, secret: nil) {
                        switch progressResult {
                        case .progress(let progress):
                            setCurrentPercent(for: entry.type, percent: progress.progressPercent)
                        case .complete(let data):
                            finalData = data
                        }
                    }
                    guard let data = finalData else {
                        throw NSError(domain: "Polar360Panel", code: -1, userInfo: [NSLocalizedDescriptionKey: "データが空でした"])
                    }
                    print("[Offline] ✓ fetchingEntry done type=\(typeLabel) path=\(entry.path)")

                    stopPhase = .savingCsv(type: typeLabel)
                    print("[Offline] ▶ savingCsv start type=\(typeLabel) path=\(entry.path)")
                    let result = await saveOfflineRecordingData(data)
                    tally[result.label, default: 0] += result.count
                    if let first = result.first, earliest == nil || first < earliest! { earliest = first }
                    if let last = result.last, latest == nil || last > latest! { latest = last }
                    print("[Offline] ✓ savingCsv done type=\(typeLabel) path=\(entry.path) count=\(result.count)")

                    stopPhase = .erasingMemory(type: typeLabel)
                    print("[Offline] ▶ erasingMemory start type=\(typeLabel) path=\(entry.path)")
                    // 複数センサーを同時に同期するとBLE帯域が混み合い、20秒では
                    // 「応答が返る前にアプリ側が諦めてしまう」誤検知が起きやすかったため延長。
                    // なお、タイムアウトしてもCSV保存自体は既に完了済みなのでデータロスは無く、
                    // 実際にはセンサー側の消去処理自体は継続していることが多い(後述のメッセージ参照)。
                    let removed = await withTimeout(seconds: 45) {
                        try await self.api.removeOfflineRecord(deviceId, entry: entry)
                    }
                    if removed != nil {
                        print("[Offline] ✓ erasingMemory done type=\(typeLabel) path=\(entry.path)")
                        csvLogger?.logEvent("offline_synced_removed path=\(entry.path) type=\(result.label) count=\(result.count)")
                        successCount += 1
                    } else {
                        print("[Offline] ✗ erasingMemory TIMEOUT(20s) type=\(typeLabel) path=\(entry.path) ※CSV保存自体は完了済みなのでデータロスはない")
                        csvLogger?.logEvent("offline_remove_timeout path=\(entry.path) type=\(result.label)")
                        failCount += 1
                    }
                    advanceProgress(for: entry.type)
                } catch {
                    print("[Offline] ✗ fetch/save failed for \(entry.path): \(error)")
                    csvLogger?.logEvent("offline_sync_entry_failed path=\(entry.path)")
                    failCount += 1
                    advanceProgress(for: entry.type)
                }
            }
        } catch {
            print("[Offline] listOfflineRecordings failed: \(error)")
        }

        // NOTE: 以前ここで自動収集データ(deleteStoredDeviceData)もまとめて削除していたが、
        // 未対応のデータ種別を渡すとSDK内部でfatal error(強制アンラップでクラッシュ)になる
        // ことが分かったため撤回した。try/catchでは捕まえられない致命的なクラッシュのため、
        // 安全な種別の切り分けができるまでは対応しない。

        stopPhase = .done
        return (successCount, failCount, tally, earliest, latest)
    }

    /// 指定秒数以内に処理が終わらなければタイムアウトとしてnilを返す(ハング防止用の汎用ヘルパー)。
    /// removeOfflineRecordのように、BLE応答が返ってこない場合に無限に待ち続けてしまう
    /// 呼び出しを、この関数でラップすることで一定時間で諦められるようにする。
    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func displayLabel(for type: PolarDeviceDataType) -> String {
        switch type {
        case .hr: return "HR"
        case .skinTemperature: return "体表温"
        case .acc: return "加速度"
        default: return "\(type)"
        }
    }

    /// 抽出処理の優先順位(小さいほど先に処理する)。
    /// データ量が軽く処理が速い順(HR→体表温→加速度)にしておくことで、
    /// 途中で問題が起きても軽いものは先に回収・消去できているようにする。
    private func typePriority(_ type: PolarDeviceDataType) -> Int {
        switch type {
        case .hr: return 0
        case .skinTemperature: return 1
        case .acc: return 2
        default: return 3
        }
    }

    /// センサー内に残っている未取得の記録を、種類別に件数だけ数える(取得はしない)。
    private func offlineEntryCounts(deviceId: String) async throws -> (hr: Int, skinTemp: Int, acc: Int, total: Int) {
        var entries: [PolarOfflineRecordingEntry] = []
        for try await entry in api.listOfflineRecordings(deviceId) {
            entries.append(entry)
        }
        let hr = entries.filter { $0.type == .hr }.count
        let skinTemp = entries.filter { $0.type == .skinTemperature }.count
        let acc = entries.filter { $0.type == .acc }.count
        return (hr, skinTemp, acc, entries.count)
    }

    // MARK: - 未取得データへの対応(.pendingOfflineData状態からの3アクション)

    /// 「抽出する」: 計測終了時と全く同じ処理(取得→CSV保存→メモリ消去)を行い、
    /// 終わったら計測終了時と同様サマリーを表示 → OKで切断、という流れにする。
    func extractPendingOfflineData() {
        guard let deviceId else { return }
        isSyncing = true
        stopPhase = .stoppingRecording
        hrProgress = TypeProgress()
        skinTempProgress = TypeProgress()
        accProgress = TypeProgress()
        csvLogger?.logEvent("pending_data_extraction_requested")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isSyncing = false
                self.stopPhase = .idle
            }
            let result = await self.fetchAndSaveAllOfflineEntries(deviceId: deviceId)
            self.lastOfflineSyncDate = Date()
            let summary = self.buildSyncSummary(
                successCount: result.successCount, failCount: result.failCount,
                tally: result.tally, earliest: result.earliest, latest: result.latest
            )
            self.lastSyncSummary = summary
            // 計測終了時と同じサマリーダイアログを再利用し、OKが押されたら切断する
            self.measurementStopSummary = summary
        }
    }

    /// 「削除する」: 取得せずそのままセンサー内蔵メモリの記録を削除する。
    /// 確認ダイアログの表示自体はView側の責任(誤操作防止のため)。
    func deletePendingOfflineDataWithoutExtracting() {
        guard let deviceId else { return }
        isSyncing = true
        csvLogger?.logEvent("pending_data_delete_without_extract_requested")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSyncing = false }
            var deletedCount = 0
            var failedCount = 0
            do {
                var entries: [PolarOfflineRecordingEntry] = []
                for try await entry in self.api.listOfflineRecordings(deviceId) {
                    entries.append(entry)
                }
                for entry in entries {
                    do {
                        try await self.api.removeOfflineRecord(deviceId, entry: entry)
                        deletedCount += 1
                    } catch {
                        failedCount += 1
                    }
                }
            } catch {
                print("[Offline] pending data delete: listOfflineRecordings failed: \(error)")
            }

            // NOTE: ここでも同様にdeleteStoredDeviceDataを撤回した(SDK内部でクラッシュするため)。

            print("[Offline] pending data deleted(未取得のまま破棄) count=\(deletedCount) failed=\(failedCount)")
            self.csvLogger?.logEvent("pending_data_deleted count=\(deletedCount) failed=\(failedCount)")
            let summary = "\(deletedCount)件削除(未取得のまま破棄) / \(failedCount)件失敗"
            self.lastSyncSummary = summary
            // こちらも計測終了時と同じサマリーダイアログを再利用する
            self.measurementStopSummary = summary
        }
    }

    /// 「無視して新しい計測を始める」: 古いデータには一切触れず、通常の計測設定画面へ進む。
    func ignorePendingOfflineDataAndConfigure() {
        guard let deviceId else { return }
        csvLogger?.logEvent("pending_data_ignored_proceeding_to_configure")
        state = .configuring
        Task { @MainActor [weak self] in
            await self?.loadRateOptions(deviceId: deviceId)
        }
    }

    private func setCurrentPercent(for type: PolarDeviceDataType, percent: Int) {
        switch type {
        case .hr: hrProgress.currentPercent = percent
        case .skinTemperature: skinTempProgress.currentPercent = percent
        case .acc: accProgress.currentPercent = percent
        default: break
        }
    }

    /// 1件分の処理(成功・失敗問わず)が終わった時に呼び、完了数を進める。
    private func advanceProgress(for type: PolarDeviceDataType) {
        switch type {
        case .hr:
            hrProgress.completedCount += 1
            hrProgress.currentPercent = 0
        case .skinTemperature:
            skinTempProgress.completedCount += 1
            skinTempProgress.currentPercent = 0
        case .acc:
            accProgress.completedCount += 1
            accProgress.currentPercent = 0
        default: break
        }
    }

    private func buildSyncSummary(successCount: Int, failCount: Int, tally: [String: Int], earliest: Date?, latest: Date?) -> String {
        if failCount > 0 {
            // failCountは「データ抽出の失敗」ではなく「センサー内蔵メモリの消去が
            // 時間内に完了しなかった」ことを指す。CSV保存自体は既に完了済みなので、
            // データが失われたわけではないことを明示する。
            return "データ取得は完了しました(\(successCount)件消去済み / \(failCount)件は消去に時間がかかっています)。"
                + "しばらくしてから再度接続すると自動的に解消される場合がありますが、"
                + "解消しない場合はセンサー管理画面の「メモリ消去」から削除してください。"
        } else if tally.isEmpty {
            return "取得対象なし(最新)"
        } else {
            let breakdown = ["HR", "体表温", "加速度"]
                .compactMap { label -> String? in
                    guard let count = tally[label] else { return nil }
                    return "\(label) \(count)件"
                }
                .joined(separator: " / ")
            if let earliest, let latest {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                return "\(breakdown) (\(formatter.string(from: earliest))〜\(formatter.string(from: latest)))"
            } else {
                return breakdown
            }
        }
    }

    /// Polarのタイムスタンプ(ナノ秒、エポックは2000-01-01 00:00:00 UTC)をDateに変換する
    private func polarEpochDate(nanoseconds: UInt64) -> Date {
        let epoch2000 = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01T00:00:00Z
        return epoch2000.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
    }

    /// 取得したオフライン記録データの中身を種類別にCSVへ保存する。
    /// HRだけはサンプルごとのタイムスタンプを持たないため、startTimeから1Hz想定で近似する。
    /// 戻り値: (種類ラベル, サンプル数, 最初の日時, 最後の日時) — サマリー表示用
    /// 取得したオフライン記録データの中身を種類別にCSVへ保存する。
    /// HRだけはサンプルごとのタイムスタンプを持たないため、startTimeから1Hz想定で近似する。
    /// 戻り値: (種類ラベル, サンプル数, 最初の日時, 最後の日時) — サマリー表示用
    ///
    /// NOTE: 加速度のように長時間分のデータが溜まっていると数十万〜100万件規模になり、
    /// @MainActor上で一度もawaitを挟まない完全同期ループが数分単位で固まって見える
    /// (最悪の場合、iOSに強制終了・サスペンドされてデータが途中までしか保存されない)
    /// 原因になっていたため、まとめてバッチ書き込みし、定期的にTask.yield()で
    /// 実行を区切っている。
    @MainActor
    private func saveOfflineRecordingData(_ data: PolarOfflineRecordingData) async -> (label: String, count: Int, first: Date?, last: Date?) {
        switch data {
        case .hrOfflineRecordingData(let samples, let startTime):
            print("[Offline] hr samples count=\(samples.count)")
            var lines: [String] = []
            lines.reserveCapacity(samples.count)
            var lastDate: Date?
            for (index, sample) in samples.enumerated() {
                let approxDate = startTime.addingTimeInterval(Double(index))
                lines.append("\(CsvLogger.isoString(approxDate)),\(sample.hr)")
                lastDate = approxDate
            }
            await csvLogger?.appendBatch(lines, kind: "hr", header: "timestamp,hr_bpm")
            return ("HR", samples.count, samples.isEmpty ? nil : startTime, lastDate)

        case .skinTemperatureOfflineRecordingData(let tempData, _):
            print("[Offline] skinTemp samples count=\(tempData.samples.count)")
            var lines: [String] = []
            lines.reserveCapacity(tempData.samples.count)
            var first: Date?
            var last: Date?
            for sample in tempData.samples {
                let date = polarEpochDate(nanoseconds: sample.timeStamp)
                lines.append("\(CsvLogger.isoString(date)),\(String(format: "%.3f", sample.temperature))")
                if first == nil { first = date }
                last = date
            }
            await csvLogger?.appendBatch(lines, kind: "skintemp", header: "timestamp,skin_temperature_c")
            // 疑似リアルタイム表示用に、直近の値を画面にも反映する
            if let lastSample = tempData.samples.last {
                self.skinTemperature = Double(lastSample.temperature)
            }
            return ("体表温", tempData.samples.count, first, last)

        case .accOfflineRecordingData(let accData, _, _):
            print("[Offline] acc samples count=\(accData.count)")
            var first: Date?
            var last: Date?
            let flushSize = 20_000
            var batch: [(x: Int, y: Int, z: Int, date: Date)] = []
            batch.reserveCapacity(min(accData.count, flushSize))
            for (index, sample) in accData.enumerated() {
                let date = polarEpochDate(nanoseconds: sample.timeStamp)
                batch.append((x: Int(sample.x), y: Int(sample.y), z: Int(sample.z), date: date))
                if first == nil { first = date }
                last = date
                if batch.count >= flushSize {
                    await csvLogger?.logAccBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    accProgress.currentPercent = accData.isEmpty ? 100 : min(100, Int(Double(index + 1) / Double(accData.count) * 100))
                    // 完全同期ループのままだとUIが固まって見えるため、ここで一度制御を返す
                    await Task.yield()
                }
            }
            if !batch.isEmpty {
                await csvLogger?.logAccBatch(batch)
            }
            accProgress.currentPercent = 100
            if !accData.isEmpty {
                // 「取得中」インジケータとして、直近の同期で実際にデータが取れたことを示す
                self.isAccStreaming = true
            }
            return ("加速度", accData.count, first, last)

        case .emptyData:
            return ("(空)", 0, nil, nil)
        default:
            print("[Offline] 未対応のオフラインデータ種別のためスキップ")
            return ("(未対応)", 0, nil, nil)
        }
    }

    // MARK: - 切断(未ペアリング状態に戻す)

    /// アプリ側の接続を切る。
    /// 注意: iOS(CoreBluetooth)の仕様上、サードパーティアプリがOSレベルの
    /// Bluetoothボンディング情報そのものを消すAPIは公開されていない。
    /// Polar 360は「一度ペアリングした相手以外を受け付けない」仕様のため、
    /// 別の相手(元のサードパーティアプリ等)と組ませ直したい場合は、
    /// 本体側のファクトリーリセット、および必要ならiOS設定アプリ側の
    /// Bluetoothペアリング情報削除もあわせて案内すること。
    /// 接続中(connecting/settingUp/configuring)に、途中で止められなくなった時に使う。
    /// 同じセンサーを別のパネルでも選んでしまった場合など、コールバックが正しい相手に
    /// 届かなくなって「ぐるぐる」から戻れなくなるケースの回避策として使う。
    func cancelConnection() {
        ftuTask?.cancel()
        stopAllStreams()
        if let deviceId {
            disconnectReason = .userDisconnect
            csvLogger?.logEvent("connection_cancelled_by_user")
            do {
                try api.disconnectFromDevice(deviceId)
            } catch {
                print("[Cancel] disconnectFromDevice failed(無視可): \(error)")
            }
            PolarManager.shared.unregister(deviceId: deviceId)
            UserDefaults.standard.removeObject(forKey: lastDeviceIdKey)
            UserDefaults.standard.removeObject(forKey: lastDeviceNameKey)
        }
        self.deviceId = nil
        self.deviceName = ""
        self.errorMessage = nil
        self.batteryLevel = nil
        csvLogger?.closeAccFile()
        self.csvLogger = nil
        self.state = .idle
    }

    func disconnectAndForget() {
        guard let deviceId else { return }
        disconnectReason = .userDisconnect
        stopAllStreams()
        csvLogger?.logEvent("manual_disconnect")
        do {
            try api.disconnectFromDevice(deviceId)
        } catch {
            errorMessage = "切断エラー: \(error.localizedDescription)"
        }
        PolarManager.shared.unregister(deviceId: deviceId)
        UserDefaults.standard.removeObject(forKey: lastDeviceIdKey)
        UserDefaults.standard.removeObject(forKey: lastDeviceNameKey)
        self.deviceId = nil
        self.deviceName = ""
        self.state = .idle
        self.heartRate = nil
        self.skinTemperature = nil
        self.batteryLevel = nil
        self.lastOfflineSyncDate = nil
        self.pendingOfflineEntries = 0
        csvLogger?.closeAccFile()
        self.csvLogger = nil
    }

    @Published var measurementStopSummary: String?

    /// 「計測終了」: センサー側の記録(HR/体表温/加速度)を停止し、
    /// その時点までのデータを取得・CSV保存してから、結果サマリーを表示する。
    /// 実際の切断(検索画面へ戻る)は、そのサマリーで「OK」が押されてから行う。
    func stopMeasurement() {
        guard let deviceId else { return }
        isSyncing = true
        stopPhase = .stoppingRecording
        hrProgress = TypeProgress()
        skinTempProgress = TypeProgress()
        accProgress = TypeProgress()
        csvLogger?.logEvent("measurement_stop_requested")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isSyncing = false
                self.stopPhase = .idle
            }
            for feature: PolarDeviceDataType in [.hr, .skinTemperature, .acc] {
                do {
                    try await self.api.stopOfflineRecording(deviceId, feature: feature)
                    self.csvLogger?.logEvent("offline_recording_stopped_by_user feature=\(feature)")
                } catch {
                    // 元々記録していなければエラーになるが無視してよい
                    print("[Offline] stopOfflineRecording(\(feature)) on measurement stop failed(無視可): \(error)")
                }
            }
            // 停止しただけでは取得したことにならないため、ここで最後まで取得・保存する
            let result = await self.fetchAndSaveAllOfflineEntries(deviceId: deviceId)
            self.lastOfflineSyncDate = Date()
            let summary = self.buildSyncSummary(
                successCount: result.successCount, failCount: result.failCount,
                tally: result.tally, earliest: result.earliest, latest: result.latest
            )
            self.lastSyncSummary = summary
            // ここで即切断せず、結果サマリーを表示してユーザーの確認を待つ
            self.measurementStopSummary = summary
        }
    }

    /// 計測終了の結果サマリーで「OK」を押した時に呼ぶ。ここで初めて実際に切断し、
    /// センサーを探す画面(idle)へ戻す。
    func acknowledgeMeasurementStopAndReturnToSearch() {
        measurementStopSummary = nil
        disconnectAndForget()
    }

    private func stopAllStreams() {
        ftuTask?.cancel()
        hrTask?.cancel()
        tempTask?.cancel()
        accTask?.cancel()
        diskCheckTask?.cancel()
        isAccStreaming = false
    }

    // MARK: - オンラインモード専用: 計測終了/再計測/検索画面へ戻る

    /// 「計測終了」(オンラインモード用): ここまでのデータはCSVに保存済みのまま、
    /// ストリーミングを止めて切断する。ただし「切断」ボタンと違い、
    /// 検索画面には戻さず、その時点までのグラフをそのまま見返せる状態(.measurementStopped)にする。
    func stopOnlineMeasurement() {
        guard let deviceId else { return }
        disconnectReason = .measurementStop
        stopAllStreams()
        csvLogger?.logEvent("measurement_stop_requested_online")
        do {
            try api.disconnectFromDevice(deviceId)
        } catch {
            errorMessage = "切断エラー: \(error.localizedDescription)"
        }
        // コールバック(handleDisconnected)が来るまで待たず、先に表示だけ切り替えておく
        state = .measurementStopped
    }

    /// .measurementStopped から、同じセンサーで新しい計測を開始する。
    /// グラフ履歴をリセットし、新しいセッション(＝新しいCSVファイル)として開始する。
    func startNewMeasurement() {
        guard let deviceId else { return }
        csvLogger?.closeAccFile()
        csvLogger = CsvLogger(deviceId: deviceId, mode: mode)
        csvLogger?.logEvent("new_measurement_started")
        hrHistory = []
        skinTempHistory = []
        accHistory = []
        heartRate = nil
        skinTemperature = nil
        state = .connecting
        do {
            try api.connectToDevice(deviceId)
        } catch {
            state = .error("再接続に失敗: \(error.localizedDescription)")
        }
    }

    /// .measurementStopped から、完全に切断してセンサーを探す画面に戻る。
    func returnToSearchScreen() {
        guard let deviceId else {
            state = .idle
            return
        }
        PolarManager.shared.unregister(deviceId: deviceId)
        UserDefaults.standard.removeObject(forKey: lastDeviceIdKey)
        UserDefaults.standard.removeObject(forKey: lastDeviceNameKey)
        self.deviceId = nil
        self.deviceName = ""
        self.heartRate = nil
        self.skinTemperature = nil
        self.hrHistory = []
        self.skinTempHistory = []
        self.accHistory = []
        csvLogger?.closeAccFile()
        self.csvLogger = nil
        state = .idle
    }
}
