# Polar360Panel

Polar 360センサー(最大4台同時)からHR(心拍数)・体表温・加速度を取得し、
CSVとして端末内に保存するiPad用アプリです。

## 概要

- 計測開始前に **オンラインモード** / **オフラインモード** のどちらかを選択
- 4分割のダッシュボードで、複数センサーを同時に管理
- センサーに名前を付けて管理(センサー管理画面)
- 保存済みデータの一覧・削除・グラフ表示(データ管理画面)

## なぜモードを分けているか

Polar 360は、体表温・加速度について「オンラインストリーミング」と「オフライン記録
(センサー内蔵メモリへの記録)」を**同時には使えない**仕様になっています。
このため、計測開始前にどちらを使うか選ぶ設計にしています。

- **オンラインモード**: 接続中のみリアルタイムにグラフ表示。切断中は記録されない
- **オフラインモード**: 切断中もセンサー内蔵メモリに記録し続ける。取得(取り出し)は「計測終了」時のみ

HRだけは標準のBLE Heart Rate Serviceを使うため、モードに関わらず常時両方(表示+記録)が有効です。

詳しい設計判断の背景は、アプリ内の「このアプリの使い方」画面(`UsageGuideView.swift`)にまとめてあります。

## セットアップ

Xcodeへの組み込み手順は [SETUP.md](./SETUP.md) を参照してください。

- Polar BLE SDK (公式リポジトリのフォーク/パッチ版) が必要です
- iPad専用、iOS 17以降が必要(グラフのズーム・スクロール機能で使用)

## 主要なファイル構成

| ファイル | 役割 |
|---|---|
| `Polar360PanelApp.swift` | アプリのエントリポイント |
| `ContentView.swift` | モード選択画面 or 各ダッシュボードへのルーター |
| `ModeSelectionView.swift` | 起動時のモード選択画面 |
| `OnlineDashboardView.swift` / `OnlineSensorPanelView.swift` | オンラインモードのダッシュボード・パネル |
| `OfflineDashboardView.swift` / `OfflineSensorPanelView.swift` | オフラインモードのダッシュボード・パネル |
| `SensorSlotViewModel.swift` | センサー1台分の状態管理(接続・FTU・計測・記録) |
| `PolarManager.swift` | PolarBleApiの共有・コールバックの振り分け |
| `CsvLogger.swift` | CSV書き出し(センサーID・セッション単位でファイル分割) |
| `SensorNicknameStore.swift` / `SensorManagementView.swift` | センサーの名前管理 |
| `DataFileScanner.swift` / `CsvDataLoader.swift` / `DataManagementView.swift` / `StoredDataGraphView.swift` | 保存済みデータの閲覧・削除・グラフ表示 |
| `UsageGuideView.swift` | アプリの使い方・制約の解説画面 |

## データ保存先

```
Documents/
  Online または Offline/
    <名前_ID または ID>/
      hr_<セッション開始時刻>.csv
      skintemp_<セッション開始時刻>.csv
      acc_<セッション開始時刻>.csv
      events_<セッション開始時刻>.csv
```

## 既知の制約・不具合

- Polar 360のオフライン加速度記録は、高いレート(25Hz以上)だと取得時にエラーになる不具合報告あり(SDK Issue #716, #652)。デフォルトは10Hz
- 充電すると記録が終了する(実測確認済み)。計測中は絶対に充電しないこと
- 1台のセンサーは同時に1つのペアリング相手としか組めない。別のiPad等で使うには工場出荷リセットが必要
- iPad 1台に同時接続できるセンサー数は、iPadOS内蔵Bluetoothの制約でおおむね6〜10台が目安

詳細な検証項目・今後の実装方針は [ROADMAP.md](./ROADMAP.md) を参照してください。
