# 通常版・Tree版のビルドと起動検証（タスク7.2）

検証日：2026-10-23（Asia/Tokyo）。本書はタスク7.2の検証記録であり、実ウィンドウの最小化・復元成功を示すものではない。

## Task Brief

- 受け入れ条件：既存XCTest経路で関連機能を含む全テストが成功し、通常版が既存スクリプトから起動し、Tree版が共有AX型を含めてコンパイルできる。Swift言語モード5.0で隔離・共有状態の新規警告を確認する。
- 完了成果物：本記録と実行ログ。レビューで発見した既存Snapshotテストの待機方法だけを修正し、本番ソース、設定、起動スクリプト、タスク一覧は変更しない。
- 設計制約：通常版、仮データの試作、独立Tree版を区別する。共有AX契約以外の通常版専用実行管理をTreeへ追加しない。Swift 6への移行や無条件の並列共有宣言は行わない。
- 検証方法：要件2.1、3.3、5.3、6.1、6.2、6.3に関わる回帰をXCTestで確認し、設計のTechnology Stack、Components and Interfaces、Testing Strategy、Migration Strategyに沿ってビルド・起動結果と実AX検証を区別する。挙動変更のない検証タスクのためRED／機能フラグは適用外。

## 実行環境と作業ツリーの保全

Desktop上の直接ビルドと古いDerivedDataでは、先行タスクで停止が観測された。今回もソースを変更せず、一時コピー `/private/tmp/wb-minimization-task-7.1` で検証した。通常版ソース、テスト、Treeソース、Xcodeプロジェクトの4ディレクトリに含まれる109ファイルについて、実行前に作業ツリーとのバイト単位一致を確認した。既存の `script/build_and_run.sh` も同一内容をコピーした。

一時コピーの古い `build/DerivedData` は削除せず `build/DerivedData.pre-7.2-preserved` へ移し、同じコピー内で検証済みの `build/IntegrationDerivedData` を指すシンボリックリンクを `build/DerivedData` に置いた。以降は既存コマンドの引数を変えず実行した。生成物はコピー内の既存build/dist配置、ログは作業ツリーのbuild配置へ保存した。既存のユーザー変更を戻していない。

## 結果

| 検証 | 実行内容・観測 | 結果と証跡 |
| --- | --- | --- |
| 通常版ビルド・起動 | `./script/build_and_run.sh --verify`。prototype指定なし | exit 0、`BUILD SUCCEEDED`、`WindowBoard is running.`。`build/minimization-task-7.2-launch.log` |
| 起動対象 | 実行プロセスのパスとBundle情報を読み取った | PID 7362、`/private/tmp/wb-minimization-task-7.1/dist/WindowBoard.app/Contents/MacOS/WindowBoard`、Bundle ID `com.local.WindowBoard`。`WindowBoardSplitPrototype` は未設定（false）。`build/minimization-task-7.2-process.log` |
| Tree版コンパイル | `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoardTree -configuration Debug -derivedDataPath build/DerivedData build` | exit 0、`BUILD SUCCEEDED`。`build/minimization-task-7.2-tree.log`。Treeアプリは起動していない |
| 全XCTest | `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData test` | exit 0、285件・失敗0、`TEST SUCCEEDED`。`build/minimization-task-7.2-tests.log` |
| 実ビルド設定 | 同じ通常版・Debug・DerivedData指定で `-showBuildSettings` | exit 0、`SWIFT_VERSION = 5.0`、macOS Deployment Target 14.0、SDK macOS26.5。`build/minimization-task-7.2-settings.log` |

全テストにはWindowMatching、WorkspaceMinimization、WindowMinimizationExecutor、WindowOperationInspection、Snapshot、Recovery、Launcher等の既存・追加テストが含まれる。上表の初回実行は成功したが、後続の独立レビューで下記の既存テスト不安定性を検出した。これはfake等で制御した検証であり、3つの入口を実際のUIで操作したことや、外部アプリのAX操作成功を意味しない。

## 独立レビューでの失敗と修正

独立レビューの全テスト実行はexit 65となり、`testSnapshotWaitsForIntervalBeforeFirstSample` の取得回数・consume回数がいずれも0で、1以上を要求する2つのアサーションに失敗した。証跡 `build/minimization-review-7.2-tests.log` 111〜113行は保持した。テストは5msと25msの固定sleep後に背景処理が進行済みと仮定しており、スケジューラ遅延で誤失敗していた。

修正範囲は `WindowBoardTests/AttachedWindowSnapshotCoordinatorTests.swift` の当該テストと既存actor probeの初回時刻記録だけである。consumeでexpectationを完了してCoordinatorを停止し、2秒の上限付きで実際の完了を待つ。さらにrestart直前と初回サンプル時のContinuousClock時刻を比較し、設定間隔15msより早いサンプリングがないことと取得1回を確認する。単にsleepを延ばして初回間隔の検証を失う変更ではない。本番コードの変更やSendable宣言の追加はない。既存レビュー失敗をREDの証跡とし、テストの待機修正なので機能フラグは適用しない。

修正後、作業ツリーと一致するコピーで正準の全XCTestコマンドを実行し、285件・失敗0・exit 0・`TEST SUCCEEDED` を確認した。証跡は `build/minimization-task-7.2-remediation-tests.log`。本番ソースは変わっていないため、先行する通常版・Treeビルドと起動の証跡はそのまま有効である。

通常版ビルドログにコンパイラ警告はなく、TreeビルドとテストのログにはAppIntents.framework依存がないためメタデータ抽出を省略する警告がある。隔離違反、Sendable、共有状態に関する新規コンパイラ警告はこの実行ログで検出されなかった。テストホストではOSサービス `com.apple.linkd.autoShortcut` への接続エラー4097も出力されたが、テストは全件成功した。警告・OSログを無視して完全無警告と報告していない。

実プロセス確認の最初の試行では、sandbox内の `ps` 読取りが `operation not permitted` となった。読み取り権限を付けた再実行で上記のPIDとパスを取得した。起動やビルドの失敗ではない。

## 検証範囲の限界

今回確認したのはテスト、通常版のビルドとプロセス起動、Tree版のコンパイルまでである。ウィンドウ表示の使いやすさ、Accessibility権限、未登録ウィンドウの実際の最小化、連続切替後の復元、Terminal保護、3つの実UI入口はタスク7.3の別証跡が必要になる。起動成功を実AX操作成功に置き換えず、別Space・フルスクリーンの制御や未測定の時間目標も保証しない。

親担当のCUAによる起動後の画面読取りでは、通常版にAccessibility権限が必要という案内が表示され、ウィンドウ操作が無効になっていることが確認された（親担当からの直接観測報告）。これは実AX操作が成功した証拠ではなく、7.3実施前に確認すべき現在の環境状態として区別する。
