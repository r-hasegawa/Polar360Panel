# SideStore向け IPA作成 & 配布ガイド

本ドキュメントは、Xcodeで開発したiOSアプリ（Polar360Panel）を **無料のApple ID (Personal Team)** 環境でプロビジョニングエラーを回避しつつ `.ipa` 化し、GitHub Releases および `apps.json` を通して SideStore へ配信・更新するための一連の手順書です。

---

## 📋 全体の流れ
1. **Xcodeでアーカイブ（Archive）を作成**
2. **手動（Payload方式）で `.ipa` ファイルを生成**
3. **GitHub Releases に `.ipa` をアップロード**
4. **`apps.json` の情報を更新して GitHub に Push**
5. **SideStore アプリで更新を確認・インストール**

---

## 🛠️ Step 1: Xcodeでアーカイブを作成する

1. Xcodeの画面上部のビルドターゲットを **`Any iOS Device (arm64)`** に設定します。
2. メニューバーから **`Product` > `Archive`** を実行します。
3. ビルド完了後、**Organizer** ウィンドウが自動的に開きます。
   - もし開かない場合は、メニューバーから `Window` > `Organizer` を開いてください。

---

## 📦 Step 2: 手動 (Payload方式) で .ipa を作成する

無料アカウント（Personal Team）で Xcode 標準の `Distribute App` を実行するとプロビジョニングプロファイルや署名に関するエラー（`Distribution requires enrollment...` や `requires a provisioning profile`）が発生するため、**手動で Payload 化**します。

1. Organizer 内で作成された最新のアーカイブを**右クリック**し、**`Show in Finder`** を選択します。
2. Finder で表示された `.xcarchive` ファイルを**右クリック ＞ `パッケージの内容を表示`** を選択します。
3. パッケージ内の **`Products` > `Applications`** フォルダへ移動します。
4. 中にある **`Polar360Panel.app`** ファイルを確認します。

### IPA圧縮手順:
1. デスクトップ等の作業フォルダに、半角大文字小文字を厳密に区別して **`Payload`** という名前のフォルダを新規作成します。
   - ⚠️ フォルダ名は必ず **`Payload`**（先頭大文字、残り小文字）にしてください。
2. `Polar360Panel.app` を先ほど作成した `Payload` フォルダの中にコピーします。
3. `Payload` フォルダ自体を右クリックし、**`"Payload" を圧縮`**（Zip圧縮）を選択します。
4. 生成された **`Payload.zip`** の名前を **`Polar360Panel.ipa`** に変更します。
   - 拡張子変更の確認ダイアログが出た場合は「`.ipa` を使用」を選択します。

⚠️ **Kekaなど他の圧縮ツールを使うと、`Payload`フォルダの1つ上の階層ごと圧縮してしまい、構造がズレることがあります。** 必ず**Finder標準の「"Payload"を圧縮」**を使うのが一番確実です(ターミナルで`zip -r -y ファイル名.ipa Payload`を使う方法でも可)。

---

## 🚀 Step 3: GitHub Releases に .ipa をアップロードする

1. GitHub の Polar360Panel リポジトリページを開きます。
2. 画面右側の **`Releases`** ＞ **`Draft a new release`**（または `Create a new release`）をクリックします。
3. 設定項目を入力します：
   - **Choose a tag**: `v1.0.0` などのバージョンタグ（新規作成の場合は入力して `Create new tag` を選択）
   - **Target**: `main` (または書き出したブランチ)
   - **Release title**: `v1.0.0 リリース` など
4. 下部の **`Attach binaries by dropping them here or selecting them.`** エリアに、Step 2 で作成した **`Polar360Panel.ipa`** をドラッグ＆ドロップします。
5. **`Publish release`** を押して公開します。
6. 公開後、`Assets` に表示された `Polar360Panel.ipa` の上で**右クリック ＞ `リンクのアドレスをコピー`** し、ダウンロード用の直リンクURLを取得しておきます。

---

## 📝 Step 4: `apps.json` を更新して GitHub に Push する

1. Xcode またはテキストエディタでプロジェクト直下の **`apps.json`** を開きます。
2. 以下の項目を最新情報に書き換えます：
   - **`version`**: **Xcodeの`Version`(Identity欄)と完全に同じ表記にする**(例: Xcode側が`1.0`なら`"1.0"`。`1.0.0`と書くと不一致でインストールできない)
   - **`versionDate`**: リリース日（ISO 8601形式: `"2026-07-30T00:00:00Z"` など）
   - **`downloadURL`**: Step 3 でコピーした `.ipa` の直リンクURL
   - **`size`**: ⚠️ **これを忘れると更新できません。** 新しく作った`.ipa`ファイルを、Finderで右クリック→「情報を見る」→「サイズ」欄に出るバイト数(カンマなしの数字)をそのまま入れる。**`.ipa`を作り直すたびに、必ずこの数値も一緒に更新すること**(ファイルサイズが変わっているのに古い数値のままにすると、SideStore側で「the file doesnt exist」というエラーになる)

```json
{
  "name": "Polar360Panel App Source",
  "identifier": "com.r-hasegawa.source",
  "apps": [
    {
      "name": "Polar360Panel",
      "bundleIdentifier": "com.r-hasegawa.Polar360Panel",
      "developerName": "r-hasegawa",
      "subtitle": "Polar360Panel App",
      "version": "1.0",
      "versionDate": "2026-07-30T00:00:00Z",
      "downloadURL": "https://github.com/r-hasegawa/Polar360Panel/releases/download/v1.0/Polar360Panel_v1_0.ipa",
      "localizedDescription": "Polar360Panel アプリケーション",
      "iconURL": "https://raw.githubusercontent.com/r-hasegawa/Polar360Panel/main/AppIcon.png",
      "size": 3193213
    }
  ]
}
```

3. 変更した `apps.json` を保存し、GitHub へ **Commit & Push** します。

---

## 📲 Step 5: SideStore での更新確認

1. iPad / iPhone で **SideStore** を起動します。
2. **`Sources`** タブに `apps.json` の Raw URL が追加されていることを確認します。
   - ※ 初回のみ: GitHubで `apps.json` を開いて `Raw` ボタンを押した時のURLを SideStore の `Sources` > `＋` から追加してください。
3. **`My Apps`** タブ（または `Sources` 内のアプリ詳細画面）で更新・インストールボタンをタップします。

---

## 💡 補足・トラブルシューティング

- **SideStoreでアプリが認識されない場合**
  - `apps.json` 内の `bundleIdentifier` が Xcode のプロジェクト設定（General > Bundle Identifier）と**完全に一致しているか**確認してください。
- **Raw URLの場所**
  - `https://raw.githubusercontent.com/ユーザー名/リポジトリ名/main/apps.json` のような形式になります。
