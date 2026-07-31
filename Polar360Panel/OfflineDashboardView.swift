import SwiftUI

struct OfflineDashboardView: View {
    let onChangeMode: () -> Void

    @AppStorage("offlineGridColumns") private var gridColumns: Int = 2
    @State private var slots: [SensorSlotViewModel] = []
    @State private var nextSlotIndex: Int = 0
    @State private var showUsageGuide = false
    @State private var showModeChangeConfirmation = false

    private let slotIndicesKey = "offlineSlotIndices"

    /// slotsをgridColumns列ずつの行に分割する
    private var rows: [[SensorSlotViewModel]] {
        stride(from: 0, to: slots.count, by: gridColumns).map {
            Array(slots[$0..<min($0 + gridColumns, slots.count)])
        }
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
            GeometryReader { geo in
                ScrollView {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(rows.indices, id: \.self) { rowIndex in
                            GridRow {
                                ForEach(0..<gridColumns, id: \.self) { colIndex in
                                    if colIndex < rows[rowIndex].count {
                                        let slot = rows[rowIndex][colIndex]
                                        OfflineSensorPanelView(viewModel: slot) {
                                            removeSlot(slot)
                                        }
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
