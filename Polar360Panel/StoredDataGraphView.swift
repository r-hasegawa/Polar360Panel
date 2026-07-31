import SwiftUI
import Charts

/// ズーム(表示範囲の長さ)・スクロール位置(開始時刻)・範囲固定トグルの状態。
/// 複数のStoredDataGraphViewインスタンス間(センサー種別の切り替え時)で
/// このオブジェクトを共有すると、「同じ表示範囲のまま別のグラフに切り替えて比較する」
/// ことができる。単独で使う場合(イベントログ等)は、呼び出し側で毎回新しく作ればよい。
final class GraphRangeState: ObservableObject {
    @Published var visibleDomainLength: TimeInterval = 300
    @Published var baseDomainLength: TimeInterval = 300
    @Published var scrollPositionStart: Date = Date()
    @Published var rangeLocked: Bool = false
    /// 一度でも実データに基づいて初期化されたかどうか。
    /// falseの間は、ロードされたファイルの実際のデータ範囲で表示範囲を初期化する。
    /// true以降は、別のファイルに切り替わっても表示範囲を上書きしない
    /// (＝ユーザーが選んだ表示範囲を保ったまま比較できるようにする)。
    var initialized: Bool = false
}

struct StoredDataGraphView: View {
    let file: DataFileEntry
    @ObservedObject var rangeState: GraphRangeState

    @State private var hrPoints: [StoredHrPoint] = []
    @State private var tempPoints: [StoredSkinTempPoint] = []
    @State private var accPoints: [StoredAccPoint] = []
    @State private var eventLines: [String] = []
    @State private var isLoading = true

    // ズーム・スクロール位置以外の、このファイル固有のデータ範囲(DatePickerの上下限や「全体表示」の基準に使う)
    @State private var fullDomainLength: TimeInterval = 300
    @State private var dataStartDate: Date = Date()
    @State private var dataEndDate: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading {
                    ProgressView("読み込み中...")
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    if file.kind != "events" {
                        rangeControls
                    }

                    switch file.kind {
                    case "hr":
                        Text("HR (\(hrPoints.count)点)").font(.headline)
                        Chart(hrPoints) { point in
                            LineMark(x: .value("時刻", point.date), y: .value("HR", point.bpm))
                                .foregroundStyle(.red)
                        }
                        .zoomable(
                            visibleDomainLength: $rangeState.visibleDomainLength,
                            baseDomainLength: $rangeState.baseDomainLength,
                            scrollPositionStart: $rangeState.scrollPositionStart,
                            rangeLocked: $rangeState.rangeLocked
                        )
                        .frame(height: 260)

                    case "skintemp":
                        Text("体表温 (\(tempPoints.count)点)").font(.headline)
                        Chart(tempPoints) { point in
                            LineMark(x: .value("時刻", point.date), y: .value("体表温", point.celsius))
                                .foregroundStyle(.orange)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .zoomable(
                            visibleDomainLength: $rangeState.visibleDomainLength,
                            baseDomainLength: $rangeState.baseDomainLength,
                            scrollPositionStart: $rangeState.scrollPositionStart,
                            rangeLocked: $rangeState.rangeLocked
                        )
                        .frame(height: 260)

                    case "acc":
                        Text("加速度 X/Y/Z (\(accPoints.count)点)").font(.headline)
                        Chart(accPoints) { point in
                            LineMark(x: .value("時刻", point.date), y: .value("値", point.x))
                                .foregroundStyle(by: .value("軸", "X"))
                            LineMark(x: .value("時刻", point.date), y: .value("値", point.y))
                                .foregroundStyle(by: .value("軸", "Y"))
                            LineMark(x: .value("時刻", point.date), y: .value("値", point.z))
                                .foregroundStyle(by: .value("軸", "Z"))
                        }
                        .zoomable(
                            visibleDomainLength: $rangeState.visibleDomainLength,
                            baseDomainLength: $rangeState.baseDomainLength,
                            scrollPositionStart: $rangeState.scrollPositionStart,
                            rangeLocked: $rangeState.rangeLocked
                        )
                        .frame(height: 260)

                    case "events":
                        Text("イベントログ (\(eventLines.count)件)").font(.headline)
                        ForEach(eventLines, id: \.self) { line in
                            Text(line).font(.caption).font(.system(.caption, design: .monospaced))
                        }

                    default:
                        Text("未対応のファイル種別です")
                    }

                    if file.kind != "events" {
                        Text("ピンチで拡大縮小、ドラッグで左右にスクロールできます(範囲固定中を除く)。行数が多い場合は各区間の最小値・最大値を残す方式で間引いています(最大3000点)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(file.displayKind)
        .onAppear(perform: load)
        .onChange(of: file.id) { _ in
            // センサー種別のボタンでfileが切り替わった時、onAppearは再発火しないため
            // ここで明示的に再読込する。
            isLoading = true
            load()
        }
    }

    @ViewBuilder
    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("表示範囲を固定する", isOn: $rangeState.rangeLocked)
                .font(.caption)

            HStack {
                VStack(alignment: .leading) {
                    Text("開始").font(.caption2).foregroundColor(.secondary)
                    DatePicker(
                        "",
                        selection: $rangeState.scrollPositionStart,
                        in: dataStartDate...dataEndDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                }
                VStack(alignment: .leading) {
                    Text("終了").font(.caption2).foregroundColor(.secondary)
                    DatePicker(
                        "",
                        selection: endDateBinding,
                        in: dataStartDate...dataEndDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                }
                Spacer()
                Button("全体表示") {
                    rangeState.scrollPositionStart = dataStartDate
                    rangeState.visibleDomainLength = fullDomainLength
                    rangeState.baseDomainLength = fullDomainLength
                }
                .font(.caption)
            }
            Text("※ 時刻の分単位までの指定になります。秒単位の微調整はピンチ・ドラッグを使ってください")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// DatePicker(終了)用。開始時刻+表示範囲の長さから逆算し、
    /// 変更されたらvisibleDomainLengthに反映する。
    private var endDateBinding: Binding<Date> {
        Binding(
            get: { rangeState.scrollPositionStart.addingTimeInterval(rangeState.visibleDomainLength) },
            set: { newEnd in
                let newLength = newEnd.timeIntervalSince(rangeState.scrollPositionStart)
                guard newLength > 5 else { return }
                rangeState.visibleDomainLength = newLength
                rangeState.baseDomainLength = newLength
            }
        )
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            switch file.kind {
            case "hr":
                let points = CsvDataLoader.loadHr(from: file.url)
                DispatchQueue.main.async {
                    hrPoints = points
                    setInitialDomain(first: points.first?.date, last: points.last?.date)
                    isLoading = false
                }
            case "skintemp":
                let points = CsvDataLoader.loadSkinTemp(from: file.url)
                DispatchQueue.main.async {
                    tempPoints = points
                    setInitialDomain(first: points.first?.date, last: points.last?.date)
                    isLoading = false
                }
            case "acc":
                let points = CsvDataLoader.loadAcc(from: file.url)
                DispatchQueue.main.async {
                    accPoints = points
                    setInitialDomain(first: points.first?.date, last: points.last?.date)
                    isLoading = false
                }
            case "events":
                let lines = CsvDataLoader.loadEvents(from: file.url)
                DispatchQueue.main.async { eventLines = lines; isLoading = false }
            default:
                DispatchQueue.main.async { isLoading = false }
            }
        }
    }

    /// ファイル固有のデータ範囲(DatePickerの上下限・「全体表示」の基準)は常に更新する。
    /// 表示範囲そのもの(rangeState)は、まだ一度も初期化されていない場合のみ設定する。
    /// これにより、センサー種別を切り替えても「今見ている範囲のまま」比較できる。
    private func setInitialDomain(first: Date?, last: Date?) {
        let start = first ?? Date()
        let end = last ?? start.addingTimeInterval(300)
        let span = max(end.timeIntervalSince(start), 10)
        dataStartDate = start
        dataEndDate = end
        fullDomainLength = span
        guard !rangeState.initialized else { return }
        rangeState.visibleDomainLength = span
        rangeState.baseDomainLength = span
        rangeState.scrollPositionStart = start
        rangeState.initialized = true
    }
}

/// ピンチズーム(拡大縮小)+ 横スクロール(ドラッグ移動)を1つのChartに付与するための共通修飾子。
/// rangeLockedがtrueの間は、ピンチ・ドラッグどちらの変更も無効化する。
private struct ZoomableChart: ViewModifier {
    @Binding var visibleDomainLength: TimeInterval
    @Binding var baseDomainLength: TimeInterval
    @Binding var scrollPositionStart: Date
    @Binding var rangeLocked: Bool

    func body(content: Content) -> some View {
        content
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: visibleDomainLength)
            .chartScrollPosition(x: $scrollPositionStart)
            // スクロール軸自体は常に有効のままにし(無効にすると表示位置が
            // リセットされてしまうため)、固定中はタッチ操作だけを受け付けないようにする。
            .allowsHitTesting(!rangeLocked)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        guard !rangeLocked else { return }
                        let newLength = baseDomainLength / scale
                        // 短すぎる/長すぎる拡大縮小を防ぐガード
                        visibleDomainLength = min(max(newLength, 5), baseDomainLength * 20)
                    }
                    .onEnded { _ in
                        guard !rangeLocked else { return }
                        baseDomainLength = visibleDomainLength
                    }
            )
    }
}

private extension View {
    func zoomable(
        visibleDomainLength: Binding<TimeInterval>,
        baseDomainLength: Binding<TimeInterval>,
        scrollPositionStart: Binding<Date>,
        rangeLocked: Binding<Bool>
    ) -> some View {
        modifier(ZoomableChart(
            visibleDomainLength: visibleDomainLength,
            baseDomainLength: baseDomainLength,
            scrollPositionStart: scrollPositionStart,
            rangeLocked: rangeLocked
        ))
    }
}
