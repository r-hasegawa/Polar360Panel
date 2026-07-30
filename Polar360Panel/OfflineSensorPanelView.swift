import SwiftUI
import PolarBleSdk

struct OfflineSensorPanelView: View {
    @ObservedObject var viewModel: SensorSlotViewModel
    @ObservedObject private var manager = PolarManager.shared
    @State private var showDeviceList = false
    /// 台数を可変にできるオフラインモード専用。未接続時にこのパネル自体を
    /// 削除したい時に呼ばれる(nilならボタンを出さない=オンライン側では未使用)。
    var onRemove: (() -> Void)? = nil

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
        .alert("計測終了", isPresented: Binding(
            get: { viewModel.measurementStopSummary != nil },
            set: { if !$0 { viewModel.acknowledgeMeasurementStopAndReturnToSearch() } }
        )) {
            Button("OK") {
                viewModel.acknowledgeMeasurementStopAndReturnToSearch()
            }
        } message: {
            Text(viewModel.measurementStopSummary ?? "")
        }
        .alert("加速度の記録エラーが起きる可能性があります", isPresented: $viewModel.showAccRiskWarning) {
            Button("設定をやり直す", role: .cancel) {
                viewModel.dismissAccRiskWarningToReconfigure()
            }
            Button("このまま続行する", role: .destructive) {
                viewModel.proceedDespiteAccRiskWarning()
            }
        } message: {
            Text("選択した加速度のレート(\(viewModel.selectedAccRateHz)Hz)は、Polar 360のオフライン記録で取得時にエラーになる可能性が報告されています。10Hz以下に設定し直すことを推奨します。")
        }
    }

    private var borderColor: Color {
        switch viewModel.state {
        case .error: return .red
        case .unexpectedDisconnect: return .orange
        case .connected: return .green
        default: return .gray
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(SensorNicknameStore.shared.displayName(for: viewModel.deviceId))
                .font(.headline)
            Spacer()
            if let battery = viewModel.batteryLevel {
                Text("\(battery)%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if viewModel.state == .idle, let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
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
            VStack(spacing: 8) {
                ProgressView("接続中...")
                Button("キャンセル") { viewModel.cancelConnection() }
                    .font(.caption)
                    .foregroundColor(.red)
            }

        case .settingUp:
            VStack(spacing: 8) {
                ProgressView("初期設定中...")
                Button("キャンセル") { viewModel.cancelConnection() }
                    .font(.caption)
                    .foregroundColor(.red)
            }

        case .configuring:
            measurementSettingsView

        case .connected:
            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).font(.caption2).foregroundColor(.red)
                }

                // 簡易な生存確認用(グラフではなく数値のみ)
                HStack {
                    Text("HR")
                        .font(.caption).foregroundColor(.secondary)
                    Text(viewModel.heartRate.map { "\($0) bpm" } ?? "--")
                        .font(.title3).bold()
                }

                Divider()

                // 記録状況(接続時に一度だけ確認。以降は「同期」ボタンで更新)
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isAccStreaming ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(viewModel.recordingStatusText ?? "記録状況を確認中...")
                        .font(.caption)
                }

                // 計測終了時の取得結果(接続中は特に何も起きない。取得は計測終了時のみ)
                VStack(alignment: .leading, spacing: 2) {
                    if viewModel.isSyncing {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.6)
                            Text(phaseText(viewModel.stopPhase))
                        }
                        progressRow(label: "HR", progress: viewModel.hrProgress)
                        progressRow(label: "体表温", progress: viewModel.skinTempProgress)
                        progressRow(label: "加速度", progress: viewModel.accProgress)
                    } else if let summary = viewModel.lastSyncSummary {
                        Text(summary).foregroundColor(.green)
                        if let date = viewModel.lastOfflineSyncDate {
                            Text("前回の取得 \(date.formatted(date: .omitted, time: .shortened))")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("記録中(まだ計測終了していません)").foregroundColor(.secondary)
                    }
                }
                .font(.caption)

                Divider()

                // メモリ残量
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        if let checkpoint = viewModel.diskCheckpoint {
                            Text("前回確認時 \(checkpoint.date.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("残り容量 \(formattedBytes(checkpoint.freeSpace)) (\(formattedPercent(checkpoint)))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let remaining = viewModel.estimatedRemainingSeconds(asOf: context.date) {
                            Text("残り記録可能時間(推定) \(formattedDuration(remaining))")
                                .font(.caption)
                                .foregroundColor(remaining < 3600 ? .red : .primary)
                                .bold()
                        } else {
                            Text("残り時間: 計測中(2回確認後に推定開始)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
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
                Text("記録は継続中のはずです(オフラインモード)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("再接続を試す") {
                    viewModel.retryReconnect()
                }
                .buttonStyle(.borderedProminent)
            }

        case .measurementStopped:
            // オフラインモードでは使わない状態(オンラインモード専用)だが、
            // SlotStateを共有しているため網羅のために用意している。
            Text("計測終了(オンラインモード専用の状態です)")
                .font(.caption2)
                .foregroundColor(.secondary)

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
                    if viewModel.selectedAccRateHz > 10 {
                        Text("⚠️ 10Hzを超えるレートは、Polar 360のオフライン加速度記録で取得時にエラーが起きる可能性が報告されています")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                Button("測定開始") {
                    viewModel.confirmMeasurementSettings()
                }
                .buttonStyle(.borderedProminent)
                Button("キャンセル") { viewModel.cancelConnection() }
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
    }

    private func phaseText(_ phase: OfflineStopPhase) -> String {
        switch phase {
        case .idle: return ""
        case .stoppingRecording: return "記録停止中..."
        case .fetchingEntry(let type): return "データ取得中...(\(type))"
        case .savingCsv(let type): return "CSVに保存中...(\(type))"
        case .erasingMemory(let type): return "内蔵メモリ消去中...(\(type))"
        case .done: return "完了"
        }
    }

    @ViewBuilder
    private func progressRow(label: String, progress: TypeProgress) -> some View {
        if progress.totalCount > 0 {
            HStack(spacing: 4) {
                Circle()
                    .fill(progress.completedCount >= progress.totalCount ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text("\(label) (\(progress.displayIndex)/\(progress.totalCount)件) \(progress.currentPercent)%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formattedPercent(_ checkpoint: DiskCheckpoint) -> String {
        guard checkpoint.totalSpace > 0 else { return "--%" }
        let percent = Double(checkpoint.freeSpace) / Double(checkpoint.totalSpace) * 100.0
        return String(format: "%.0f%%", percent)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "約\(hours)時間\(minutes)分" : "約\(minutes)分"
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if viewModel.state == .connected {
                Button("切断") { viewModel.disconnectAndForget() }
                    .font(.caption)
                    .foregroundColor(.red)

                Button(viewModel.isSyncing ? "取得中..." : "計測終了") {
                    viewModel.stopMeasurement()
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red)
                .cornerRadius(6)
                .disabled(viewModel.isSyncing)
            }
        }
    }

    @ViewBuilder
    private var deviceListSheet: some View {
        NavigationView {
            List(manager.discoveredDevices.filter { !PolarManager.shared.isDeviceActive($0.deviceId) }, id: \.deviceId) { device in
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
