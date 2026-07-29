import SwiftUI

struct OfflineDashboardView: View {
    let onChangeMode: () -> Void

    @StateObject private var slot1 = SensorSlotViewModel(slotIndex: 0, mode: .offline)
    @StateObject private var slot2 = SensorSlotViewModel(slotIndex: 1, mode: .offline)
    @StateObject private var slot3 = SensorSlotViewModel(slotIndex: 2, mode: .offline)
    @StateObject private var slot4 = SensorSlotViewModel(slotIndex: 3, mode: .offline)
    @State private var showUsageGuide = false
    @State private var showModeChangeConfirmation = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("オフラインモード").font(.subheadline).bold()
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
            HStack(spacing: 6) {
                OfflineSensorPanelView(viewModel: slot1)
                OfflineSensorPanelView(viewModel: slot2)
            }
            HStack(spacing: 6) {
                OfflineSensorPanelView(viewModel: slot3)
                OfflineSensorPanelView(viewModel: slot4)
            }
        }
        .padding(6)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            slot1.autoReconnectIfPossible()
            slot2.autoReconnectIfPossible()
            slot3.autoReconnectIfPossible()
            slot4.autoReconnectIfPossible()
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

    private func requestChangeMode() {
        let anyMeasuring = [slot1, slot2, slot3, slot4].contains { $0.state == .connected }
        if anyMeasuring {
            showModeChangeConfirmation = true
        } else {
            disconnectAllAndChangeMode()
        }
    }

    private func disconnectAllAndChangeMode() {
        [slot1, slot2, slot3, slot4].forEach { $0.disconnectAndForget() }
        onChangeMode()
    }
}
