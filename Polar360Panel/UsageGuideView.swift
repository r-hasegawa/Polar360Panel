import SwiftUI

struct UsageGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    section(title: "このアプリについて") {
                        Text("Polar 360センサーからHR(心拍数)・体表温・加速度を取得し、CSVとして端末内に保存するアプリです。用途に応じて「オンラインモード」と「オフラインモード」を、計測開始前に1回選びます。")
                    }

                    section(title: "なぜオンライン/オフラインを分けているか") {
                        Text("Polar 360は、同じ種類のデータ(体表温・加速度)について、「オンラインストリーミング」と「オフライン記録(センサー内蔵メモリへの記録)」を同時には使えない仕様になっています。両方同時に使おうとすると、正常に動作しなくなります(体表温が取得できない、記録自体が破損する、等)。")
                        Text("この制約のため、体表温・加速度は「接続中だけリアルタイムに見る(オンライン)」か「切断中も含めてセンサー側に記録し続ける(オフライン)」かを、計測開始前に選んでもらう設計にしています。")
                        Text("HRだけは例外です。標準のBLE Heart Rate Serviceという別の仕組みを使っているため、オンライン表示とオフライン記録を同時に行えます。そのためHRはモードを問わず常に両方動作します。")
                    }

                    section(title: "他にも制約に基づいて設計している部分") {
                        bullet("加速度のオンライン50Hz固定/オフライン10Hz標準という違い → 通常モード(SDK Modeを使わない設定)では、オンラインストリーミングは50Hzの1択しか候補が無く、オフライン記録はより低いレートも選べる、というセンサー側の仕様差による(オフライン記録はメモリ・電力の制約で低レートが基本、という設計思想と一致)")
                        bullet("SDK Mode(加速度の高レート化などが可能になる拡張モード)を使っていない → SDK Modeを有効にすると、HRのストリーミング・記録が両方使えなくなる(アルゴリズムが無効化されるため)。HRを常時取得できることを優先し、あえて使っていない")
                        bullet("オフライン加速度のデフォルトを10Hzにしている → Polar 360のオフライン加速度記録には、高いレートだと取得時にエラーになる既知の不具合報告があるため、事故が少ないと確認できているレートを標準にしている")
                        bullet("「計測終了」ボタンで初めてデータを取得・保存する(接続中は自動同期しない) → 以前は数十秒おきに自動で「停止→取得→再開」を繰り返す設計にしていたが、これ自体が記録の空白(取りこぼし)を生む原因になっていたため、取得のタイミングを「計測終了」時だけに絞った")
                        bullet("保存ファイル名が日付ではなくセンサーID・セッション単位 → 同じセンサーを複数回計測に使う運用や、同期を繰り返す運用でも、「どのファイルに追記すればいいか」が常に一意に決まるようにするため")
                        bullet("オンラインの加速度グラフだけ保持時間を3分に短縮 → 50Hz×3軸という高頻度データを長時間保持すると、動作が重くなる/メモリを圧迫するため")
                    }

                    section(title: "オンラインモード") {
                        bullet("接続中のみ、HR・体表温・加速度をリアルタイムにグラフ表示")
                        bullet("体表温は1/2/4Hzから選択可")
                        bullet("加速度はセンサーの仕様上、通常モードでは50Hz固定(変更不可)")
                        bullet("切断すると、その間のデータは記録されない(オフラインのような安全網はなし)")
                        bullet("「計測終了」= 切断はするが、同じセンサーへすぐ再接続できるよう情報を残す")
                        bullet("「切断」= 情報を全部忘れて検索画面に戻る(別センサーに繋ぎたい時など)")
                    }

                    section(title: "オフラインモード") {
                        bullet("接続の有無に関わらず、センサー内蔵メモリにHR・体表温・加速度を記録し続ける")
                        bullet("接続中は数値の確認と残り容量の確認ができるが、データの取得(取り出し)は「計測終了」を押した時のみ")
                        bullet("「切断」だけでは記録は止まらない(センサー内で記録され続ける)")
                        bullet("「計測終了」= 記録を停止し、その時点までのデータを取得・保存してから切断する")
                        bullet("加速度は10Hzが標準。10Hzを超えるレートを選ぶと、取得時にエラーになる既知の不具合報告(Polar 360固有)があるため警告が出る")
                        bullet("センサー内蔵メモリの残り容量・残り記録可能時間(推定)を画面に表示")
                    }

                    section(title: "共通の注意点") {
                        bullet("1台のセンサーは、同時に1つのペアリング相手としか組めない。別のiPad/アプリで使いたい場合は、そのセンサーの工場出荷リセットが必要(データも消える)")
                        bullet("iPad 1台に同時接続できるセンサー数は、iPadOS内蔵Bluetoothの制約でおおむね6〜10台が目安")
                        bullet("工場出荷リセット後は、iPad側の設定→Bluetoothに残ったペアリング情報も必ず削除してから再接続すること")
                        bullet("アプリを強制終了しても、選んでいたモードと直前のセンサーは記憶されており、次回起動時に自動で再接続を試みる")
                    }

                    section(title: "データの保存場所") {
                        Text("iPadの「ファイル」アプリ、またはMacとのUSB-C接続経由で取り出せます。")
                        codeBlock("""
                        Documents/
                          Online または Offline/
                            <センサーID>/
                              hr_<セッション開始時刻>.csv
                              skintemp_<セッション開始時刻>.csv
                              acc_<セッション開始時刻>.csv
                              events_<セッション開始時刻>.csv
                        """)
                        Text("ファイル名は「接続(計測)を開始した時刻」で固定され、同じセッション中はずっと同じファイルに追記され続けます。")
                        Text("※ オフラインモードの体表温・加速度は、接続中は何も書き込まれず、「計測終了」を押した瞬間にまとめて書き込まれます。そのためファイル名の時刻(接続開始時刻)と、実際にファイルへ書き込まれた時刻(計測終了時刻)にはズレがあります(HRはリアルタイムに書き込まれるためズレません)。")
                            .foregroundColor(.secondary)
                    }

                    section(title: "既知の制約・不具合") {
                        bullet("Polar 360のオフライン加速度記録は、高いレート(25Hz以上)だと取得時にエラーになる不具合が報告されている(SDK Issue #716, #652)")
                        bullet("充電すると記録は終了する(実測で確認済み)。記録中は絶対に充電しないこと。充電するタイミングは、計測が完全に不要な期間に限定すること")
                        bullet("長時間(目安半日以上)同期せずに放置すると、1回の取得データが大きくなりすぎて取得に失敗するリスクが上がる")
                    }
                }
                .padding()
            }
            .navigationTitle("アプリの使い方")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
                .font(.callout)
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }

    @ViewBuilder
    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .cornerRadius(6)
    }
}
