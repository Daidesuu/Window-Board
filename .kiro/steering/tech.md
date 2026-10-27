# 技術スタックと実装規約

updated_at: 2026-10-20

## 調査範囲

現在の作業ツリーのコード・プロジェクト設定・スクリプトから確認した内容を記す。既存規約の優先順位は `AGENTS.md` に従う。今回、ビルド・テスト・実機操作は実行していない。

## 技術構成（実装確認）

| 領域 | 使用技術・役割 |
| --- | --- |
| 言語・対象OS | Swift。Xcode設定のSwift言語モードは5.0、macOS Deployment Targetは14.0 |
| 宣言的UI | SwiftUIのScene、View、Settings、状態プロパティ |
| macOS統合 | AppKit、NSWindow、NSStatusItem、NSWorkspace、NSViewRepresentable |
| 外部ウィンドウ | ApplicationServicesのAXUIElement、CoreGraphicsの位置・サイズ・ウィンドウ識別情報 |
| 状態通知 | Combine、ObservableObject、@Published、Subject |
| 非同期処理 | Swift ConcurrencyのTask、Task.detached、MainActor、用途別DispatchQueue |
| 永続化 | UserDefaults、FoundationのCodable/JSONEncoder/JSONDecoder |
| ホットキー | Carbon（Quick Launcher） |
| 診断・更新 | OSLog、Sparkle |
| テスト | XCTest、fakeサービス、注入したsamplerやUserDefaultsによる分離 |

根拠：`WindowBoard.xcodeproj/project.pbxproj` と各ソースのimport・型定義。SparkleはSwift Package依存で、現在の `WindowBoard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` は2.9.5を記録する。言語モードはインストール済みSwiftコンパイラのバージョンを示すものではない。

## ビルドと検証

Xcodeプロジェクトには通常アプリの `WindowBoard`、`WindowBoardTests`、独立アプリの `WindowBoardTree` がある。標準の作業経路はリポジトリのスクリプトを使う。

```sh
# 通常ビルド・起動
./script/build_and_run.sh
# 起動確認付き
./script/build_and_run.sh --verify
# コンパイルのみ
xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData build
# XCTest
xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/DerivedData test
```

- 生成物は既存のbuild/dist配置に従う。試作・Treeの起動は通常アプリとは別モードとしてスクリプトを確認する。
- テストはマッチング、セッション、復旧、追従、前面化、スナップショット、Launcher、Tree、試作の純粋モデルなどを対象にしている。
- fakeによる成功、コンパイル成功、起動成功、実際のAX操作成功、ネイティブドラッグ完了はそれぞれ別の検証結果として報告する。

## 命名・型・構成の既存パターン

- 型・SwiftファイルはUpperCamelCase、プロパティ・メソッド・enum caseはlowerCamelCase。原則として責務を表す名前を使う。
- `Saved...` は永続化参照、`...Store` は保存とコレクション、`...Coordinator` は処理の調停、`...Resolver` / `...Reducer` は照合や状態遷移、`...Controller` は操作やライフサイクルの中心を表す例がある。
- モデルにはstruct、enum、Identifiable、Equatable、Codableを用途に応じて採用する。保存値に生きたAX要素そのものを永続化しない。
- 関数のguardによる早期終了、private/private(set)、関連処理のextension分割を用いる。importは必要なシステムモジュールを直接指定する。同一アプリ内の型をファイルパスでimportする構造ではない。
- UIのBoard表記と内部Workspace型名の併存を維持する。全体改名や保存形式変更は独立した移行検討を必要とする。

## 状態と非同期処理

- Viewは表示と一時操作状態、Sessionは通常アプリの実行状態、Storeは保存状態、Coordinatorは処理方針を担当する。Sessionを迂回して別の切替状態を作らない。
- UI関連CoordinatorやLauncher等には `@MainActor` が使われる。AX取得・移動・復元等はTask.detachedや専用キューへ逃がし、結果適用を `MainActor.run` 等で戻す経路がある。
- `WorkspaceSessionController`、`WindowBoardAppState`、`WorkspaceStore` のクラス全体に `@MainActor` が付いているわけではない。全状態が型でMainActor隔離済みとは仮定せず、変更する経路の呼出元と結果適用先を確認する。
- キャンセル、revision、対象Board・ウィンドウIDの照合を使い、古い非同期結果の上書きを防ぐ。SnapshotはCoordinatorでスケジュール・採取、Reducerで遷移し、呼出元で状態変更・保存する。
- `@unchecked Sendable` を持つAXサービス等があることは、可変状態を無条件に並列共有できる根拠にはならない。AX境界と処理単位を保つ。
- Followは移動処理の間引き・集約、Frontingはdebounce・キャンセル、Snapshotは低頻度サンプリングを使う。no-opを避ける方針を維持する。

## エラーと永続化

- AXの位置・サイズ・操作失敗は `WindowBoardAXError: LocalizedError` とthrowsで表す。呼出元ではdo/catch、try?、結果enum、statusMessageなど、操作の重要度に応じて扱う。
- 取得失敗は通常の状態として扱い、Unavailable/Reconnecting/Minimized等を区別する。失敗だけで登録を黙って解除しない。同一アプリの曖昧一致を無制限に許容しない。
- Snapshotでは通常の読取失敗を連続失敗として評価する一方、pidが0のプレースホルダーと最小化状態を別扱いする。古いrevisionや別Boardの結果を適用しない。
- Codableの独自decodeとdecodeIfPresentによる既存データへの互換処理がある。新しい保存項目も欠落時の扱いを検討する。
- 永続化失敗の扱いは統一されていない。`WorkspaceStore` はdecode失敗で空配列へフォールバックし、encode失敗では保存キーを削除する。一方 `BoardStorageBootstrapper` は置換前にthrowするencode処理を完了する。すべての保存経路が既存データを保護すると記載・仮定しない。

根拠：`WindowBoard/Services/AccessibilityWindowService.swift`、各Coordinator、`WindowBoard/Models/AttachedWindowSnapshotReducer.swift`、`WindowBoard/Stores/WorkspaceStore.swift`、`WindowBoard/Stores/BoardStorageBootstrapper.swift`。

## 検証変更の指針

AGENTS.mdが指定する状態遷移・復旧・追従・前面化・Snapshotの変更には焦点を絞ったテストを追加する。タイミング依存処理はfakeや注入可能な処理で検証し、実アプリ権限・別Space・マウス操作の証明に置き換えない。Debugの診断ログは利用者の操作フローへ露出させず、低ノイズに保つ。
