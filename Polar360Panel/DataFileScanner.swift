import Foundation

/// 1セッション(接続開始時刻)分のファイル群。
/// 例: hr_20260729_051432.csv / skintemp_20260729_051432.csv / acc_..._.csv / events_..._.csv
struct SessionFileGroup: Identifiable {
    let id = UUID()
    let sessionLabel: String     // 例: "20260729_051432"
    let sessionDate: Date?
    var files: [DataFileEntry]   // kind("hr"/"skintemp"/"acc"/"events") ごとのファイル

    var totalSizeBytes: Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }

    func file(kind: String) -> DataFileEntry? {
        files.first { $0.kind == kind }
    }
}

struct DataFileEntry: Identifiable, Equatable {
    let id = UUID()
    let kind: String   // "hr" / "skintemp" / "acc" / "events"
    let url: URL
    let sizeBytes: Int64

    var displayKind: String {
        switch kind {
        case "hr": return "HR"
        case "skintemp": return "体表温"
        case "acc": return "加速度"
        case "events": return "イベントログ"
        default: return kind
        }
    }
}

enum DataFileScanner {

    /// "Online" / "Offline" のうち、実際にフォルダが存在するものだけ返す
    static func availableModeFolders() -> [String] {
        ["Online", "Offline"].filter { modeFolder in
            var isDir: ObjCBool = false
            let url = CsvLogger.documentsDirectory.appendingPathComponent(modeFolder)
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// 指定モード直下の「デバイスフォルダ(名前_ID または ID)」一覧
    static func deviceFolders(modeFolder: String) -> [String] {
        let url = CsvLogger.documentsDirectory.appendingPathComponent(modeFolder)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// 指定デバイスフォルダ内のファイルを、セッション(ファイル名の日時部分)ごとにグループ化する
    static func sessionGroups(modeFolder: String, deviceFolder: String) -> [SessionFileGroup] {
        let dirURL = CsvLogger.documentsDirectory
            .appendingPathComponent(modeFolder)
            .appendingPathComponent(deviceFolder)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        var groups: [String: SessionFileGroup] = [:]

        for fileURL in contents where fileURL.pathExtension == "csv" {
            let name = fileURL.deletingPathExtension().lastPathComponent
            guard let underscoreIndex = name.firstIndex(of: "_") else { continue }
            let kind = String(name[..<underscoreIndex])
            let sessionLabel = String(name[name.index(after: underscoreIndex)...])
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            let entry = DataFileEntry(kind: kind, url: fileURL, sizeBytes: Int64(size))

            if var existing = groups[sessionLabel] {
                existing.files.append(entry)
                groups[sessionLabel] = existing
            } else {
                groups[sessionLabel] = SessionFileGroup(
                    sessionLabel: sessionLabel,
                    sessionDate: formatter.date(from: sessionLabel),
                    files: [entry]
                )
            }
        }

        return groups.values.sorted { ($0.sessionDate ?? .distantPast) > ($1.sessionDate ?? .distantPast) }
    }
}
