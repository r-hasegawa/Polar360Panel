import Foundation

struct StoredHrPoint: Identifiable {
    let id = UUID()
    let date: Date
    let bpm: Int
}

struct StoredSkinTempPoint: Identifiable {
    let id = UUID()
    let date: Date
    let celsius: Double
}

struct StoredAccPoint: Identifiable {
    let id = UUID()
    let date: Date
    let x: Int
    let y: Int
    let z: Int
}

enum CsvDataLoader {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 行数が多すぎる場合、表示負荷を抑えるために間引く上限
    private static let maxPoints = 3000

    static func loadHr(from url: URL) -> [StoredHrPoint] {
        let lines = readLines(url)
        var points: [StoredHrPoint] = []
        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2,
                  let date = isoFormatter.date(from: String(cols[0])),
                  let bpm = Int(cols[1]) else { continue }
            points.append(StoredHrPoint(date: date, bpm: bpm))
        }
        return downsampleMinMax(points.sorted { $0.date < $1.date }, date: { $0.date }, value: { Double($0.bpm) })
    }

    static func loadSkinTemp(from url: URL) -> [StoredSkinTempPoint] {
        let lines = readLines(url)
        var points: [StoredSkinTempPoint] = []
        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2,
                  let date = isoFormatter.date(from: String(cols[0])),
                  let celsius = Double(cols[1]) else { continue }
            points.append(StoredSkinTempPoint(date: date, celsius: celsius))
        }
        return downsampleMinMax(points.sorted { $0.date < $1.date }, date: { $0.date }, value: { $0.celsius })
    }

    static func loadAcc(from url: URL) -> [StoredAccPoint] {
        let lines = readLines(url)
        var points: [StoredAccPoint] = []
        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 4,
                  let date = isoFormatter.date(from: String(cols[0])),
                  let x = Int(cols[1]), let y = Int(cols[2]), let z = Int(cols[3]) else { continue }
            points.append(StoredAccPoint(date: date, x: x, y: y, z: z))
        }
        // 3軸の合成値(magnitude)を代表値としてMin-Maxを判定する(どれか1軸だけ見ると別の軸のピークを逃すため)
        return downsampleMinMax(points.sorted { $0.date < $1.date }, date: { $0.date }, value: {
            sqrt(Double($0.x * $0.x + $0.y * $0.y + $0.z * $0.z))
        })
    }

    /// イベントログはグラフ化せず、そのまま文字列の配列として返す(一覧表示用)
    static func loadEvents(from url: URL) -> [String] {
        Array(readLines(url).dropFirst())
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init)
    }

    /// 単純に間引くと、たまたま捨てた点にスパイク(急激な変化)が乗っていた場合に
    /// 見えなくなってしまう。各区間の最小値・最大値の両方を残すことで、
    /// ピークを見逃しにくくする(いわゆるMin-Maxダウンサンプリング)。
    private static func downsampleMinMax<T>(
        _ points: [T],
        date: (T) -> Date,
        value: (T) -> Double
    ) -> [T] {
        guard points.count > maxPoints else { return points }
        let bucketCount = max(1, maxPoints / 2) // 1区間につき最大2点(min+max)残す
        let bucketSize = max(1, points.count / bucketCount)

        var result: [T] = []
        var index = 0
        while index < points.count {
            let end = min(index + bucketSize, points.count)
            let bucket = points[index..<end]
            guard let minPoint = bucket.min(by: { value($0) < value($1) }),
                  let maxPoint = bucket.max(by: { value($0) < value($1) }) else {
                index = end
                continue
            }
            // 折れ線がジグザグに逆行しないよう、時刻順に並べてから追加する
            let pair = [minPoint, maxPoint].sorted { date($0) < date($1) }
            result.append(pair[0])
            if value(minPoint) != value(maxPoint) {
                result.append(pair[1])
            }
            index = end
        }
        return result
    }
}
