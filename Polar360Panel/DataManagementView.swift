import SwiftUI

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
                .onDelete(perform: deleteFolders)
            }
        }
        .navigationTitle(modeFolder == "Online" ? "オンライン" : "オフライン")
        .onAppear {
            deviceFolders = DataFileScanner.deviceFolders(modeFolder: modeFolder)
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
                .onDelete(perform: deleteSessions)
            }
        }
        .navigationTitle(deviceFolder)
        .onAppear(perform: reload)
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

    init(session: SessionFileGroup, onChanged: @escaping () -> Void) {
        self.session = session
        self.onChanged = onChanged
        _files = State(initialValue: session.files)
    }

    var body: some View {
        List {
            ForEach(files) { file in
                NavigationLink {
                    StoredDataGraphView(file: file)
                } label: {
                    HStack {
                        Text(file.displayKind)
                        Spacer()
                        Text(formattedBytes(file.sizeBytes))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onDelete(perform: deleteFiles)
        }
        .navigationTitle(session.sessionLabel)
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: files[index].url)
        }
        files.remove(atOffsets: offsets)
        onChanged()
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes > 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
    }
}
