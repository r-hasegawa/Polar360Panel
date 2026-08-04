import SwiftUI
import UIKit

struct DataManagementView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                let modes = DataFileScanner.availableModeFolders()
                if modes.isEmpty {
                    Text("まだ保存されたデータがありません。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(modes, id: \.self) { modeFolder in
                        NavigationLink(modeFolder == "Online" ? "オンラインモードのデータ" : "オフラインモードのデータ") {
                            DeviceFolderListView(modeFolder: modeFolder)
                        }
                    }
                }
            }
            .navigationTitle("データ管理")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct DeviceFolderListView: View {
    let modeFolder: String
    @State private var deviceFolders: [String] = []
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            if deviceFolders.isEmpty {
                Text("データがありません。").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(deviceFolders, id: \.self) { folder in
                    NavigationLink(folder) {
                        SessionListView(modeFolder: modeFolder, deviceFolder: folder)
                    }
                }
                .onDelete { offsets in
                    pendingDeleteOffsets = offsets
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle(modeFolder == "Online" ? "オンライン" : "オフライン")
        .onAppear {
            deviceFolders = DataFileScanner.deviceFolders(modeFolder: modeFolder)
        }
        .alert("このセンサーのデータを削除しますか?", isPresented: $showDeleteConfirm) {
            Button("キャンセル", role: .cancel) { pendingDeleteOffsets = nil }
            Button("削除する", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    deleteFolders(at: offsets)
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("保存されているすべてのセッションのデータが削除されます。この操作は元に戻せません。")
        }
    }

    private func deleteFolders(at offsets: IndexSet) {
        for index in offsets {
            let url = CsvLogger.documentsDirectory
                .appendingPathComponent(modeFolder)
                .appendingPathComponent(deviceFolders[index])
            try? FileManager.default.removeItem(at: url)
        }
        deviceFolders = DataFileScanner.deviceFolders(modeFolder: modeFolder)
    }
}

private struct SessionListView: View {
    let modeFolder: String
    let deviceFolder: String
    @State private var sessions: [SessionFileGroup] = []
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var showDeleteConfirm = false

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("データがありません。").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(sessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session, onChanged: reload)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.sessionDate.map { Self.displayFormatter.string(from: $0) } ?? session.sessionLabel)
                                .font(.body)
                            Text("\(session.files.map { $0.displayKind }.joined(separator: "・")) / \(formattedBytes(session.totalSizeBytes))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    pendingDeleteOffsets = offsets
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle(deviceFolder)
        .onAppear(perform: reload)
        .alert("このセッションのデータを削除しますか?", isPresented: $showDeleteConfirm) {
            Button("キャンセル", role: .cancel) { pendingDeleteOffsets = nil }
            Button("削除する", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    deleteSessions(at: offsets)
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("このセッションに含まれるすべてのファイル(HR・体表温・加速度・イベントログ)が削除されます。この操作は元に戻せません。")
        }
    }

    private func reload() {
        sessions = DataFileScanner.sessionGroups(modeFolder: modeFolder, deviceFolder: deviceFolder)
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            for file in sessions[index].files {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
        reload()
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes > 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
    }
}

private struct SessionDetailView: View {
    let session: SessionFileGroup
    let onChanged: () -> Void
    @State private var files: [DataFileEntry]
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var showDeleteConfirm = false

    init(session: SessionFileGroup, onChanged: @escaping () -> Void) {
        self.session = session
        self.onChanged = onChanged
        _files = State(initialValue: session.files)
    }

    @State private var selectedGraphFile: DataFileEntry?
    @State private var shareZipURL: URL?
    @State private var isPreparingShare = false

    var body: some View {
        List {
            ForEach(files) { file in
                if file.kind == "events" {
                    // イベントログは短いテキスト一覧なので、これまで通り通常のプッシュ遷移でよい
                    NavigationLink {
                        StoredDataGraphView(file: file, rangeState: GraphRangeState())
                    } label: {
                        HStack {
                            Text(file.displayKind)
                            Spacer()
                            Text(formattedBytes(file.sizeBytes))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    // グラフ(HR・体表温・加速度)は、iPadの2カラム表示に押し込まれると
                    // 窮屈になるため、フルスクリーンで大きく表示する。
                    Button {
                        selectedGraphFile = file
                    } label: {
                        HStack {
                            Text(file.displayKind)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(formattedBytes(file.sizeBytes))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                pendingDeleteOffsets = offsets
                showDeleteConfirm = true
            }
        }
        .navigationTitle(session.sessionLabel)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isPreparingShare {
                    ProgressView()
                } else {
                    Button {
                        prepareAndShareSession()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { shareZipURL != nil },
            set: { if !$0 { shareZipURL = nil } }
        )) {
            if let url = shareZipURL {
                ShareSheet(activityItems: [url]) {
                    // 共有シートが閉じたら(送信完了・保存完了・キャンセルいずれでも)、
                    // 一時的に作ったzipファイルは役目を終えるので削除する。
                    try? FileManager.default.removeItem(at: url)
                    shareZipURL = nil
                }
            }
        }
        .fullScreenCover(item: $selectedGraphFile) { file in
            NavigationView {
                MultiSensorGraphView(session: session, initialFile: file) {
                    selectedGraphFile = nil
                }
            }
            .navigationViewStyle(.stack)
        }
        .alert("このファイルを削除しますか?", isPresented: $showDeleteConfirm) {
            Button("キャンセル", role: .cancel) { pendingDeleteOffsets = nil }
            Button("削除する", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    deleteFiles(at: offsets)
                }
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("この操作は元に戻せません。")
        }
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: files[index].url)
        }
        files.remove(atOffsets: offsets)
        onChanged()
    }

    /// セッションのファイル一式(HR・体表温・加速度・イベントログ)を
    /// 一時ディレクトリ上でひとまとめにし、zip化してから共有シートを開く。
    /// zip自体はDocuments配下ではなく一時ディレクトリに作るため、
    /// データ管理画面のファイルスキャン対象に混ざることはない。
    private func prepareAndShareSession() {
        isPreparingShare = true
        let sessionLabel = session.sessionLabel
        let filesToShare = files
        DispatchQueue.global(qos: .userInitiated).async {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("share_\(UUID().uuidString)", isDirectory: true)
            var resultZipURL: URL?
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                for file in filesToShare {
                    let dest = workDir.appendingPathComponent(file.url.lastPathComponent)
                    try? FileManager.default.copyItem(at: file.url, to: dest)
                }

                var coordError: NSError?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: workDir, options: .forUploading, error: &coordError) { zippedURL in
                    let finalURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(sessionLabel).zip")
                    try? FileManager.default.removeItem(at: finalURL)
                    do {
                        try FileManager.default.copyItem(at: zippedURL, to: finalURL)
                        resultZipURL = finalURL
                    } catch {
                        print("[Share] zipのコピーに失敗: \(error)")
                    }
                }
                if let coordError {
                    print("[Share] zip作成に失敗: \(coordError)")
                }
            } catch {
                print("[Share] 準備に失敗: \(error)")
            }
            // 素材コピー用の作業フォルダはzip化が済めばもう不要
            try? FileManager.default.removeItem(at: workDir)

            DispatchQueue.main.async {
                isPreparingShare = false
                shareZipURL = resultZipURL
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes > 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
    }
}

/// UIActivityViewController(共有シート)のSwiftUIラッパー。
/// onCompleteは送信完了・保存完了・キャンセル、いずれの場合でも呼ばれる。
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


/// フルスクリーン表示中、右上にセンサー種別の切り替えボタンを並べるラッパービュー。
/// GraphRangeStateを切り替え間で共有し続けることで、
/// 「今見ている表示範囲(ズーム・スクロール位置)を保ったまま」別のセンサーのグラフに
/// 切り替えて比較できるようにしている。
private struct MultiSensorGraphView: View {
    let session: SessionFileGroup
    let onClose: () -> Void

    @State private var currentFile: DataFileEntry
    @StateObject private var rangeState = GraphRangeState()

    /// グラフを持つセンサー種別のみ対象(イベントログはここでは扱わない)
    private static let graphKinds: [(kind: String, label: String)] = [
        ("hr", "HR"),
        ("skintemp", "体表温"),
        ("acc", "加速度")
    ]

    init(session: SessionFileGroup, initialFile: DataFileEntry, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _currentFile = State(initialValue: initialFile)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach(Self.graphKinds, id: \.kind) { item in
                        sensorSwitchButton(kind: item.kind, label: item.label)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 2)

            StoredDataGraphView(file: currentFile, rangeState: rangeState)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { onClose() }
            }
        }
    }

    @ViewBuilder
    private func sensorSwitchButton(kind: String, label: String) -> some View {
        if let file = session.file(kind: kind) {
            if kind == currentFile.kind {
                // 現在表示中: 押せない・強調表示
                Text(label)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            } else {
                // データはあるが非表示中: 押せる
                Button {
                    print("[Graph] button tapped kind=\(kind) label=\(label) -> file=\(file.url.lastPathComponent) (file.kind=\(file.kind))")
                    currentFile = file
                } label: {
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
        } else {
            // このセッションにはデータが無い: 押せない・グレーアウト
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .foregroundColor(.secondary)
                .clipShape(Capsule())
        }
    }
}
