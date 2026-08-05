import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("appMode") private var appModeRaw: String = ""

    var body: some View {
        Group {
            if let mode = SensorMode(rawValue: appModeRaw) {
                switch mode {
                case .online:
                    OnlineDashboardView(onChangeMode: resetMode)
                case .offline:
                    OfflineDashboardView(onChangeMode: resetMode)
                }
            } else {
                ModeSelectionView { selected in
                    appModeRaw = selected.rawValue
                }
            }
        }
        .onAppear {
            // 計測中にiPadの自動ロックで画面が消えないようにする。
            // アプリ全体を通して常時ONでよい(計測画面以外でも複数センサーの状態を
            // 目視確認する運用のため)。
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func resetMode() {
        appModeRaw = ""
    }
}
