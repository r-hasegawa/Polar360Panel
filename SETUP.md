# Polar360Panel セットアップ手順

## 1. Xcodeプロジェクト作成
- Xcode → File > New > Project
- テンプレート: App
- Interface: SwiftUI / Language: Swift
- Team: 無料のPersonal Apple ID(Signing & Capabilitiesで後から設定でも可)

## 2. Polar BLE SDK の導入 (Swift Package Manager)
- File > Add Package Dependencies
- URL: `https://github.com/polarofficial/polar-ble-sdk.git`
- ルール: Up to Next Major (例: 6.0.0 以上)
- 追加するProduct: `PolarBleSdk`

## 3. このフォルダのファイルをプロジェクトに追加
デフォルトで生成される `ContentView.swift` と `xxxApp.swift` は
このフォルダの同名ファイルで上書きしてください。

**旧`SensorPanelView.swift`はもう使いません。Xcodeプロジェクトから削除してください**
(オンライン/オフラインそれぞれ専用のパネルに分割したため)。

- Polar360PanelApp.swift
- ContentView.swift(モード選択済みかどうかで画面を振り分けるルーター)
- ModeSelectionView.swift(起動時のモード選択画面)
- UsageGuideView.swift(アプリの使い方・制約の解説画面)
- SensorNicknameStore.swift(センサーID⇔名前の永続化ストア)
- SensorManagementView.swift(センサー管理画面)
- DataFileScanner.swift(保存済みファイルのスキャン・モデル)
- CsvDataLoader.swift(CSV読み込み・グラフ用データへの変換)
- StoredDataGraphView.swift(保存済みデータのグラフ表示画面)
- DataManagementView.swift(データ管理画面: 一覧・削除・グラフ表示への導線)
- OnlineDashboardView.swift / OnlineSensorPanelView.swift(オンラインモード、グラフ中心)
- OfflineDashboardView.swift / OfflineSensorPanelView.swift(オフラインモード、記録状況・メモリ残量中心)
- SensorSlotViewModel.swift
- PolarManager.swift
- CsvLogger.swift

## 4. Info.plist に追加

| Key | Value |
|---|---|
| Privacy - Bluetooth Always Usage Description (`NSBluetoothAlwaysUsageDescription`) | 例:「センサとの接続にBluetoothを使用します」 |

## 5. iPad専用アプリにする(重要・iPhoneでは不要だが抜けがちな設定)
- プロジェクト設定 > TARGETS > 対象アプリ > General > Supported Destinations
  - iPhone のチェックを外し、**iPad のみ**にする
- Info.plist に `UIRequiresFullScreen` を追加し `YES` にする
  - これが無いと iPadOS の Split View / Slide Over / Stage Manager で
    アプリがリサイズ・分割され、下記の横画面固定自体が効かなくなることがある

## 6. 画面回転を横固定にする
- プロジェクト設定 > TARGETS > 対象アプリ > General > Deployment Info
- "Supported Interface Orientations" (iPad) で
  Portrait / Portrait Upside Down のチェックを外し、Landscape Left/Right のみ残す
- 上記5の `UIRequiresFullScreen` とセットでないと確実に効かない点に注意

## 7. ローカルデータ保存
取得したHR/体表温/加速度/イベントログの保存先は、以下のディレクトリ構成にしています。

```
Documents/
  Online/
    <デバイスID>/
      hr_<セッション開始時刻>.csv
      skintemp_<セッション開始時刻>.csv
      acc_<セッション開始時刻>.csv
      events_<セッション開始時刻>.csv
  Offline/
    <デバイスID>/
      (同様のファイル構成)
```

「セッション開始時刻」は接続(または計測開始)した瞬間の時刻で固定され、
そのセッション中(オフラインモードなら20秒ごとの同期を何度繰り返しても)は
ずっと同じファイルに追記され続けます。新しいファイルになるのは
「再接続した時」「新しい計測を開始した時」だけです。

- 保存先: `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)`
- MacやPCへの取り出しをiPadの「ファイル」アプリ経由で行いたい場合、
  Info.plistに以下を追加:
  - `UIFileSharingEnabled: YES`
  - `LSSupportsOpeningDocumentsInPlace: YES`

## 8. バックグラウンドでもストリーミングを継続したい場合
- Signing & Capabilities > + Capability > Background Modes
- "Uses Bluetooth LE accessories" にチェック

## 9. 動作確認の順番(推奨)
1. まずFTU + HRストリーミングだけで1台接続できるか確認
   (`SensorSlotViewModel.swift` の `startSkinTemperatureStreaming` /
   `startAccStreaming` / `startOfflineRecordingIfNeeded` の呼び出しを
   一旦コメントアウトして最小構成でテストすると切り分けやすいです)
2. 問題なければ体表温ストリーミングを有効化
3. 加速度、オフライン記録の順に有効化

## 10. 要検証・要確認ポイント(コード内にもコメントあり)
SDKは更新が比較的頻繁なライブラリのため、以下はビルド時に
Xcodeの自動補完・エラーメッセージ・公式サンプル
(`examples/example-ios` フォルダ)で必ず突き合わせてください。

- `PolarFirstTimeUseConfig` の正確なプロパティ名・必須項目
  (`FirstTimeUse.md` 参照)
- オフライン記録関連 (`startOfflineRecording` /
  `getOfflineRecordingStatus` / 実際のfetch・delete) の正確なメソッド名
  (`SdkOfflineRecordingExplained.md` 参照)
- `PolarBleApiObserver` 等プロトコルの必須メソッドの完全な一覧
  (SDKバージョンによって増減あり。Xcodeが「準拠していません」と
  指摘してくれるメソッドを追加していけばOK)

体表温については `.temperature`/`startTemperatureStreaming` ではなく
`.skinTemperature`/`startSkinTemperatureStreaming` を使うこと
(firmware 2.0.8以降、旧APIは ERROR_NOT_SUPPORTED になる実例が
SDK issue #656 で報告されています)。

## 11. 既知の制約: アプリ強制終了時のACCデータ消失リスク
加速度用CSVはFileHandleを開きっぱなしで書き込む設計のため、
「切断」ボタンを押さずにアプリを強制終了(スワイプで完全終了)した場合、
直前の書き込みがディスクに反映されていない可能性があります。
現状は50件(約1秒分)ごとに`synchronize()`でディスク同期する形で
消失範囲を最大1秒程度に抑えていますが、完全にゼロにはできていません。
確実性を高めたい場合は、Appのシーンフェーズ(`.background`遷移時)を
フックして明示的にファイルを閉じる処理を追加することを検討してください。
