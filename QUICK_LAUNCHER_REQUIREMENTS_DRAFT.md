# WindowBoard クイックランチャー要件ドラフト

状態: MVP実装済み。正式なユーザー向け要件は `APP_REQUIREMENTS.md` の「Quick Launcher Requirements」を正とする  
対象: `WindowBoard.app`（`WindowBoard` target）  
対象外: `WindowBoard Tree.app`（`WindowBoardTree` target）

## 1. 目的

既存のWindowBoardへ、キーボード中心で操作できるSpotlight風クイックランチャーを追加する。

グローバルショートカットからランチャーを表示し、メインウインドウを開かずに、次の対象を検索・実行できるようにする。

- 保存済みBoard
- 保存済みWindow Reference
- 現在利用可能なWindowBoardのAction

クイックランチャーは別アプリやhelper processにせず、既存の `WindowBoard.app` 内に実装する。メインウインドウとStatus Itemと同じ `WindowBoardAppState`、`WorkspaceStore`、`BoardCompositionStore`、`WorkspaceSessionController` を共有する。

## 2. 現行の用語

ランチャーのユーザー向け表示では、次の現行用語を使用する。

| 用語 | 意味 |
| --- | --- |
| Board | 外部ウインドウの参照とレイアウト情報を保存する単位 |
| Current Board | 現在読み込まれている、複数Boardを含み得る解決済み構成 |
| Primary Board | Current Boardを解決するときの起点になる保存Board |
| Included Board | Current Boardへ追加ルートまたは子として含まれるBoard |
| Permanent Board | 削除・改名できない既定Board |
| Attached Window | Current Board内で解決された、liveまたはplaceholderの実行時表現 |
| Window Reference | 外部ウインドウを再検出・復元するための保存情報 |

注意事項:

- `Primary` と `Included` はBoardの固定種別ではなく、現在のBoard構成内での役割である。
- `Permanent Board` は常に全Current Boardへ重なる特別レイヤーではない。構成に含まれた場合だけCurrent Boardへ参加する。
- `Pinned Board` という概念は追加しない。
- `Pinned Window` ではなく、文脈に応じて `Attached Window` または `Window Reference` を使う。
- 内部型の `Workspace...` 名はランチャーUIへ表示しない。

## 3. 旧プロンプトからの修正

| 旧表現 | 現行仕様に合わせた扱い |
| --- | --- |
| BoardをRestore | `Switch to Board`。Board切替自体が保存レイアウトをbest-effortで適用する |
| Restore Current Board | `Restore Layout` |
| Snapshot Current Board | MVPから削除。現在の同名ユーザーActionではない |
| Attach Front Window | `Attach Window` |
| Find Unavailable Windows | `Recover Missing` |
| Reopen Missing Windows | 独立Actionにせず、既存のrecoveryへ統合したままにする |
| Bring attached windows to front | `Focus Board` |
| Restore Minimized | `Restore Windows` |
| Open Main Window | `Show Window` |
| PermanentまたはPinned Boardを優先 | 削除。PermanentはFavoriteを意味しない |
| 63件以上のXCTest | 固定件数を削除し、現在の全テストを実行する |

個別Windowでは、現在の状態別Action名を維持する。

- `Bring Forward`
- `Restore Window`
- `Find or Reopen`
- `Use Front Window`（既存recoveryが条件を満たした場合のみ）
- `Save Layout`
- `Detach from Board`

## 4. MVPの操作フロー

1. ユーザーがグローバルショートカットを押す。
2. マウスポインタがあるディスプレイの中央付近にランチャーが表示される。
3. 検索フィールドへ自動的にフォーカスする。
4. Board名、アプリ名、Windowタイトル、所属Board名、Action名を検索する。
5. 上下キーで候補を選択する。
6. Enterで候補の既定Actionを実行する。
7. Escapeで何も実行せず閉じる。
8. Actionの開始を受け付けたらランチャーを閉じる。ただし開始前エラーを表示する必要がある場合は短いメッセージを表示する。

マウスでは、ホバー表示、クリック選択、ダブルクリック実行に対応する。

## 5. 専用ランチャーウインドウ

既存の `WindowGroup` とは別に、SwiftUI Viewをホストする専用 `NSPanel` を使用する。

必須要件:

- 既存の `WindowBoard.app` プロセス内で動作する。
- メインウインドウの生成・表示状態に依存しない。
- メインウインドウを閉じた状態やWindowBoardがバックグラウンドの状態でも表示できる。
- 通常のタイトルバーを表示しない。
- 角丸、macOS標準material、適切な影を使用する。
- 表示中は通常ウインドウより前面に置く。
- key windowになり、検索フィールドが確実に文字入力を受け取れる。
- `nonactivatingPanel` 等を使う場合も、キーボード入力不能になる組み合わせを採用しない。
- Escape、ショートカットの再入力、Action受理、必要に応じたフォーカス喪失で閉じる。
- 通常のウインドウ復元対象にせず、アプリ起動時に自動再表示しない。
- `NSEvent.mouseLocation` を含む `NSScreen.visibleFrame` の中央へ配置する。
- 対象screenを判定できない場合はmain screenへ安全にfallbackする。
- 見た目上タイトルを隠しても、アクセシビリティ上のウインドウ名は持たせる。

WindowBoardは現在どおり通常のDockアプリとStatus Itemを維持する。Dockアイコンの廃止やメニューバー専用アプリ化は、この機能の対象外とする。

## 6. グローバルショートカット

初期値は `Command + Shift + Space` とする。

要件:

- WindowBoardが起動中であれば、バックグラウンドから表示できる。
- 表示中に同じショートカットを押すと閉じる。
- 表示中だがkey windowでない場合は、前面化して検索フィールドへ戻す。
- 登録失敗時にクラッシュさせず、WindowBoardの他機能を継続する。
- 登録・解除処理を専用controllerへ分離する。
- ショートカットの値とOSへの登録処理を分離し、将来Settingsから変更できる構造にする。
- 現在依存が存在しない限り、MVPでは新しい外部packageを追加しない。
- 登録失敗時にも使えるよう、Status Itemへ `Show Quick Launcher` を追加する。

このショートカットはWindowBoardプロセスの起動中だけ動作する。Launch at Loginや、終了中のWindowBoardをショートカットから起動する機能は将来要件とする。

## 7. 候補モデル

Board、Window、Actionを統一候補として扱う。ただしSwiftUI Viewが `SavedWorkspace`、`SavedWindowReference`、`AXUIElement` の具体的処理へ直接依存しないようにする。

```swift
enum QuickLauncherItemKind: Equatable {
    case board
    case window
    case action
}

struct QuickLauncherItem: Identifiable, Equatable {
    let id: String
    let kind: QuickLauncherItemKind
    let title: String
    let subtitle: String?
    let keywords: [String]
    let badge: String
    let icon: QuickLauncherIcon
    let target: QuickLauncherTarget
}
```

名称は既存の命名規則に合わせて調整してよい。Viewは候補の描画とtargetの送出だけを行い、Board切替、永続化、AX操作を実装しない。

## 8. Board候補

保存済みBoardを、サイドバーおよびStatus Itemと同じBoardグループ解釈で候補化する。

表示内容:

- Board名
- 保存Window Reference数
- 必要に応じた文脈ラベル: `Current`、`Primary`、`Included`、`Permanent`
- 必要な場合のみ最終更新日時

`updatedAt` は改名や設定変更でも更新されるため、「最近使用した日時」として扱わない。

Board候補の実行targetには、少なくとも次を保持する。

- 読み込むPrimary Board ID
- 表示上選択するmember Board ID

既定Actionは `Switch to Board` とする。

- `WorkspaceSessionController` をBoard切替の唯一のownerとする。
- `activeWorkspaceID` と `selectedWorkspaceID` を混同しない。
- Current Boardグループ内のmember選択を、新しいPrimary Boardの読み込みとして誤解釈しない。
- 切替中の追加要求は既存のpending switch経路へ渡す。
- ランチャーを閉じた後も、既存の段階的なBoard切替処理を継続できる。

将来の副Actionでは、Boardを切り替えてメインWindowBoardウインドウにも表示できる。

## 9. Window候補

Window候補には、保存済みWindow Referenceと、Current Boardですでに判明しているruntime stateを使用する。

表示内容:

- アプリ名
- 保存Windowタイトル。空の場合は保存display name
- owning Board名
- 現在判明している状態
- 既存icon cacheから取得できる場合はアプリアイコン

Current Boardの既知状態:

- `Available`
- `Resolving`
- `Minimized`
- `Unavailable`
- `Reconnecting`

非アクティブBoardのWindow Referenceは、現在のAX状態を解決済みではない。そのため、単にCurrent Boardに存在しないことを理由に `Unavailable` と表示せず、`Saved` と表示する。

既定Action:

| 状態・文脈 | 既定Action |
| --- | --- |
| Current Board内でAvailable | `Bring Forward` |
| Current Board内でMinimized | `Restore Window` |
| Current Board内でUnavailable | `Find or Reopen` |
| ResolvingまたはReconnecting | 実行不可。進行中であることを表示 |
| 非アクティブBoardに保存 | owning Boardへの `Switch to Board` |

非アクティブBoardへの切替後に、自動的にfocus/recoveryまで継続する動作はMVPに含めない。将来追加する場合は、request revisionまたはcancellation tokenを使い、古い要求が新しいCurrent Boardへ作用しないようにする。

ランチャーから `AXUIElement` を直接操作しない。前面化、最小化解除、matching、reopenは既存のAccessibility service、fronting、recovery境界を通す。

## 10. Action候補

現在の製品に実在し、実行条件を満たすActionだけを表示または有効化する。

MVP候補:

- `Show Window`
- `Focus Board`
- `Restore Layout`
- `Attach Window`
- `Recover Missing`（復旧対象がある場合）
- `Minimize Others`
- `Restore Windows`（WindowBoardが最小化した履歴がある場合）
- `Refresh Window List`

MVPへ追加しないAction:

- `Snapshot Current Board`
- 独立した `Reopen Missing Windows`
- BoardのDeleteまたはRename
- Window ReferenceのDetachまたはMove
- 任意BoardへのAttach
- 現在の製品に存在しない個別WindowのMinimize

利用可能条件はメインウインドウのToolbarまたはStatus Itemと一致させる。

- Board一覧の検索はAccessibility権限なしでも可能。
- `Focus Board`、Window前面化、recovery、minimize、restore、attachにはAccessibility権限が必要。
- `Recover Missing` は復旧可能なAttached Windowがある場合だけ有効。
- `Minimize Others` は `session.canMinimizeUnattached` に従う。
- `Restore Windows` は `session.canRestoreMinimized` に従う。
- 実行中の競合Actionは無効化する。

メインウインドウ固有の処理が必要なActionは、共有のView非依存Action層へ移すか、明示的にメインウインドウを表示してから実行する。`ContentView` が存在しないために黙って何もしない状態を許可しない。

## 11. 検索仕様

検索対象:

- Board名
- アプリ名
- Windowタイトルと保存display name
- owning Board名
- Action名とalias

検索は大文字・小文字を区別しない。可能な範囲でダイアクリティカルマークも区別しない。

順位:

1. 完全一致
2. 前方一致
3. 部分一致
4. 文字順を維持した簡易fuzzy一致
5. ランチャー内の最近の使用
6. ランチャー内の使用回数
7. Current Boardとの関連
8. Current Board内のselected memberまたはPrimaryとしての関連

検索スコアは決定的なpure serviceとして実装し、独立してテストできるようにする。最近の使用と使用回数は、専用 `QuickLauncherUsageStore` で `UserDefaults` へ保存し、検索ロジックから分離する。

空入力時の表示順:

1. 最近使用したBoard
2. Current Board候補
3. 最近使用したWindow候補
4. 現在利用可能なAction候補

初回利用などusage情報がない場合は、Current Board、保存順、主要Actionの決定的なfallback順を使用する。

カテゴリ上限の初期値:

- Board: 5件
- Window: 5件
- Action: 5件

文字入力ごとにAccessibility windowを列挙しない。`WorkspaceStore`、Current session、既存cacheから作ったインメモリindexを検索する。

## 12. キーボードとマウス操作

MVPのキーボード操作:

- 上矢印: 前の候補
- 下矢印: 次の候補
- Enter: 既定Actionを実行
- Escape: 閉じる

選択状態:

- 最初の有効候補を初期選択する。
- 結果更新後も同じitem IDが存在する場合は選択を維持する。
- 選択候補が消えた場合は、有効な候補へ安全に補正する。
- 結果が空の場合は未選択とし、Enterで何もしない。
- Action実行中のEnter連打で重複実行しない。

マウス操作:

- ホバーで軽量な強調表示
- クリックで選択
- ダブルクリックで既定Actionを実行

MVP後の拡張:

- Command + Enterによる副Action
- Tabによる操作モード切替
- `>` から始まるコマンドモード

## 13. 状態と非同期処理

ViewModelは少なくとも次の状態を管理する。

```swift
@Published var query: String
@Published private(set) var results: [QuickLauncherItem]
@Published var selectedItemID: QuickLauncherItem.ID?
@Published private(set) var isVisible: Bool
@Published private(set) var isExecuting: Bool
@Published private(set) var errorMessage: String?
```

配列indexだけでなく、安定したitem IDで選択を管理する。

次の場合も安全に処理する。

- 表示中にBoardが改名または削除される
- 選択候補が消える
- runtime Window状態が変わる
- 結果数が減る
- Board切替がすでに進行中
- Action実行中にランチャーを再表示する
- 古い検索またはActionの完了が返る
- Accessibility権限が失われる

## 14. 実装境界

既存の `WindowBoard` target内に、次の責務を追加する。

- `QuickLauncherWindowController`
- `GlobalHotKeyController`
- `QuickLauncherViewModel`
- `QuickLauncherSearchService`
- `QuickLauncherActionExecutor`
- `QuickLauncherUsageStore`
- `QuickLauncherView`

責務:

- Launcher controllerは、共有app stateとStatus Item controllerと同じapplication scopeで所有する。
- `WorkspaceSessionController` はBoard切替とsession mutationの唯一のownerを維持する。
- `WorkspaceStore` と `BoardCompositionStore` を保存・構成のsource of truthとする。
- `AccessibilityWindowService` をAX境界として維持する。
- `BoardFrontingCoordinator` と `AttachedWindowRecoveryCoordinator` の既存方針を再利用する。
- ランチャー独自のsession、Store、AX worker群を作らない。
- メインウインドウ、Status Item、Launcherの呼び出しを共有Action経路へ収束させる。

現在、単一Windowのfronting、`Find or Reopen`、`Recover Missing`、frontmost Windowのattach、UI context付き `Restore Layout` などの一部処理は `ContentView` のprivate処理である。また、一部commandは `ContentView.onReceive` で消費される。

ランチャー接続前に必要最小限の処理をView非依存の共有Action境界へ抽出し、メインウインドウが未生成でも動作するようにする。ランチャーからAX処理をコピーしない。また、すべてを `WorkspaceSessionController` に押し込まず、session stateとAX Action調停の責務を分ける。

ランチャー起点のBoard切替を明確にするため、必要なら `WorkspaceSwitchSource.launcher` を追加する。メインウインドウを開かず、Status Item起点と同様に保存済み絶対位置を利用できる意味にする。

## 15. パフォーマンス

- ランチャー表示だけで完全なAccessibility window列挙を実行しない。
- 文字入力中にAccessibility APIを呼ばない。
- Store/sessionのpublishと既存cacheから検索indexを更新する。
- 検索はpureかつ件数上限付きにする。
- debounceは計測上必要な場合だけ使用する。
- 小さな `List` または軽量 `VStack` を優先する。
- `LazyVGrid`、連続的なhover animation、繰り返しのicon/tint計算を避ける。
- AX操作は既存service経由でmain thread外に置く。
- debug buildではshortcut登録失敗、panel表示時間、検索時間、Action失敗を低noiseで記録できる。

## 16. アクセシビリティとエラー

設定する内容:

- 検索fieldのaccessibility label
- 候補のtitle、owning Board、種別、状態、選択状態を含む読み上げ
- キーボードだけで完結するMVP操作
- `No results found` の空状態
- Actionを開始できない場合の短いinline error

次の場合もクラッシュまたはWindow Referenceの削除を起こさない。

- Accessibility権限がない
- shortcut登録に失敗する
- 対象Boardが削除済み
- 外部Windowが閉じている、または操作できない
- Board切替、focus、minimize、restore、recoveryが失敗する
- アプリアイコンを取得できない
- 古い非同期処理が完了する

詳細は `Logger` へ出し、ランチャー内には短いメッセージだけを表示する。

## 17. テスト

検索:

- Board名の完全一致、前方一致、部分一致、簡易fuzzy一致
- アプリ名、Windowタイトル、owning Board名の検索
- 大文字・小文字を区別しない
- 空入力時の決定的な順序
- 候補なし
- 同点を含む決定的なscore順
- `Pinned Board` やPermanent自動優遇に依存しないCurrent Board relevance

選択:

- 最初の有効候補を選択
- 上下移動
- 先頭・末尾での境界動作
- 結果更新後のitem ID維持
- 選択候補削除後の補正
- 候補なしでEnterを押しても実行しない

Board projectionとAction:

- Board候補がPrimary Board IDとselected member IDを保持する
- Board実行が共有 `WorkspaceSessionController` 経路を使う
- Available、Minimized、UnavailableのWindow候補が既存の状態別Actionへ接続される
- 非アクティブBoardのWindow候補はMVPではowning Board切替だけを実行する
- 利用不可Actionは非表示またはdisabledになる
- 受理したActionの開始後にランチャーが閉じる
- Action失敗時にクラッシュせず短いエラーを出す
- 実行中のEnter連打を無視する

現在のXCTestをすべて実行し、古い固定件数を合格条件にしない。

手動確認:

- 他アプリが前面の状態からshortcutを押す
- 表示中にshortcutを再度押す
- 表示直後に文字入力できる
- メインWindowBoardウインドウを閉じた状態
- 複数ディスプレイ
- Accessibility権限なし
- Current Boardグループのmember選択
- Available、Minimized、Unavailable、非アクティブBoardのWindow候補
- Status Itemのfallback Action

## 18. 完了条件

- `Command + Shift + Space` で、起動中のWindowBoardからランチャーを開閉できる。
- マウスポインタがあるscreenへ表示され、直ちに入力できる。
- 保存Boardを検索し、共有session経路で切り替えられる。
- Window Referenceをアプリ名、タイトル、owning Board名で検索できる。
- Current BoardのWindow候補が、カードと同じ状態別Actionを実行する。
- 非アクティブBoardのWindow候補は、live操作が可能であると誤表示せずowning Boardへ切り替える。
- 現在利用可能なActionを検索でき、有効条件が既存UIと一致する。
- 上下キー、Enter、Escapeが安定して動作する。
- 文字入力ごとのAX列挙が発生しない。
- メインウインドウが非表示または未生成でもランチャーを使用できる。
- 既存のメインUI、Status Item、Board構成、Permanent Board、recovery、fronting、minimize、restoreを壊さない。
- 新規テストと既存全テストが成功する。
- リポジトリ標準スクリプトで `WindowBoard.app` がbuild・launchできる。
- 実装と確認が完了した後、`APP_REQUIREMENTS.md` にQuick Launcher要件を反映する。

## 19. MVP対象外

- 別ランチャーアプリまたはlogin-item helper
- `WindowBoard Tree.app` への搭載
- 終了中のWindowBoardをshortcutから起動する機能
- shortcut編集用Settings UI
- `>` command parserの完全実装
- BoardまたはWindow Referenceの破壊的操作
- 保存Board外の任意外部Window検索
- shortcutから非アクティブBoardのWindowを自動切替後に即front/recoveryする連続Action
- 他Spaceやfull-screen Windowの確実な制御
- 既存serviceと重複する新しいAX処理

## 20. 実装時の報告内容

実装前:

1. 再利用する既存ファイルと正確な処理経路
2. 共有Action境界へ移す必要がある `ContentView` のprivate処理
3. 追加する型とファイル
4. Panel表示とkeyboard focusの方式
5. shortcut登録方式
6. Board group projectionとWindow候補の動作
7. リスクとMVPで延期する内容

実装後:

1. 変更ファイル
2. 実装した動作
3. 簡略化・延期した動作
4. 新規・既存テスト結果
5. build・launch結果
6. 既知の制約
7. 手動確認手順と、未確認の視覚・実機項目
