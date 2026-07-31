import Foundation

/// センサ1台・1接続セッション分のCSV書き出しを担当。
///
/// 保存先ディレクトリ構成:
///   Documents/Online または Offline/<デバイスID>/
///     hr_<セッション開始時刻>.csv
///     skintemp_<セッション開始時刻>.csv
///     acc_<セッション開始時刻>.csv
///     events_<セッション開始時刻>.csv
///
/// ファイル名は「日付」ではなく「このセッション(接続してから切断/計測終了するまで)が
/// 開始した時刻」で固定される。これにより、オフラインモードで20秒ごとに
/// 同期を繰り返しても、同じセッション内は常に同じファイルに追記され続ける
/// (＝日をまたいでも迷わない。新しいファイルになるのは「再接続した時」だけ)。
final class CsvLogger {

    private let deviceId: String
    private let modeFolder: String
    private let sessionLabel: String
    private let queue = DispatchQueue(label: "csvlogger.\(UUID().uuidString)")

    // 加速度は50Hz×3軸と高頻度なので、HR/体表温のような
    // 「毎回ファイルを開いて書いて閉じる」方式だと負荷が大きい。
    // ACCだけはFileHandleを開きっぱなしにして使い回す。
    private var accFileHandle: FileHandle?
    private var accWriteCountSinceSync = 0

    init(deviceId: String, mode: SensorMode, sessionStart: Date = Date()) {
        // ファイル名に使えない文字(コロン等)が来た場合の簡易サニタイズ
        self.deviceId = deviceId.replacingOccurrences(of: "/", with: "_")
        self.modeFolder = mode == .online ? "Online" : "Offline"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        self.sessionLabel = formatter.string(from: sessionStart)

        try? FileManager.default.createDirectory(
            at: Self.sessionDirectory(modeFolder: modeFolder, deviceId: self.deviceId),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public

    func logHr(_ bpm: Int, at date: Date = Date()) {
        appendLine(
            "\(isoString(date)),\(bpm)",
            kind: "hr",
            header: "timestamp,hr_bpm"
        )
    }

    func logSkinTemperature(_ celsius: Double, at date: Date = Date()) {
        appendLine(
            "\(isoString(date)),\(String(format: "%.3f", celsius))",
            kind: "skintemp",
            header: "timestamp,skin_temperature_c"
        )
    }

    /// 接続/切断/FTU完了/時刻同期などのイベントを記録する。
    /// 後でデータ欠測の理由を追跡する材料になる。
    func logEvent(_ event: String, at date: Date = Date()) {
        appendLine(
            "\(isoString(date)),\(event)",
            kind: "events",
            header: "timestamp,event"
        )
    }

    /// 加速度は高頻度なので専用のFileHandleを使い回して書き込む。
    /// `at` には各サンプルのタイムスタンプを渡すこと。
    func logAcc(x: Int, y: Int, z: Int, at date: Date = Date()) {
        queue.async {
            self.ensureAccFileHandle()
            let line = "\(self.isoString(date)),\(x),\(y),\(z)\n"
            if let data = line.data(using: .utf8) {
                self.accFileHandle?.write(data)
            }
            // FileHandleは開きっぱなしなので、close()されるまでOSバッファに
            // 留まる可能性がある。アプリが強制終了された場合のデータ消失を
            // ある程度の範囲(最大約1秒分)に抑えるため、定期的にディスクへ同期する。
            self.accWriteCountSinceSync += 1
            if self.accWriteCountSinceSync >= 50 {
                try? self.accFileHandle?.synchronize()
                self.accWriteCountSinceSync = 0
            }
        }
    }

    /// 加速度をまとめて書き込む版。オフライン記録の一括取得のように大量サンプルを
    /// 一度に処理する場合、1サンプルごとにqueue.asyncを積むと(数十万件規模で)
    /// 著しく遅くなるため、まとめて1回のクロージャで処理する。
    /// async化しているのは、呼び出し側(メモリ消去の直前)で「実際にディスクへの
    /// 書き込みが完了してから次に進みたい」ため。fire-and-forgetにすると、
    /// 書き込みキューが残っている間にセンサー側のデータを消してしまう
    /// (僅かとはいえロスの可能性がある)ケースを避ける。
    func logAccBatch(_ samples: [(x: Int, y: Int, z: Int, date: Date)]) async {
        guard !samples.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                self.ensureAccFileHandle()
                var buffer = ""
                buffer.reserveCapacity(samples.count * 40)
                for sample in samples {
                    buffer += "\(self.isoString(sample.date)),\(sample.x),\(sample.y),\(sample.z)\n"
                }
                if let data = buffer.data(using: .utf8) {
                    self.accFileHandle?.write(data)
                }
                try? self.accFileHandle?.synchronize()
                continuation.resume()
            }
        }
    }

    /// HR・体表温など、行の配列をまとめて1回のファイル書き込みで追記する。
    /// appendLineを大量件数分繰り返すと、1件ごとにファイルを開閉するオーバーヘッドが
    /// 積み重なって遅くなるため、複数行をまとめて渡せるようにしたもの。
    /// logAccBatchと同様の理由でasync化し、書き込み完了を待てるようにしている。
    func appendBatch(_ lines: [String], kind: String, header: String) async {
        guard !lines.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                let url = self.fileURL(kind: kind)
                let joined = lines.joined(separator: "\n") + "\n"
                if FileManager.default.fileExists(atPath: url.path) {
                    guard let handle = try? FileHandle(forWritingTo: url) else {
                        continuation.resume()
                        return
                    }
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    if let data = joined.data(using: .utf8) {
                        handle.write(data)
                    }
                } else {
                    let content = header + "\n" + joined
                    try? content.write(to: url, atomically: true, encoding: .utf8)
                }
                continuation.resume()
            }
        }
    }

    /// 切断時に必ず呼び、開きっぱなしのFileHandleを閉じること。
    func closeAccFile() {
        queue.async {
            try? self.accFileHandle?.close()
            self.accFileHandle = nil
        }
    }

    /// 保存先ディレクトリをFinder/ファイルアプリ等で確認したい時用
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func sessionDirectory(modeFolder: String, deviceId: String) -> URL {
        let nickname = SensorNicknameStore.shared.nicknames[deviceId]
        let folderName = SensorNicknameStore.folderName(deviceId: deviceId, nickname: nickname)
        return documentsDirectory.appendingPathComponent(modeFolder).appendingPathComponent(folderName)
    }

    // MARK: - Private

    private var sessionDirectory: URL {
        Self.sessionDirectory(modeFolder: modeFolder, deviceId: deviceId)
    }

    private func fileURL(kind: String) -> URL {
        sessionDirectory.appendingPathComponent("\(kind)_\(sessionLabel).csv")
    }

    private func isoString(_ date: Date) -> String {
        Self.isoString(date)
    }

    /// 他のクラス(SensorSlotViewModelなど)からも、CSV内のタイムスタンプと
    /// 同じ書式の文字列を作れるようにするための共有ヘルパー。
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func appendLine(_ line: String, kind: String, header: String) {
        queue.async {
            let url = self.fileURL(kind: kind)
            if FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = (line + "\n").data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                let content = header + "\n" + line + "\n"
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// queue上で呼ぶこと。ファイル名はセッション中固定なので、初回だけ開けばよい。
    private func ensureAccFileHandle() {
        if accFileHandle != nil { return }

        let url = fileURL(kind: "acc")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "timestamp,acc_x,acc_y,acc_z\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        accFileHandle = try? FileHandle(forWritingTo: url)
        accFileHandle?.seekToEndOfFile()
    }
}
