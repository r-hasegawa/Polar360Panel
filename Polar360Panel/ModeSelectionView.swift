import SwiftUI

struct ModeSelectionView: View {
    let onSelect: (SensorMode) -> Void
    @State private var showUsageGuide = false
    @State private var showSensorManagement = false
    @State private var showDataManagement = false

    var body: some View {
        VStack(spacing: 32) {
            Text("計測モードを選択")
                .font(.title)
                .bold()

            HStack(spacing: 24) {
                modeButton(
                    mode: .online,
                    title: "オンラインモード",
                    description: "体表温・加速度をリアルタイム表示\n(グラフ中心、切断中の記録なし)",
                    color: .blue
                )
                modeButton(
                    mode: .offline,
                    title: "オフラインモード",
                    description: "センサー内蔵メモリに常時記録\n(データ保全・メモリ残量中心)",
                    color: .green
                )
            }

            HStack(spacing: 16) {
                Button {
                    showSensorManagement = true
                } label: {
                    Label("センサー管理", systemImage: "tag")
                }
                .buttonStyle(.bordered)

                Button {
                    showDataManagement = true
                } label: {
                    Label("データ管理", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    showUsageGuide = true
                } label: {
                    Label("このアプリの使い方", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showUsageGuide) {
            UsageGuideView()
        }
        .sheet(isPresented: $showSensorManagement) {
            SensorManagementView()
        }
        .sheet(isPresented: $showDataManagement) {
            DataManagementView()
        }
    }

    @ViewBuilder
    private func modeButton(mode: SensorMode, title: String, description: String, color: Color) -> some View {
        Button {
            onSelect(mode)
        } label: {
            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .bold()
                Text(description)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(width: 260, height: 180)
            .background(color.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(color, lineWidth: 2))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
