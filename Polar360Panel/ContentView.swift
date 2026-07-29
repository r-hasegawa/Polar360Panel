import SwiftUI

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
    }

    private func resetMode() {
        appModeRaw = ""
    }
}
