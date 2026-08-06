import Foundation
import CoreBluetooth
import PolarBleSdk

/// PolarBleApiの observer / deviceInfoObserver 等はプロパティが1つずつしかなく、
/// 「デバイスごと」ではなく「アプリ全体で1つ」しか設定できない。
/// そのため、コールバックを受け取ってから deviceId を見て正しいパネル(SensorSlotViewModel)に
/// 振り分ける役目をこのクラスが担う。SensorSlotViewModel自身はAPIのobserverにはならない。
final class PolarManager: NSObject, ObservableObject,
                           PolarBleApiObserver,
                           PolarBleApiDeviceInfoObserver,
                           PolarBleApiDeviceFeaturesObserver,
                           PolarBleApiPowerStateObserver {

    static let shared = PolarManager()

    var api: PolarBleApi

    @Published var discoveredDevices: [PolarDeviceInfo] = []
    @Published var isBluetoothOn: Bool = false

    // deviceId -> 対応するパネルのViewModel
    private var slots: [String: PolarDeviceEventReceiver] = [:]

    private var scanTask: Task<Void, Never>?

    private override init() {
        api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_hr,
                .feature_battery_info,
                .feature_device_info,
                .feature_polar_online_streaming,
                .feature_polar_offline_recording,
                .feature_polar_device_time_setup,
                .feature_polar_device_control
            ]
        )
        super.init()
        api.observer = self
        api.deviceInfoObserver = self
        api.deviceFeaturesObserver = self
        api.powerStateObserver = self
    }

    // MARK: - 登録/解除

    func register(slot: PolarDeviceEventReceiver, forDeviceId deviceId: String) {
        slots[deviceId] = slot
    }

    func unregister(deviceId: String) {
        slots[deviceId] = nil
    }

    /// このdeviceIdが現在いずれかのパネルで接続登録されている(＝アプリが実際に
    /// CSVへ書き込んでいる可能性がある)かどうか。名前変更(フォルダ名リネーム)前の
    /// 安全確認に使う。
    func isDeviceActive(_ deviceId: String) -> Bool {
        slots[deviceId] != nil
    }

    // MARK: - スキャン
    // searchForDevice() は AsyncThrowingStream を返す(8.1時点)。
    // Polar 360 は BLE アドバタイズ名が "Polar 360 xxxxxxxx" のような形式なので "Polar" で絞り込み。

    func startScan() {
        discoveredDevices = []
        scanTask?.cancel()
        // SDK内部に溜まった「使用していない既知デバイス」の情報をリセットしてからスキャンする。
        // (未接続センサーが見つからない問題の切り分け用)
        api.cleanup()
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // デバッグのため一時的にSDK側の名前フィルターを外し、全デバイスを見る。
                // (一度も接続したことのないセンサーが、名前フィルターのせいで
                // リストに出てこないのではないかを確認するため)
                for try await info in self.api.searchForDevice(withNameContaining: nil) {
                    print("[Scan-debug] name='\(info.name)' id=\(info.deviceId)")
                    if info.name.contains("Polar"),
                       !self.discoveredDevices.contains(where: { $0.deviceId == info.deviceId }) {
                        print("[Scan] found \(info.name) hasSAGRFCFileSystem=\(info.hasSAGRFCFileSystem)")
                        self.discoveredDevices.append(info)
                        SensorNicknameStore.shared.registerKnownDevice(info.deviceId)
                    }
                }
            } catch {
                // スキャン自体のエラーは各パネル側の状態には影響させない
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - PolarBleApiObserver
    // NOTE: SDK内部の実装によっては、これらのコールバックがメインスレッド以外から
    // 呼ばれることがある(Publishing changes from background threads 警告の原因)。
    // @Publishedを触る処理は必ずメインスレッドにホップしてから実行する。

    func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.slots[polarDeviceInfo.deviceId]?.handleConnecting()
        }
    }

    func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.slots[polarDeviceInfo.deviceId]?.handleConnected()
        }
    }

    func deviceDisconnected(_ polarDeviceInfo: PolarDeviceInfo, pairingError: Bool) {
        // SDKが渡してくるpairingErrorだけだと、実際にはペアリング解除が原因でも
        // falseのまま(単なるタイムアウト扱い)になることがあるため、
        // checkIfDeviceDisconnectedDueRemovedPairingでも重ねて確認し、
        // どちらかがtrueならペアリング解除扱いにする。
        let confirmedByCheck = (try? api.checkIfDeviceDisconnectedDueRemovedPairing(polarDeviceInfo.deviceId)) ?? false
        let effectivePairingError = pairingError || confirmedByCheck
        DispatchQueue.main.async { [weak self] in
            self?.slots[polarDeviceInfo.deviceId]?.handleDisconnected(pairingError: effectivePairingError)
        }
    }

    // MARK: - PolarBleApiDeviceInfoObserver
    // NOTE: Xcodeが「Add protocol stubs」で追加した分の中に、
    // ここに載っていないメソッドがあれば、それは消さずに残しておくこと。

    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        DispatchQueue.main.async { [weak self] in
            self?.slots[identifier]?.batteryLevel = Int(batteryLevel)
        }
    }

    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        // Device Information Service由来の情報。今回は未使用。
    }

    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: PolarBleSdk.BleBasClient.ChargeState) {
        // 今回は未使用
    }

    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        // 今回は未使用
    }

    // MARK: - PolarBleApiDeviceFeaturesObserver

    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        DispatchQueue.main.async { [weak self] in
            self?.slots[identifier]?.handleFeatureReady(feature)
        }
    }

    // MARK: - PolarBleApiPowerStateObserver

    func blePowerOn() {
        DispatchQueue.main.async { [weak self] in
            self?.isBluetoothOn = true
        }
    }

    func blePowerOff() {
        DispatchQueue.main.async { [weak self] in
            self?.isBluetoothOn = false
        }
    }
}
