import SwiftUI

struct OfflineDashboardView: View {
    let onChangeMode: () -> Void

    @AppStorage("offlineGridColumns") private var gridColumns: Int = 2
    @State private var slots: [SensorSlotViewModel] = []
    @State private var nextSlotIndex: Int = 0
    @State private var showUsageGuide = false
    @State private var showModeChangeConfirmation = false
    @State private var pendingStopSlot: SensorSlotViewModel?
    @State private var showMultiSyncConfirm = false

    private let slotIndicesKey = "offlineSlotIndices"

    /// slotsをgridColumns列ずつの行に分割する
    private var rows: [[SensorSlotViewModel]] {
        stride(from: 0, to: slots.count, by: gridColumns).map {
            Array(slots[$0..<min($0 + gridColumns, slots.count)])
        }
    }

    private var syncingCount: Int {
        slots.filter { $0.isSyncing }.count
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("オフラインモード(\(slots.count)台・\(gridColumns)列)").font(.subheadline).bold()
                Spacer()
                Button {
                    addSlot()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .font(.caption)
                Button {
                    showUsageGuide = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .font(.caption)
                Button("モード変更") {
                    requestChangeMode()
                }
                .font(.caption)
            }
            // 常時表示の注意書き(A)。押しつけがましくならないよう小さく・さりげなく。
            Text("複数台同時に計測終了すると処理が遅くなることがあります(データが消えることはありません)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                ScrollView {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(rows.indices, id: \.self) { rowIndex in
                            GridRow {
                                ForEach(0..<gridColumns, id: \.self) { colIndex in
                                    if colIndex < rows[rowIndex].count {
                                        let slot = rows[rowIndex][colIndex]
                                        OfflineSensorPanelView(
                                            viewModel: slot,
                                            onRemove: { removeSlot(slot) },
                                            onRequestStop: { requestStop(for: slot) }
                                        )
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    } else {
                                        Color.clear
                                    }
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .padding(6)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if slots.isEmpty {
                loadOrCreateInitialSlots()
            }
        }
        .sheet(isPresented: $showUsageGuide) {
            UsageGuideView()
        }
        .alert("モードを変更しますか?", isPresented: $showModeChangeConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("変更する", role: .destructive) {
                disconnectAllAndChangeMode()
            }
        } message: {
            Text("計測中のパネルがあります。センサー内蔵の記録はそのまま継続されますが、アプリ側の表示(残り容量・記録状況など)はリセットされます。")
        }
        // 複数台同時実行時の確認(B)。実際にもう1台以上が同期中の時だけ出す。
        .alert("他に\(syncingCount)台が同期中です", isPresented: $showMultiSyncConfirm) {
            Button("キャンセル", role: .cancel) {
                pendingStopSlot = nil
            }
            Button("同時に進める") {
                pendingStopSlot?.stopMeasurement()
                pendingStopSlot = nil
            }
        } message: {
            Text("同時に進めると処理が遅くなることがあります。データが消えることはありませんが、途中でアプリを終了した場合、その時点で処理中だったセンサーの分だけ、もう一度同じ抽出をやり直す必要があります。")
        }
    }

    private func loadOrCreateInitialSlots() {
        let saved = UserDefaults.standard.array(forKey: slotIndicesKey) as? [Int] ?? []
        let indices = saved.isEmpty ? [0, 1, 2, 3] : saved
        slots = indices.map { SensorSlotViewModel(slotIndex: $0, mode: .offline) }
        slots.forEach { $0.autoReconnectIfPossible() }
        nextSlotIndex = (indices.max() ?? -1) + 1
        persistSlotIndices()
    }

    private func persistSlotIndices() {
        UserDefaults.standard.set(slots.map { $0.slotIndex }, forKey: slotIndicesKey)
    }

    private func addSlot() {
        let newSlot = SensorSlotViewModel(slotIndex: nextSlotIndex, mode: .offline)
        nextSlotIndex += 1
        slots.append(newSlot)
        persistSlotIndices()
    }

    private func removeSlot(_ slot: SensorSlotViewModel) {
        guard slot.state == .idle else { return } // 念のため、未接続時だけ削除可能
        slots.removeAll { $0.id == slot.id }
        persistSlotIndices()
    }

    /// 「計測終了」が押された時の入り口。他に同期中のセンサーがいなければそのまま進め、
    /// いれば確認アラートを挟む。
    private func requestStop(for slot: SensorSlotViewModel) {
        let othersSyncing = slots.filter { $0.id != slot.id && $0.isSyncing }.count
        if othersSyncing > 0 {
            pendingStopSlot = slot
            showMultiSyncConfirm = true
        } else {
            slot.stopMeasurement()
        }
    }

    private func requestChangeMode() {
        let anyMeasuring = slots.contains { $0.state == .connected }
        if anyMeasuring {
            showModeChangeConfirmation = true
        } else {
            disconnectAllAndChangeMode()
        }
    }

    private func disconnectAllAndChangeMode() {
        slots.forEach { $0.disconnectAndForget() }
        onChangeMode()
    }
}
