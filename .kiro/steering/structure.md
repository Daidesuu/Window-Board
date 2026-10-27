# 構造・責務・データフロー

updated_at: 2026-10-20

## 整理方針

現在の実装は、通常アプリの層別構成を基本とし、Launcher、独立したTreeアプリ、仮データの分割UI試作が併存する。以下はコードから確認した責務であり、将来の理想構造への置換ではない。`AGENTS.md` の責務境界と用語を維持する。

## ディレクトリのパターン

| 場所 | 責務・配置するもの | 代表例 |
| --- | --- | --- |
| `WindowBoard/App/` | 通常アプリの起動・共有状態・セッション・メニュー統合 | WindowBoardApp、WorkspaceSessionController |
| `WindowBoard/Views/` | SwiftUIの画面合成と用途別表示部品 | ContentView、BoardCardViews、BoardSidebarViews |
| `WindowBoard/Models/` | 保存参照、ライブウィンドウ情報、設定enum、純粋な照合・状態遷移 | SavedWorkspace、WindowInfo、AttachedWindowSnapshotReducer |
| `WindowBoard/Stores/` | Boardデータ・構成・ツリーの保存と整合性、ディレクトリ操作 | WorkspaceStore、BoardCompositionStore、BoardDirectoryController |
| `WindowBoard/Services/` | AX境界と狭い非同期処理の調停 | AccessibilityWindowService、各Coordinator |
| `WindowBoard/Support/` | 自身のNSWindowとSwiftUIをつなぐ小さい橋渡し | BoardWindowObserver、BoardClickObserver |
| `WindowBoard/Launcher/` | 検索モデル・表示・ホットキー・パネル・既存操作への接続 | QuickLauncherViewModel、QuickLauncherIntegration |
| `WindowBoardTree/` | 別アプリの入口・状態・ツリー画面 | TreeWindowBoardAppState、TreeContentView |
| `WindowBoardTests/` | 純粋ロジック、fakeサービス、Coordinator等のXCTest | WindowMatchingTests、AttachedWindowSnapshotCoordinatorTests |
| `script/` | 開発用ビルド・起動や配布関連の補助 | build_and_run.sh |

`WindowBoard.xcodeproj/` がターゲット・ビルド設定を定義する。`docs/` とルートのMarkdownは要件・設計・運用の説明、`build/`・`dist/` は既存の生成物配置として扱う。全ファイルの一覧をSteeringへ複製しない。

## 通常アプリの所有関係

```text
WindowBoardApp / 共有オブジェクト
  └─ WindowBoardAppState
       ├─ WorkspaceStore          保存したBoard・ウィンドウ参照
       ├─ BoardCompositionStore   現行のBoard合成関係
       └─ WorkspaceSessionController
            登録中ウィンドウ・所有Board・選択/稼働状態・切替中状態

ContentView ──────────────┐
Status Item / Launcher ───┴─ 共有AppState・Sessionへ操作を渡す
```

- `@StateObject` で共有状態のライフサイクルを保持し、Viewは `@ObservedObject` 等で観測する。ContentViewの `@State` は候補表示や一時操作、Coordinator保持などに使われる。
- `selectedWorkspaceID` と `activeWorkspaceID`、表示構成、各登録の所有Boardを同一の意味とみなさない。操作ごとの対象を明示する。
- `SavedWorkspace` / `SavedWindowReference` は再接続と復元に必要な保存情報、`WindowInfo` はAX要素を含む実ウィンドウ情報、`AttachedWindow` は実行中の登録情報を表す。
- `WorkspaceStore` はBoard本体、`BoardCompositionStore` は構成を管理する。現行構成にはルート追加と子の関係があり、解決結果が表示・登録参照に使われる。

## SwiftUI・AppKit・Accessibilityの接続

1. SwiftUIの操作やStatus Item・Launcherの要求を、AppState/Sessionと画面側の調停処理へ渡す。
2. 自身のWindowBoardウィンドウは `NSViewRepresentable` のObserverで取得し、移動・リサイズ・クリック等を通知する。Status ItemやLauncherのパネル等もAppKitが担う。
3. 外部アプリのウィンドウは `AccessibilityWindowService` をAX境界として列挙・照合・読取・移動・サイズ変更・最小化・前面化する。
4. 時間のかかる外部操作は背景Task/キューで処理し、対象IDやrevisionを確認したうえで画面・セッションへ結果を反映する。
5. 保存が必要な結果は呼出元からStoreへ渡す。Coordinatorが独立してセッションや永続化を所有する構造にしない。

AppKitとAXでは座標系が異なる。Board原点から相対位置を計算する経路では、AX側の左上基準との変換を確認する。NSWindowのframe.originをそのまま外部ウィンドウ座標とみなさない。

## 非同期コンポーネントの境界

- `ApplicationWindowCatalog`：列挙とキャッシュ統合。保存Boardや切替状態の所有者ではない。
- `AttachedWindowRecoveryCoordinator` とResolver：明示的な再接続の進行と照合判断。別アプリへの黙示的な付け替えをしない。
- `BoardFollowCoordinator` と `WindowMoveScheduler`：追従のタイミング、移動計画、移動作業の調停。
- `BoardFrontingCoordinator`：前面化のdebounce、取消、revision方針。
- `AttachedWindowSnapshotCoordinator`：低頻度の採取スケジュールと背景読取。`AttachedWindowSnapshotReducer`：採取結果に基づく純粋な状態遷移。状態変更と保存の実行は呼出元へ残す。

サービスは `WorkspaceWindowOperating` / `ContentWindowOperating` 等のprotocolやfactory、クロージャで注入できる。純粋なResolver/Reducerと副作用を分けることで、実AXに依存しない回帰検証を可能にする。新しい調停処理も既存SessionやAX境界を迂回させない。

## 別経路を混同しない

### 分割UI試作

`WindowBoardEntryPoint` は `--split-prototype` またはBundle設定を確認し、通常のScene・共有状態を作る前に試作アプリへ分岐する。`Views/SplitBoardPrototypeView.swift`、`Models/PrototypeBoardDragModel.swift` と `Prototype...` の補助群は仮データのメモリ内状態で動く。通常画面と同じディレクトリ内にあっても、本番保存・AXへの接続とは扱わない。

### Treeアプリ

`WindowBoardTree/App/TreeWindowBoardApp.swift` が独立した入口である。
`TreeWindowBoardAppState` は `WorkspaceStore`、`BoardTreeStore`、`BoardDirectoryController`、`TreeBoardWindowController` を所有する。
ディレクトリControllerが階層CRUD・移動・お気に入り、ウィンドウControllerが専用の外部ウィンドウ操作を担当する。
通常アプリのSessionは所有しない。この別経路を理由に、通常アプリの主画面・Status Itemの共通Session規則を分割しない。

Treeの初期化は `BoardStorageBootstrapper` が保存世代・Root Board・ツリーを検査する。不整合時にはBoard関連保存キーを初期化する実装である。保存領域と初期化条件を確認せず、通常アプリへ流用しない。

## 設計書との対応と更新判断

`APP_REQUIREMENTS.md` / `BASIC_DESIGN.md` には次期の平坦グループと観測・復元保存分離が記載される。一方、現行Sessionには構成解決とスナップショット保存が残る。将来名の `ObservedWindowState`、`refreshComposition`、`switchDisplay` を現行本番APIとして紹介しない。

新しいファイルが既存の責務分割に従うだけならSteering更新は不要。所有関係、保存の意味、通常/試作/別ターゲットの境界が変わる場合に更新する。実装と要件の差は明記し、ドキュメントだけで未実装部分を完成扱いしない。
