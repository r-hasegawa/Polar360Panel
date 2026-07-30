import SwiftUI

struct OnlineDashboardView: View {
    let onChangeMode: () -> Void

    @StateObject private var slot1 = SensorSlotViewModel(slotIndex: 0, mode: .online)
    @StateObject private var slot2 = SensorSlotViewModel(slotIndex: 1, mode: .online)
    @StateObject private var slot3 = SensorSlotViewModel(slotIndex: 2, mode: .online)
    @StateObject private var slot4 = SensorSlotViewModel(slotIndex: 3, mode: .online)
    @AppStorage("onlineGridColumns") private var gridColumns: Int = 2
    @State private var showUsageGuide = false
    @State private var showModeChangeConfirmation = false

    private var slots: [SensorSlotViewModel] { [slot1, slot2, slot3, slot4] }

    /// slotsをgridColumns列ずつの行に分割する
    private var rows: [[SensorSlotViewModel]] {
        stride(from: 0, to: slots.count, by: gridColumns).map {
            Array(slots[$0..<min($0 + gridColumns, slots.count)])
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("オンラインモード(最大4台・\(gridColumns)列)").font(.subheadline).bold()
                Spacer()
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
            ScrollView {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(0..<gridColumns, id: \.self) { colIndex in
                                if colIndex < rows[rowIndex].count {
                                    OnlineSensorPanelView(viewModel: rows[rowIndex][colIndex])
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Color.clear
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            slots.forEach { $0.autoReconnectIfPossible() }
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
            Text("計測中のパネルがあります。計測中のデータはCSVには残りますが、グラフ履歴は失われます。")
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
