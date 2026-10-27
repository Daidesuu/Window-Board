# 実装ギャップ分析：board-switch-minimization

調査日: 2026-10-20（日本時間）
対象: 通常版WindowBoard、現行作業ツリー、要件7領域・33受け入れ基準。
要件状態: requirements-generated、generated=true、approved=false。未承認要件の検討資料として分析を継続した。承認状態・要件本文は変更しない。
検証範囲: ソース・設定・テストの静的調査。ビルド、テスト実行、実機再現、性能測定は未実施。ユーザーが報告した残留ウィンドウのアプリ名・具体的な発生経路は未確認。

## 1. 分析の要約

- 候補漏れは、登録ウィンドウの解決成功と未登録候補の網羅性を同じ条件で扱っていることに起因し得る。既知候補を再利用する高速表示を残し、最小化用の候補確認を独立させる必要がある。
- 最新の切替要求を保持する仕組みはBoard読込みにはあるが、最小化にはない。手動処理を含む準備・実行・完了の全区間で、要求の有効性と結果適用先を扱う必要がある。
- 実行済み最小化の履歴保存と、最新Boardへの画面結果反映は別の判定が必要。古い結果の一括破棄では、利用者が復元できる対象を失う。
- 一覧取得・状態読取りの失敗が既存AX境界で空配列・falseへ変換される。Sessionだけの変更では診断要件を満たせない。AXサービス内診断、結果付きの追加API、既存互換ラッパーを比較する。
- 既存Sessionへの状態集約を保つハイブリッド実装を設計候補として推奨する。新規依存・保存形式移行は不要と考えられるが、最終の構造・型・インターフェースは設計フェーズで決定する。

## 2. 現在の構造と再利用資産

以下のパスと行番号は調査時点の作業ツリーの位置。未コミット変更も含むため、後続フェーズではシンボル名でも照合する。

| 資産 | 再利用する責務・制約 | 主な根拠 |
| --- | --- | --- |
| WorkspaceSessionController | 切替・登録・所有Board・状態・復元履歴の唯一の通常版セッション所有者 | `WindowBoard/App/WorkspaceSessionController.swift:155`、`:680` |
| BoardCompositionResolver | primary、global root、追加root、childの登録参照を合成し所有Boardを保持 | `WindowBoard/Stores/BoardCompositionStore.swift:125` |
| WorkspaceWindowResolver / WindowMatching | 保存参照と生きたウィンドウの照合、placeholderと順序維持 | `WindowBoard/Models/WorkspaceWindowResolver.swift`、`WindowBoard/Models/WindowMatching.swift` |
| WorkspaceWindowOperating / AccessibilityWindowService | AX操作の注入可能な境界。現状は列挙と状態読取の失敗情報が限定的 | `WindowBoard/Services/AccessibilityWindowService.swift:23` |
| 最小化共通ループと保護判定 | 個別失敗後の続行、登録窓の復元、Terminal・曖昧窓の保護、VS Code例外 | `WindowBoard/App/WorkspaceSessionController.swift:1959`、`:1991`、`:2037` |
| ApplicationWindowCatalog | 列挙と候補統合の既存パターン。時刻・網羅性の保証は持たない | `WindowBoard/Services/ApplicationWindowCatalog.swift:4` |
| Snapshot Coordinator等 | 注入、背景処理、revision・取消を用いた遅延結果の破棄という既存パターン | `WindowBoard/Services/AttachedWindowSnapshotCoordinator.swift:95` |
| ContentView / Status Item / Launcher | 操作入口は共通Sessionに到達。各入口の候補・座標・前面化事情は異なる | `WindowBoard/Views/ContentView.swift:1202`、`WindowBoard/App/WindowBoardStatusItemController.swift:223`、`WindowBoard/Launcher/QuickLauncherIntegration.swift:496` |
| XCTestとFakeWorkspaceWindowService | 保存領域の分離、候補応答列、遅延、書込失敗、状態集合による検証 | `WindowBoardTests/WindowMatchingTests.swift:2132` |

命名はStore/Controller/Coordinator/Resolver/Reducer等の責務名を使い、純粋な判断と副作用を分ける。UI操作と結果適用はメイン側、AXの列挙・操作は背景処理という既存方針を守る。ただしSession自体はクラス全体のMainActor注釈を持たず、追加する並行処理の共有状態を型注釈済みと仮定しない。

### 現在の切替フロー

1. 主画面は候補キャッシュ、Status Itemはキャッシュなし、Launcherは短期間の候補キャッシュを渡す。
2. Sessionが設定・合成参照・revisionを取得し、placeholderを先に表示する。
3. 登録をキャッシュで解決し、必要な場合だけ全列挙する。キャッシュ経由なら位置適用を後段に回す。
4. 読込み結果を公開し、設定に応じて背景復旧を開始する。
5. 初期解決時の登録・候補を固定して150ms後に自動最小化を開始する。
6. busyまたは空の登録集合なら開始せず終了。開始済みの最小化・復元ループには世代確認がない。
7. 自動処理の結果は古い世代なら履歴保存前に破棄。手動処理の結果は世代確認なしで適用する。

## 3. 要件と既存資産の対応表

分類: **既存**=対応するコード経路があり維持・回帰確認が中心（動作検証済みの意味ではない）、**部分**=資産はあるが追加対応が必要。ギャップは **Missing**=能力不足、**Unknown**=未確認、**Constraint**=守る制約。
下表で33基準をすべて対応付ける。SCは `WindowBoard/App/WorkspaceSessionController.swift`、AXは `WindowBoard/Services/AccessibilityWindowService.swift` を示す。

| 基準 | 現状・資産 | ギャップと設計への入力 |
| --- | --- | --- |
| 1.1, 1.2 | 部分。SC:782の条件付き列挙と:824の候補統合 | **Missing** 登録解決と無関係な未登録候補補完。**Unknown** 実際に残ったアプリとキャッシュ状態 |
| 1.3 | 既存。SC:751、:987が設定で起動を制御 | **Constraint** OFFの高速経路を維持し、本機能だけの追加列挙を導入しない |
| 1.4 | 既存。SC:1145で登録集合が空なら開始しない | **Constraint** 主Board単体ではなく合成後の空判定を維持 |
| 2.1 | 既存。SC:761でplaceholderを公開、最小化は:995以降 | **Constraint** 候補補完の終了を表示の前提にしない |
| 2.2 | 部分。SC:698のpending切替と背景処理 | **Missing** 切替の受付後も最新の最小化要求が残る保証。最小化のbusyを切替拒否へ転用しない |
| 2.3 | 部分。SC:876でLoaded相当を表示、:1153まで最小化busyなし | **Missing** 保留・候補補完・実行・完了の表示上の意味。読込み完了と外部操作完了を区別 |
| 3.1, 3.2, 3.3 | 部分。SC:1148で別の最小化中ならreturn | **Missing** 手動・自動共通の最新要求保持と終了後の排出。A→B→Cの収束保証 |
| 3.4 | 部分。自動はSC:1171にguard、手動:1054と:1662にはなし | **Missing** busy・status・候補/接続更新を現在の操作へ限定。古い完了で現行処理を解除しない |
| 3.5 | 未対応。SC:2000と:2013は同期ループ | **Missing** 操作間の失効確認。**Constraint** 実行途中の同期AX呼出を取り消す保証はしない |
| 3.6 | 部分。登録窓の復元ループSC:2013は存在 | **Missing** 最新要求が取りこぼされず、その時点の登録集合で復元する保証 |
| 4.1 | 部分。合成参照とID等の一致で保護 | **Missing** 背景復旧・再接続後の実ウィンドウ情報を保護判定へ反映。SC:989の固定情報をそのまま使わない条件 |
| 4.2 | 既存資産。SC:2013で利用可能な最小化済み登録を復元 | **Constraint** unavailable/reconnectingと生きた登録を区別。再計画時の最新状態を確認 |
| 4.3 | 既存。最小化ループに登録解除はない | **Constraint** 取得・操作失敗を登録解除や別アプリへの付替えにしない |
| 4.4 | 既存。SC:2083以降のTerminal/曖昧保護とVS Code例外 | **Constraint** 一括削除や保護範囲の暗黙変更をしない |
| 4.5 | 既存。SC:389、:400は同一構成内の選択だけ変更 | **Constraint** 選択イベントを新たな自動最小化要求へ変えない |
| 5.1 | 既存。SC:2005、:2022で窓ごとにcatchして続行 | **Constraint** 新しい中断機構で単一窓の失敗を全体中断と混同しない |
| 5.2 | 部分。SC:2186で失敗合計をstatusへ表示 | **Missing** 最新結果としての集計・公開。古い手動結果や復旧メッセージとの上書き整理 |
| 5.3 | 未対応。AX:496で失敗を空配列に変換 | **Missing** 取得失敗と正常ゼロ件を区別するAX側診断または結果伝達。部分成功の扱いも要設計 |
| 5.4 | 未対応。SC:1172のguardは:1180の履歴追加より前 | **Missing** 実行済み成功の記録を世代失効で落とさない。履歴保存とUI適用の分離 |
| 5.5 | 既存資産。SC:1095の明示復元 | **Constraint** 既存の復元入口を維持。状態不明と復元済みを混同しない |
| 5.6, 5.8 | 既存。SC:2001で最小化済みなら操作・成功追加をskip | **Constraint** no-opを失敗や今回の新規最小化成功にしない |
| 5.7 | 部分。SC:1114は最小化中の失敗を残す | **Missing** AX状態読取失敗時にfalse扱いで履歴を失わない方針。**Unknown** 状態不明の保持条件 |
| 6.1 | 部分。共通Sessionだが入口の候補条件は異なる | **Missing** 共通の最小化候補・保護規則。入口固有の保存位置や前面化は統一対象外 |
| 6.2 | 既存資産。最小化ループは保存ストアへ書き込まない | **Constraint** 切替前の既存保存経路と本機能の操作を区別。所属・順序・配置を変えない |
| 6.3 | 既存。SC:752、:945、:964で自動復旧を制御 | **Constraint** 候補補完のためにopen/activate/pollを追加しない |
| 7.1 | 未対応。保護判定はBoolで理由・内訳なし | **Missing** 候補数と登録/同一アプリ保護の分類結果 |
| 7.2 | 部分。成功配列と失敗合計はあるがno-op内訳なし | **Missing** 成功/既達成/失敗の分類。AX:265の読取不能false変換を診断上区別 |
| 7.3 | 未対応。処理時間・開始イベントのみ | **Missing** 対応する切替の識別と打切り/引継ぎの記録 |
| 7.4 | 既存。Debug LoggerでUIに診断確認を要求しない | **Constraint** 調査用情報を通常操作の必須手順へ露出させない |

## 4. 統合上の重要ギャップ

### 4.1 候補の網羅性と値の鮮度は別問題

登録ウィンドウが見つかることは、未登録候補が揃っている根拠にならない。Launcherの候補には8秒の期限がある（`WindowBoardAppState.swift:136`）が、その間の新しいウィンドウ作成を否定できない。TTLだけを網羅性の証拠にしない。

さらにSC:2200の `mergeWindows(new, into: cached)` は同じIDを更新しない。SC:824は古いキャッシュ側を基底にするため、再列挙しても同一IDのAX要素・タイトル等に新しい値が採用されない場合がある。候補補完で件数を増やすだけでは不十分である。

比較対象は、(a) 最小化用途に限定した新しい列挙結果優先の統合、(b) 共通mergeの意味変更。後者は画面や他機能の呼出箇所への影響が広い。閉じた古い候補を残すか、正常な全列挙と部分失敗の結果をどう統合するかも設計事項となる。

### 4.2 最新要求・実行中操作・UI結果の有効性

読み込み中の `pendingWorkspaceSwitch` を最小化待ちへそのまま流用すると、読込みと後処理の状態が混ざる。Sessionが最新の最小化要求を扱う意味を別途定義する必要がある。

手動処理は準備時点の登録を取り込み、SC:1059で世代確認せず現在の登録へ戻す。実行完了SC:1662も無条件にbusy/statusを更新する。自動処理だけの直列化では準備中・完了時の競合が残る。

外部操作開始後の完全取消はできない。開始済みの操作結果は回収し、次の操作を止め、最新の有効要求で整える。最新要求がOFFや空構成の場合にも過去の処理を失効させる一方、新しい自動最小化・補償復元を勝手に追加しないという現在の要件境界を守る。

### 4.3 物理的な操作記録と復元履歴

自動処理は古い世代の結果を捨てる際に成功履歴も捨てる。逆に手動処理は成功履歴と一緒に古いUI結果も無条件適用する。実際の副作用を保存する条件と、現在の画面へ結果を公開する条件の分離が必要である。

明示復元はSC:1100で履歴を取得し、:1124で失敗分の配列へ全置換する。その間に追加された最小化成功を消し得る。復元操作の優先順位を新設するのは本仕様外だが、5.4の記録保持を壊さない差分更新・直列化の境界は検討が必要である。

### 4.4 背景復旧と保護対象の更新

自動復旧はSC:945/:964から別Taskで走り、:1438で同じ登録IDの実ウィンドウ情報を差し替える。最小化は:989の初期解決結果を使うため、復旧済みの新しいウィンドウが未登録として扱われる可能性がある。これは静的に確認した競合可能性であり、実機で発生確認済みではない。

候補補完とともに現在の登録集合・再接続中状態を読み直す時点、復旧完了後に必要な再評価、同じBoard内の登録変更を扱う範囲を設計で決める。常時監視や復旧方式そのものの再設計へ範囲を拡大しない。

### 4.5 エラーを区別できない既存インターフェース

`listWindows() -> [WindowInfo]` は部分失敗を含めて配列しか返さず、`isMinimized() -> Bool` は読取失敗をfalseへ潰す。5.3は「失敗を検出したとき」の診断要件であり、Sessionのログだけ増やしても既に失われた情報は再構成できない。

比較案は、(a) AXサービス内で失敗を構造的に診断し既存戻り値を保つ、(b) 列挙の部分成功・失敗、状態の不明を返す追加APIを設け既存APIを互換ラッパーにする、(c) protocol全体の戻り値を変更する。診断だけなら(a)も候補だが、状態不明時の履歴保持やSessionの判断には(b)/(c)の利点がある。

互換デフォルト実装を使う場合、単に既存配列を「完全成功」と包んで網羅性を偽装しない。影響先はSnapshot、Recovery、Launcher、Tree、fakeサービスにも及び得るため、最小化向けの追加能力として限定する方法を比較する。

### 4.6 完了の意味とコールバック

読み込み結果のLoaded表示と最小化完了は現在別々で、150ms待機中には最小化busyが立たない。2.3を満たすには、表示上の読込み完了とウィンドウ操作の未完了を区別する必要がある。

`minimizeAfterSwitchCompletion` は名前に反して最小化前に呼ばれ（SC:991）、ContentView:1244でBoardを前面化する。名称だけを見て真の完了通知へ移すと前面化の順序を変える。互換性を確認し、既存の前面化用途と新しい完了表示の通知を分けるかを設計で扱う。

## 5. 実装アプローチの比較

ここでのA/B/Cは**実装の分割方法**であり、Discoveryで採用済みのB案「最小化の実行管理を整える」を撤回する比較ではない。

| 案 | 内容と変更候補 | 利点 | 課題・互換性 |
| --- | --- | --- | --- |
| A：既存コンポーネントを拡張 | SC内に最新要求・操作識別・実行結果を追加。AXサービスの診断または結果APIを補う | 現在の切替制御に近く、新しい抽象化が少ない | SCは約2,262行。準備・実行・結果・履歴がさらに集中し、純粋判断の単体検証が難しくなる |
| B：狭い実行コンポーネントを新設 | 最小化計画・操作結果・失効確認を扱う専用型/実行部を設け、Sessionから要求して結果を戻す | 操作順・取消・失敗分類を独立して検証しやすい | 別のセッション状態所有者を作らないインターフェースが必要。Scene/Storeや直接AX要素操作を持たせない |
| C：ハイブリッド | Sessionに最新要求・busy・履歴・UI適用を残し、純粋な判定/計画と背景の操作実行だけを分離。AX境界には必要な診断能力を追加 | 既存Coordinator/Resolverパターンに沿い、共有状態を増やさずテストの境界を作れる | 候補/登録集合の有効性と実行結果の受渡しを慎重に設計する必要がある |

**設計へ持ち込む第一候補はC**。既存状態所有を守りつつ複雑な操作部分のテスト可能性を確保しやすいためであり、採用を確定するものではない。具体的な新規ファイル名・公開API・クラス配置は未決定。

どの案でも既存UIからの入口は維持し、位置保存・Status Itemの非表示切替・Launcherの座標復元を変えない。永続データ移行は不要。実装を段階化するなら、まず制御可能なfakeと失敗情報の検証境界、次に要求管理と操作結果記録、最後に候補補完・表示・診断を統合する。独立した不完全機能を途中リリースする意味ではない。

## 6. テスト資産と不足する検証

既存テストの存在は確認したが実行していない。

| 既存資産（WindowMatchingTests） | 活用と不足 |
| --- | --- |
| testLauncherSwitchUsesCompleteCandidateCacheWithoutListingWindows | 自動最小化OFFの高速経路を保護。ONで未登録候補が増えるケースは別に必要 |
| testLauncherCachedSwitchPublishesPlaceholderBeforeDeferredLayoutApplication | 表示先行の基盤。最小化候補補完を遅延させた検証へ拡張可能 |
| testNewerSwitchRemainsActiveWhenPreviousResolutionFinishesLater | 解決処理の古い結果を排除する基盤。最小化操作途中の取消・履歴の証明ではない |
| testMinimizeUnattachedProtectsOnlyAttachedWindows | 手動の登録保護・履歴。Terminal・同一アプリ別窓・合成構成・自動経路は追加が必要 |
| testRestoreKeepsOnlyWindowsThatCouldNotBeRestored | 明示復元の失敗保持。状態読取失敗や処理中の新規履歴追加は別途必要 |
| testSwitchDoesNotStartAutomaticRecoveryWhenRestoreMissingIsDisabled | 最小化補完でもopen/activateを増やさない回帰確認に利用 |

`minimizeUnattachedOnWorkspaceSwitch` のテスト内参照は検索で見当たらず、ONにした自動処理の明示検証が不足している。

追加する検証の候補:

1. 登録窓はキャッシュで解決済みだが、後から開いた対象窓がサービス一覧にのみ存在する。ON時に試行され、OFF時には本機能用の追加列挙をしない。
2. 同一IDの新旧WindowInfoで新しいAX要素や情報を採用し、無効なキャッシュ側を残さない。切替中に得た適切な一覧は重複取得しない。
3. Aの最小化中にB→Cへ切り替える。操作を止められる区切りを越えて旧操作を続けず、Cの登録保護・復元・対象試行が最終状態に反映される。
4. 手動の準備中・実行中・完了直前で切り替える。最新要求を失わず、古い結果で接続情報・busy・statusを戻さない。
5. 実行済み最小化成功は要求失効後も履歴へ残る。明示復元中に別の成功が記録されても失わない。
6. 個別の最小化/復元失敗後も他対象を続行する。既に目的状態の窓と失敗窓を区別し、元から最小化されている窓を新たに履歴へ入れない。
7. 正常ゼロ件・アプリ単位部分失敗・全取得失敗、最小化状態の読取不能を区別する。
8. 復旧により同一登録IDが新しい実ウィンドウへ置き換わった場合、新しい窓が誤って未登録扱いにならない。
9. 同じ集合・設定・窓状態を主画面/Status Item/Launcherへ与え、同じ最小化・保護方針を適用する。入口独自の表示・保存挙動は別に維持する。
10. Terminal保護・VS Code例外・全構成が空/追加Boardだけ非空・同一構成内選択・自動復旧OFFを維持する。
11. Loaded相当の表示、候補準備、保留、実行、失敗を伴う完了と、診断での切替識別を検証する。

fakeには列挙の失敗結果、状態読取不能、最小化/復元別の失敗、操作開始/完了を制御する同期ゲート、操作イベント記録が必要となる。sleep時間だけで競合を再現しない。現fakeは可変状態を共有するため、並行テスト自体のデータ競合を防ぐ必要がある。

## 7. 工数・リスク

- **Effort: M（3〜7日相当の概算）**：既存資産と技術で実装可能だが、手動/自動の要求管理、AX失敗の伝達、履歴更新、制御可能な並行テストの追加が必要。実測・納期の約束ではなく、実機固有問題や要件変更によって増える。
- **Risk: Medium**：未知の外部依存や保存移行はないが、誤最小化・復元不能・古い結果の上書きへつながるタイミング依存の統合リスクがある。同期AX呼出とアプリ個別挙動の検証を要する。
- **互換性**：保存モデル・既存設定名・既定値を維持。protocol変更はSnapshot/Recovery/Launcher/Tree/fakeへ波及し得るため、最小の追加能力と互換ラッパーを比較する。
- **回復性**：最小化成功の台帳保持と単一失敗後の続行が中核。コードの巻戻しで実ウィンドウ状態まで自動で戻るとは仮定しない。

## 8. Research Needed：設計フェーズへの引継ぎ

| ID | 未確定事項 | 確認方法・判断に必要な材料 |
| --- | --- | --- |
| RN-1 | 候補の取得範囲・世代・時点をどう表すか、何を再利用し何を補完するか | cache-only/今回列挙済み/部分失敗のケースを分け、要求ごとの一覧取得回数と鮮度を検証 |
| RN-2 | 最新要求と実行中操作・保留要求の識別、OFF/空構成への失効 | 状態遷移表と同期ゲート付きfake。最小化前後の全完了経路が保留要求を処理することを確認 |
| RN-3 | AXの診断・結果付きAPI・互換範囲 | サービス内ログ案と追加API案を比較。全ゼロ/部分成功/失敗/読取不明を偽装しない |
| RN-4 | 「実際に最小化した」成功判定と履歴の扱い | AX書込成功と事前状態、必要に応じた事後状態確認を比較。読取遅延・失敗と追加コストを実機で確認 |
| RN-5 | 履歴更新の粒度と同時復元による消失防止 | 成功の追加と復元成功の削除をID単位で追跡する案、完了順序の制御を比較。手動復元の新しい優先順位は勝手に追加しない |
| RN-6 | 背景復旧・登録変更で保護情報が変わる時点 | 再接続前後の登録ID/実窓IDを追跡し、固定snapshotの更新・再計画条件を検証 |
| RN-7 | 完了表示と既存前面化コールバックの意味 | 2.3を切替後の対象処理に適用し、従来の位置適用・背景復旧・前面化の順序を壊さない表示を設計 |
| RN-8 | 実際の報告原因、アプリごとのAX挙動 | 可能になった時点で自動最小化設定、残るアプリ、同アプリ別窓の登録有無、入口差、連続切替有無を実機確認 |

要件の修正が直ちに必須となる矛盾は見つからない。ただし2.3をすべての背景復旧の完了まで含む全体進捗UIへ拡大しないこと、5.3の「検出した取得失敗」とOSがそもそも公開しない窓を区別することを設計で明文化する。未確定の性能数値や完全制御保証を追加しない。

## 9. 調査方法と変更範囲

- kiro-validate-gapの枠組みで、Session/WorkspaceとAX/Regressionを読み取り専用で並列調査し、主担当が全33基準を統合照合した。
- 核となるSteering、現行要件・メタデータ、AGENTS.md、関連コードとテストを使用。次期設計や仮データ試作の機能を通常版実装の根拠にしなかった。
- 新規ライブラリや新しい外部サービスの評価を伴わないため、外部Web調査は行っていない。OS挙動に関する未確認事項はResearch Neededへ残した。
- この実行で保存するプロジェクトファイルは本research.mdのみ。要件承認、設計生成、コード変更、ビルド・テスト実行は行わない。

---

# 設計Discovery・Synthesis記録（2026-10-20）

## Summary

- **Feature**: board-switch-minimization
- **Discovery Scope**: 既存機能の拡張。最小化のタイミング依存とAX結果境界の互換性を考慮し、lightの統合点調査からfull相当の契約・リスク調査へ拡張した。
- **Key Findings**:
  - 読込みrevisionだけではpending受付時に旧処理を止められない。最小化用intentを受付時に発行し、読込み中キューへ継承する必要がある。
  - 列挙失敗とfalseへの変換を既存AX境界で区別する必要があり、診断付きの追加メソッドとlegacy互換実装を採用する。
  - 古い要求の物理成功とUI更新は別契約。台帳entryVersion付きの差分更新を使い、明示復元にも一窓ごとの記録を適用する。
  - 新しい実行部へ状態所有を移さず、純粋判定・一要求の実行だけを抽出できる。新規外部依存・保存移行は不要。

## Research Log

### 使用したスキルと既存規約

- **Context**: 通常版の既存機能を設計し、次期平坦グループや試作の実装を混同しない。
- **Sources Consulted**: kiro-spec-designのprinciples/discovery-light/discovery-full/synthesis/review-gate、仕様テンプレート、AGENTS.md、3件のSteering、requirements.md、既存research.md。
- **Guidance Used**: 境界先行、33基準への追跡、状態所有の一本化、AX背景実行、具体的ファイル境界、設計前の主担当によるSynthesis、保存前レビュー。
- **Domain Skill**: build-macos-apps:window-management。自身のSceneの復元・起動と外部ウィンドウ操作を区別し、macOS 15以降のScene用APIを14.0対象へ導入しない判断に用いた。Scene/UI外観を変更しないため、同スキルのUI実装・起動検証工程は今回の文書作成には適用しない。

### 受付世代と既存キュー

- **Sources Consulted**: WorkspaceSessionController.swiftのswitchWorkspace、pendingWorkspaceSwitch、requestMemberSelection、手動最小化準備・完了。
- **Findings**: 読込み中の要求はrevision更新前にキューへ入る。同一targetは選択だけ継承する分岐がある。手動準備と完了には現行世代の検査がない。
- **Implications**: 切替受付で最小化intentを発行。queued内部再投入は同ID・受付時設定を引継ぎ、同一target採用時も最新の設定・source・callbackへ結び直す。手動は現intentへbindし、新しい切替や完了済み自動要求を発行しない。

### AX契約と取消

- **Sources Consulted**: AccessibilityWindowService.swift、ローカルSDKのAXUIElement.h（CopyAttributeValue 132–148行、SetAttributeValue 207–223行、MessagingTimeout 387–402行）、下記Apple公式資料。
- **Findings**: AX読取/書込は同期のAXErrorを返す。属性未対応・無効要素・メッセージ失敗等を区別できる。Swift Taskの取消は協調的で、呼出側cancelだけでは任意の同期処理は止まらない。
- **Implications**: 列挙後、状態読取前、書込直前にMainActorで有効性を確認する。確認直後に始まった一呼出はinflightとして回収し、その成功receiptは失効後も保存する。全体AX timeoutやOS設定を変更せず、UIの非ブロックと次workerを重ねないことを優先する。
- **Source Limits**: Appleの現行ページ本文は一部JavaScript依存で取得不能だった。取消の詳細は公式検索結果本文で、AX署名・エラーはSDKヘッダと現行ソースで確認した。実機の応答時間・操作成功は未確認。

### 候補と再接続

- **Sources Consulted**: SessionのmergeWindows、applyDeferredRecovery、復旧Taskの起動箇所、ApplicationWindowCatalog。
- **Findings**: 同IDの古いキャッシュがmergeで残る。初期snapshotは復旧後の新しい実窓を反映しない。旧実窓を保護してskipした後に新実窓へ再接続すると、旧実窓が未登録のまま残る場合もある。
- **Implications**: 同intentのreport再利用、cache-only時の追加取得1回、新しいreport優先、完全取得では古いキャッシュを除外する。保護fingerprint変更時は既存候補全体を再分類する。遅い既存自動復旧には限定reconcileを使い、候補集合は増やさず新規全列挙もしない。

### テストとtarget membership

- **Sources Consulted**: project.pbxproj、WindowMatchingTests.swift、AttachedWindowSnapshotCoordinator。
- **Findings**: Xcodeは明示的なSources登録。WindowInfoとAXサービスはTreeと共有。既存private fakeは可変状態の同期がなく、完成済みreportを注入するだけでは本番のAX分類を検証できない。
- **Implications**: 共通結果型だけTreeへ登録。新fakeはlockと同期gateで制御し、テスト本体はMainActorをブロックしない。本番のCF値/エラー変換とreport純粋集約を直接テストする。busyの準備/保留への拡張ではSnapshotの停止・再開を検証する。

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Decision |
| --- | --- | --- | --- | --- |
| Sessionだけ拡張 | 新要求・分類・実行を既存ファイル内へ追加 | 構造変更が少ない | 約2,262行のSessionへさらに集中、単体検証境界が弱い | 不採用 |
| 独立Coordinatorへ状態移管 | 新機構が要求・台帳も管理 | 単体で閉じやすい | Sessionとの二重所有・切替経路の分断になる | 不採用 |
| ハイブリッド | Session所有を保ちPolicyと一要求Executorを抽出 | 既存境界に適合し制御可能なテストを作れる | permitとreceiptの契約が必要 | 採用 |

## Design Decisions

### Decision: 受付世代・実行枠・最新要求をSessionへ集約

- **Generalization**: 自動最小化と手動最小化の重複は、同じ「古い準備/実行/完了が現行へ作用する」問題として扱える。
- **Selected Approach**: intentIDとoperationIDを分離し、最大一worker・最新自動pending一件を保持。全終了で共通finish/drain。OFF/空も失効だけ行う。
- **Rationale**: 既存の読込みキューを最小化待ちへ流用せず、セッション状態の所有を増やさない。
- **Trade-offs**: 新しい値型と状態投影は増えるが、UIごとの例外や汎用タスクキューは作らない。

### Decision: 診断付き取得を互換追加

- **Alternatives Considered**: サービス内ログのみ、既存protocol全面変更、結果付きメソッドの互換追加。
- **Selected Approach**: listWindowsReportとminimizedObservationを追加。本番は正確な結果、既定実装はunverifiedLegacy/legacyとして能力差を明示する。
- **Rationale**: ログだけでは状態不明時の履歴保持をSessionが判断できない。全面変更は他経路へ不要に波及する。
- **Follow-up**: 旧利用者のBool/配列の意味が変わらないこと、正常ゼロと部分/全失敗を本番集約関数で検証する。

### Decision: 協調的なpermitと必達receipt

- **Selected Approach**: read前とwrite直前のpermit確認。permitはidentityと台帳versionを持つ。成功receiptをMainActorへawaitしてから次へ進む。
- **Rationale**: cancelだけの即時停止保証は成立しない。操作途中の一回を回収する構成で、古い成功記録の喪失を防ぐ。
- **Trade-offs**: 操作ごとの短いMainActor往復を許容する。AX呼出は含めず、未測定のms目標を追加しない。

### Decision: 固定候補の限定reconcile

- **Selected Approach**: full pendingをreconcileで置換しない。reconcileは同intentが自動ON・非空としてmaterialize済みの場合に限り、同切替の既存自動復旧完了から要求する。保持済み候補を再分類し登録復元を確認する。
- **Rationale**: 再接続で旧登録窓が未登録になる場合も最終集合へ整えられる。全列挙・新窓監視を増やさない。
- **Trade-offs**: 次の切替まで最新候補snapshotを保持する。集計はintent内で累積し、新しい確認で過去の失敗件数を消さない。

### Decision: 台帳はversion付き差分更新

- **Selected Approach**: 最小化前の正常false＋AX書込successを記帳。明示復元も一窓ごとに記録し、entryVersion一致時だけ削除。unknownと復元失敗は保持。
- **Rationale**: 事後読取成功を必須にすると実際の書込成功記録を失う。バッチ配列全置換は並行追加を消す。
- **Trade-offs**: AX書込成功は画面アニメーション完了とは別。明示復元に新しい優先順位は導入しない。

### Decision: Build vs Adoptと簡素化

- **Adopt**: 既存Swift Concurrency、MainActor、AXサービス、Combine、OSLog、XCTestのパターンを利用する。追加パッケージ・OS新APIは導入しない。
- **Build**: Board登録保護に特有な純粋Policyと一要求Executorのみを作る。汎用の外部ジョブ/リトライ/ワークフロー製品は既存Session境界に適合する必要があり過大なため採用しない。
- **Simplification**: 新しい常駐Coordinator、別の状態ストア、全AX操作の全体直列化、全クラスのMainActor化、保存移行、恒久監視を除外した。
- **Isolation Compatibility**: 新状態へ同期で到達するSessionの該当メソッドとStatus Itemを明示MainActor化し、既存の該当テストもメソッド単位で合わせる。非隔離の呼出元からの暗黙呼出を前提にしない。

## Risks & Mitigations

- AXが戻るまで次workerは開始できない。UIは背景実行で維持し、無制限の並列AX操作で回避しない。
- legacy fallbackは診断能力を保証しない。本番は新メソッド実装を必須とし、新fakeも新契約でテストする。
- MainActor直前確認と同期AX開始の間は原子的にできない。inflight分を回収し最新適格要求で整える。
- 比較用fingerprint変更時の再評価は、同じ候補/結果を二重計上しない。後日の窓監視へ拡大しない。
- 保存形式は変えないがUI状態のbusyはSnapshotに影響する。保留/準備/中断/完了で停止と再開を検証する。
- 実際に残るアプリ、AX成功後の表示遅延は未検証。実装後は通常版で入口別・連続切替・保護対象を実機確認する。

## Review Gate

主担当がSynthesisと正準33基準の追跡を実施。機械チェック後、SessionとRegressionの読取専用レビューを受け、局所修正を2回以内で反映した。追加したpermit、同target受付情報、限定reconcile、台帳即時差分、本番変換のテスト境界、MainActor呼出元を確認した。真の要件矛盾は見つからず、要件本文を変更せず設計を確定できる。設計承認・実装着手は別段階とする。

## References

- [Apple Task.cancel](https://developer.apple.com/documentation/swift/task/cancel%28%29) — 協調的取消と同期処理の継続。
- [Apple AXError](https://developer.apple.com/documentation/applicationservices/axerror) — 公開AXのエラー分類。
- [AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) — AX属性書込契約。
- ローカルmacOS26.5 SDK `ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXUIElement.h` — 既存AX APIの署名・読取/書込失敗・タイムアウトの適用範囲を確認。対応OSを26.5へ変更する意味ではない。
- `AGENTS.md`、本仕様のrequirements.md、既存research.md、上記ソース/テスト — 現行実装と境界の根拠。

本フェーズでコード変更・ビルド・テスト・実機操作は行っていない。
