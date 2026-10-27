# プロダクトの目的と実装範囲

updated_at: 2026-10-20

## この文書の位置付け

現在の作業ツリーを静的に調査して新規作成したSteering。未コミットの実装も調査対象とした。
`AGENTS.md` の制約を変更するものではない。要件は `APP_REQUIREMENTS.md`、次期構造の設計は `BASIC_DESIGN.md` を参照する。ただし設計書の記述だけを実装完了の根拠にしない。
以下の「実装確認」はコード経路の存在を意味し、実機での動作保証や今回のテスト実行結果を意味しない。対象ユーザー像や開発意図は推測して補わない。

## 目的

WindowBoardは、複数アプリの外部ウィンドウをBoardとして登録し、作業単位で切り替え、配置・前面化・追従を扱うmacOSアプリである。利用者向けには **Board** と呼び、保存モデルやセッションの `Workspace...` 名は内部用語として維持する。

## 実装確認：通常のWindowBoard

### Boardと登録ウィンドウ

- Boardの作成、改名、削除、検索別名、Status Item表示の設定を備える。既定のPermanent Boardは削除から保護される。
- 現行構成はPrimary Boardへの追加ルート・子Boardを解決する方式で、単なる平坦な分割グループではない。構成解決ではBoardとウィンドウ参照の重複を除く。
- 外部アプリのウィンドウを列挙・検索し、登録・解除・順序変更・Board間移動を行う。登録先の所有Boardをセッションで保持する。
- 通常UIはサイドバーとウィンドウカードを中心に構成され、追加用カードを持つ。

根拠：`WindowBoard/Stores/WorkspaceStore.swift`、`WindowBoard/Stores/BoardCompositionStore.swift`、`WindowBoard/App/WorkspaceSessionController.swift`、`WindowBoard/Views/ContentView.swift`。

### 保存・切替・復旧

- 保存参照にはアプリ識別情報、タイトル、文書URL、相対位置、絶対位置、任意のサイズなどを持ち、位置とサイズの復元を試みる。
- 切替時は登録をプレースホルダーで先に表示し、背景処理で実ウィンドウを照合する。閉じた／取得できないウィンドウも登録を維持する。
- `Find or Reopen` は再オープンと再照合を試みる。`Use Front Window` は同一アプリ内の明示的な代替経路である。
- 不足ウィンドウの切替時自動復旧は設定で制御し、既定はオフ。切替後の未登録ウィンドウ最小化は別の非同期処理として扱う。
- 現行実装にはスナップショットや切替時の保存経路が残る。「復元用配置を書き換えるのは明示Save Layoutだけ」という次期方針が全経路に適用済みとは記載しない。

根拠：`WindowBoard/Models/SavedWorkspace.swift`、`WindowBoard/App/WorkspaceSessionController.swift` の `switchWorkspace`、`persistActiveWorkspaceSnapshot`、`persistActiveWorkspaceSnapshotForSwitch`、復旧処理。

### 周辺操作

- Follow Mode、登録ウィンドウの前面化、未登録ウィンドウの最小化、最小化からの復元、位置更新設定を備える。Follow ModeのNoneは登録解除を意味しない。
- Status ItemとQuick LauncherからBoard切替やウィンドウ操作へ到達する。切替の中心は通常画面と共通のセッションである。
- Quick Launcherにはグローバルホットキー、Board・ウィンドウ・操作の検索、利用履歴がある。
- Sparkleによる更新確認の接続があるが、設定が有効な場合に初期化される。配信運用の成立はこの調査では未確認。

根拠：`WindowBoard/App/WindowBoardAppState.swift`、`WindowBoard/App/WindowBoardStatusItemController.swift`、`WindowBoard/Launcher/`、`WindowBoard/App/WindowBoardUpdateController.swift`。

## 実装の境界：試作・別ターゲット・次期設計

- **分割UI試作**：`--split-prototype` または専用Bundle設定で、通常の共有状態を生成する前に別シーンへ分岐する。`SplitBoardPrototypeView` と `Prototype...` モデルは仮データ上の表示・ドラッグ・アニメーションを扱う。本番のAX、実保存、セッションへの接続を実装済みとしない。
- **WindowBoardTree**：独立したアプリターゲット。`TreeWindowBoardAppState` がツリーストア、ディレクトリ操作、専用ウィンドウ操作を組み立てる。通常のWindowBoardの切替方式と混同しない。ツリー用保存初期化には旧Board保存キーの置換処理があるため、汎用の非破壊移行とはみなさない。
- **次期設計**：`BASIC_DESIGN.md` の平坦なグループ、観測状態と復元配置の分離、移行・ロールバック方針は、現在の本番モデルへの適用完了を意味しない。実装判断では対象の入口と保存モデルを確認する。

## macOS上の制約

Accessibility権限と各アプリのAX対応に依存する。再接続・配置・サイズ・前面化・最小化はベストエフォートであり、閉じた同一ウィンドウの完全復元や厳密なz-orderを保証しない。他Spaceへの既存ウィンドウ移動やフルスクリーンSpace制御を対応済み機能として扱わない。

## 更新時の原則

個々のボタンを網羅するより、登録を保持したまま復旧可能にすること、Board所有権を保つこと、素早い表示と背景AX処理を分けることを優先する。ユーザーに見える意味が変わる場合は `AGENTS.md` に従って要件書も整合させる。
