import SwiftUI
import Charts
import PolarBleSdk

struct OnlineSensorPanelView: View {
    @ObservedObject var viewModel: SensorSlotViewModel
    @ObservedObject private var manager = PolarManager.shared
    @State private var showDeviceList = false

    private static let windowOptions: [Double] = [10.0 / 60.0, 1, 3, 5, 10, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(borderColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 2))
        .sheet(isPresented: $showDeviceList) { deviceListSheet }
        .alert("センサー内蔵メモリへの記録が動作中です", isPresented: Binding(
            get: { viewModel.offlineRecordingConflictDetected },
            set: { if !$0 { viewModel.cancelOnlineConnectionDueToConflict() } }
        )) {
            Button("記録を停止して続行", role: .destructive) {
                viewModel.confirmStopOfflineRecordingAndProceed()
            }
            Button("キャンセル(切断)", role: .cancel) {
                viewModel.cancelOnlineConnectionDueToConflict()
            }
        } message: {
            Text("このセンサーは以前オフラインモードで使われており、まだ記録中の可能性があります。オンラインモードで続行すると、その記録は停止されます。")
        }
    }

    private var borderColor: Color {
        switch viewModel.state {
        case .error: return .red
        case .unexpectedDisconnect: return .orange
        case .connected: return .green
        case .measurementStopped: return .blue
        default: return .gray
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(SensorNicknameStore.shared.displayName(for: viewModel.deviceId))
                .font(.headline)
            Spacer()
            if viewModel.state == .connected || viewModel.state == .measurementStopped {
                Picker("表示範囲", selection: $viewModel.graphWindowMinutes) {
                    ForEach(Self.windowOptions, id: \.self) { minutes in
                        Text(minutes < 1 ? "\(Int(minutes * 60))秒" : "\(Int(minutes))分").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }
            if let battery = viewModel.batteryLevel {
                Text("\(battery)%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            Button {
                manager.startScan()
                showDeviceList = true
            } label: {
                Label("センサーを探す", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)

        case .connecting:
            ProgressView("接続中...")

        case .settingUp:
            ProgressView("初期設定中...")

        case .configuring:
            measurementSettingsView

        case .connected:
            VStack(alignment: .leading, spacing: 4) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).font(.caption2).foregroundColor(.red)
                }
                Text("HR \(viewModel.heartRate.map { "\($0)" } ?? "--") bpm")
                    .font(.headline)
                hrChart
                Text("体表温 \(viewModel.skinTemperature.map { String(format: "%.2f", $0) } ?? "--") ℃")
                    .font(.headline)
                skinTempChart
                if viewModel.measureAcc {
                    Text("加速度(X/Y/Z) \(viewModel.selectedAccRateHz)Hz")
                        .font(.headline)
                    accChart
                }
            }

        case .measurementStopped:
            VStack(alignment: .leading, spacing: 4) {
                Text("計測終了 — ここまでのグラフ")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text("HR (最終値 \(viewModel.heartRate.map { "\($0)" } ?? "--") bpm)")
                    .font(.headline)
                hrChart
                Text("体表温 (最終値 \(viewModel.skinTemperature.map { String(format: "%.2f", $0) } ?? "--") ℃)")
                    .font(.headline)
                skinTempChart
                if viewModel.measureAcc {
                    Text("加速度(X/Y/Z)")
                        .font(.headline)
                    accChart
                }
            }

        case .unexpectedDisconnect(let message):
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                Text("オンラインモードのため、この間のデータは記録されていません")
                    .font(.caption2)
                    .foregroundColor(.red)
                Button("再接続を試す") {
                    viewModel.retryReconnect()
                }
                .buttonStyle(.borderedProminent)
            }

        case .error(let message):
            VStack(spacing: 8) {
                Text(message).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
                Button("再スキャン") {
                    manager.startScan()
                    showDeviceList = true
                }
            }
        }
    }

    private var windowStart: Date {
        Date().addingTimeInterval(-viewModel.graphWindowMinutes * 60)
    }

    @ViewBuilder
    private var measurementSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("計測設定").font(.headline)

            if viewModel.configuringSkinTempRateOptions.isEmpty && viewModel.configuringAccRateOptions.isEmpty {
                ProgressView("設定候補を取得中...")
            } else {
                HStack {
                    Text("体表温")
                    Spacer()
                    Picker("体表温Hz", selection: $viewModel.selectedSkinTempRateHz) {
                        ForEach(viewModel.configuringSkinTempRateOptions, id: \.self) { rate in
                            Text("\(rate)Hz").tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("加速度を計測する", isOn: $viewModel.measureAcc)
                if viewModel.measureAcc {
                    HStack {
                        Text("加速度")
                        Spacer()
                        Picker("加速度Hz", selection: $viewModel.selectedAccRateHz) {
                            ForEach(viewModel.configuringAccRateOptions, id: \.self) { rate in
                                Text("\(rate)Hz").tag(rate)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Text("※ 加速度のグラフ履歴は直近3分間のみ保持されます(HR・体表温は最大60分)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("測定開始") {
                    viewModel.confirmMeasurementSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var hrChart: some View {
        Chart(viewModel.hrHistory.filter { $0.date >= windowStart }) { point in
            LineMark(x: .value("時刻", point.date), y: .value("HR", point.bpm))
                .foregroundStyle(.red)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 70)
    }

    @ViewBuilder
    private var skinTempChart: some View {
        Chart(viewModel.skinTempHistory.filter { $0.date >= windowStart }) { point in
            LineMark(x: .value("時刻", point.date), y: .value("体表温", point.celsius))
                .foregroundStyle(.orange)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 70)
    }

    @ViewBuilder
    private var accChart: some View {
        Chart(viewModel.accHistory.filter { $0.date >= windowStart }) { point in
            LineMark(x: .value("時刻", point.date), y: .value("値", point.x))
                .foregroundStyle(by: .value("軸", "X"))
            LineMark(x: .value("時刻", point.date), y: .value("値", point.y))
                .foregroundStyle(by: .value("軸", "Y"))
            LineMark(x: .value("時刻", point.date), y: .value("値", point.z))
                .foregroundStyle(by: .value("軸", "Z"))
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 90)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if viewModel.state == .connected {
                Button("計測終了") {
                    viewModel.stopOnlineMeasurement()
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue)
                .cornerRadius(6)

                Button("切断") { viewModel.disconnectAndForget() }
                    .font(.caption)
                    .foregroundColor(.red)
            } else if viewModel.state == .measurementStopped {
                Button("新しい計測を開始") {
                    viewModel.startNewMeasurement()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)

                Button("切断") { viewModel.returnToSearchScreen() }
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var deviceListSheet: some View {
        NavigationView {
            List(manager.discoveredDevices, id: \.deviceId) { device in
                Button {
                    manager.stopScan()
                    showDeviceList = false
                    viewModel.connect(to: device)
                } label: {
                    VStack(alignment: .leading) {
                        Text(SensorNicknameStore.shared.displayName(for: device.deviceId))
                        Text(device.deviceId).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("センサーを選択")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        manager.stopScan()
                        showDeviceList = false
                    }
                }
            }
        }
    }
}
