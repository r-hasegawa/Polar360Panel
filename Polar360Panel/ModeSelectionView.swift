import SwiftUI

struct ModeSelectionView: View {
    let onSelect: (SensorMode) -> Void
    @AppStorage("onlineGridColumns") private var onlineGridColumns: Int = 2
    @AppStorage("offlineGridColumns") private var offlineGridColumns: Int = 2
    @State private var showUsageGuide = false
    @State private var showSensorManagement = false
    @State private var showDataManagement = false

    /// Xcodeの Target → General → Identity → Version(CFBundleShortVersionString)を
    /// 実行時に読み取って表示する。ここを手動で書き換える必要は無い。
    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version)"
    }

    var body: some View {
        VStack(spacing: 32) {
            Text("計測モードを選択")
                .font(.title)
                .bold()

            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 8) {
                    modeButton(
                        mode: .online,
                        title: "オンラインモード",
                        description: "体表温・加速度をリアルタイム表示\n(グラフ中心、切断中の記録なし)\n最大4台まで",
                        color: .blue
                    )
                    columnPicker(title: "列数", selection: $onlineGridColumns)
                }
                VStack(spacing: 8) {
                    modeButton(
                        mode: .offline,
                        title: "オフラインモード",
                        description: "センサー内蔵メモリに常時記録\n(データ保全・メモリ残量中心)\n台数の上限なし",
                        color: .green
                    )
                    columnPicker(title: "列数", selection: $offlineGridColumns)
                }
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
        .overlay(alignment: .bottomTrailing) {
            Text(versionLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(8)
        }
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
    private func columnPicker(title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(1...4, id: \.self) { count in
                Text("\(count)列").tag(count)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 320)
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
