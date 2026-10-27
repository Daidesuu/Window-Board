# WindowBoard Application Requirements

2026/10/13 — 次期UIの承認済み方針。アプリ本体は旧構成のままであり、本書への変更は実装完了を意味しない。


## 2026-10-13 UI試作で承認した変更

- 並列表示中のメンバーBoardに選択・操作対象の強調を付けず、全メンバーを対等に表示する。サイドバーの表示中チェックはグループ全体または単独Boardだけを示す。選択中は通常の単独タブと同じ青背景をグループ全体に付け、未選択時は透明にする（2026-10-14追加）。
- サイドバーは文字だけでなくタブ・行の余白を含む全領域をクリック可能にする。同一グループ内のどのタブを押しても表示対象は同じで、隠れた追加先を切り替えない。
- Add WindowとBoard設定・配置保存・全参照解除は各キャンバスの明示的な所有Boardへ適用する。共通ツールバーのFocus・Restore Layout・Minimize Othersは表示中の全Boardへ適用する。カード操作は常にカードの所有Boardへ適用する。
- 以前の本文にある「操作対象Board」「focusedBoardID」、メンバー選択の強調、選択中メンバーを既定の追加先にする経路は旧案であり、この変更を優先する。表示対象の選択と操作ごとの明示所有者を分離する。右隣・左隣への操作対象移動も新UIでは不要となる。
- 現段階は仮データ試作のみ。本番セッション、Status Item、ランチャー、移行処理への接続は後続工程で本方針に合わせて見直し、今回変更しない。

## UI試作の確認（工程2）

`./script/build_and_run.sh --prototype --verify` で仮データ専用の分割UIを開く。生成される `dist/WindowBoardPrototype.app` はダブルクリックでも試作モードで起動する。既存ビルドからの起動確認は `./script/build_and_run.sh --prototype --launch-only --verify` を使う。本番アプリは終了しない。通常起動のUIは旧構成のまま維持する。試作では保存データ・本番セッション・Status Item・ランチャー・Accessibilityを初期化せず、操作はメモリ内の仮データだけに反映する。終了すると試作の変更は失われる。既存サイドバー・ツールバー・カードの見た目を保ち、カード表示領域だけを左右に分割する。仮の「作業＋資料」並列グループと単独「個人」Boardを切り替え、左右独立スクロール、既存カードサイズ、表示対象全体の選択表示とBoard別操作の区別を確認する段階であり、新形式への移行は行わない。

### 仮データのドラッグ＆ドロップ試作（2026-10-14）

- Boardタブの並列化・所属移動、カードのBoard間移動・同Board内並べ替え・専用領域への解除、およびメニューによる代替を実装する。
- New Boardで空の仮Boardを追加でき、最大4個の構成と5個目の拒否を確認できる。1／2／3／4個のキャンバス配置を切り替える。
- 動作はPrototypeBoardDragModelのメモリ内に限定する。参照ID・仮保存配置を保持し、処理中・重複・古いdrag session・二重確定を拒否する。PrototypeメニューのFail Next Saveで仮保存失敗を再現できる。
- 本番のWorkspaceSessionController、保存ストア、AX操作、新保存形式・移行処理には接続しない。終了／Reset Demoで仮データを初期状態に戻す。

## 1. Purpose

WindowBoardは、外部アプリのウィンドウ集合を独立した **Board** として保存し、ブラウザのタブに近い操作で切り替え、統合時にはBoardごとのキャンバスを分割表示するmacOSアプリとする。

外部アプリのウィンドウは埋め込まない。キャンバスはウィンドウカードの操作画面であり、外部ウィンドウの移動・サイズ・最小化・復旧は公開Accessibility APIによるbest-effort操作である。内部のWorkspace型の一括改名は行わない。

## 2. Platform and Prerequisites

- SwiftUIと限定的なAppKit連携を使うネイティブmacOSアプリ。Dock、Status Item、既存ランチャーを維持する。
- 外部ウィンドウ操作にはAccessibility許可が必要。許可なしでもアプリは起動できるが、外部操作はできない。
- フルスクリーン・別Space・システムウィンドウの制約は従来どおりとする。
- 本変更では署名、配布、Sparkle、対応OSの変更を行わない。

## 3. Concepts and Terms

| 用語 | 意味 |
| --- | --- |
| Board | 名前、安定ID、保存済みウィンドウ参照とレイアウトを持つ独立した集合 |
| Boardタブ | 保存済みBoardへの入口。単独または分割グループ内に一度だけ表示する |
| 分割グループ | 順序付きBoard IDの平坦な集合。グループ自体はウィンドウを所有しない |
| Boardキャンバス | 一つのBoard専用のカード表示・操作領域 |
| 表示対象 | 単独Boardまたは分割グループ |
| 操作先Board | キャンバス・メニュー・カードから各操作へ明示する所有Board。メンバー選択状態は持たない |
| Permanent Board | 削除・改名不可の既存Board。通常の統合・解除は可能 |
| Attached Window / Window Reference | 生存・placeholder状態と保存済み参照。所有者は常にBoard ID |

「子Board」「Primary Board」「Included Board」「Current Boardの階層」は新しいユーザー向け概念から廃止する。以降の既存仕様に残るCurrent Boardは表示対象全体、owning Boardは参照を所有するBoardを意味する。

## 4. Board Persistence

- Board ID、名前、検索別名、Status Item表示、作成・更新時刻、ウィンドウ参照・カード順・保存座標・サイズを維持する。
- 名前・設定・所属・ウィンドウ追加／解除・カード順は自動保存する。明示保存が必要なのは復元用の位置・サイズ・相対オフセットだけとし、Board全体を未保存状態にしない。
- 復元用レイアウトと現在位置のsnapshotを分離する。タブ切り替え・退出・Follow・定期snapshotでは復元用レイアウトを上書きせず、対象を明示したSave Layout／配置保存・上書きでだけ更新する。新規追加時の初期配置記録は例外とする。
- 読み取れた現在配置と保存配置に意味のある差がある場合、対象カードとBoardに「配置が未保存」を表示する。Unavailableなど現在値が不明な状態を差分とみなさず、読み取り失敗で保存配置を消去しない。
- Boardは独立して作成、保存、改名、削除できる。新規Boardは単独タブとして作成・表示する。
- Boardの統合は内容のコピーや移動ではなく、表示グループへの所属変更である。
- 一つのBoardは同時に一つの分割グループだけに所属できる。グループは2〜4個まで、グループ非所属のBoardは単独タブになる。
- 保存済みBoardをタブから隠す「閉じる」操作は初期段階では設けない。タブ解除とBoard削除を混同しない。
- ウィンドウのUnavailable、Minimized、Reconnectingなどの状態、明示的な復旧、所有者へのSave Layoutは維持する。
- Permanent Boardの削除・改名禁止と保存済みウィンドウは維持する。全Boardへの自動共通追加は廃止し、必要なときだけ通常の統合操作でグループに含める。

## 5. Flat Split Groups

### 5.1 統合と解除

- 親子、入れ子、再帰的なグループは作らない。
- 単独Boardを別Boardへドロップすると、追加先、追加元の順で分割グループを作る。位置による意味の違いはない。
- グループに追加すると末尾へ入る。所属済みBoardの場合は元グループからそのBoardだけを移し、他メンバーは維持する。
- 4個のグループへの追加は拒否して理由を表示する。検証は移動元を変更する前に行い、拒否時には両グループ・選択・保存状態を変更しない。
- 同じグループへの再追加・自分自身への追加・存在しないIDは変更せず理由を表示する。
- グループを丸ごとドラッグする操作と並び替えは初期段階の対象外。
- どのメンバーも「グループから外す」で単独タブに戻せる。Primaryの特権は設けない。
- 残り一つになったグループは解除して単独タブに戻す。残りゼロのグループは削除する。
- 解除ではBoardとウィンドウを削除しない。Board削除では当該Boardと所属参照だけを除去し、外部アプリのウィンドウは閉じない。
- 解除・所属移動・削除では表示中の元グループを維持し、残り一つならその単独Boardを表示する。単独の表示Boardを削除した場合はPermanent Boardへ戻す。メンバー個別の操作対象や右隣・左隣への選択移動は設けない。
- 所属変更は一回の保存として扱い、表示と所属だけを更新する。外部ウィンドウの移動・最小化・復旧・前面化は行わず、タブ切り替えの配置復元経路を呼ばない。

### 5.2 選択と操作範囲

- タブを選ぶと、そのBoardを含む表示対象全体を表示する。同じグループのどのタブを選んでも表示と操作先の既定値は変わらず、メンバー個別の選択を持たない。
- タブ・キャンバス選択だけでは外部ウィンドウを前面化しない。同じ表示対象内のタブ選択は変更もAXもなし。別表示対象への切り替えは配置を復元するが、暗黙の前面化はせず、前面化は明示操作へ分ける。
- キャンバスの追加、Board設定、改名、保存、ウィンドウ移動は明示したBoardだけに作用する。
- 追加・保存・Board設定は各キャンバスまたはBoard名を明示したメニューから行う。共通ツールバーに最後のクリック先へ作用する追加・保存操作を置かない。
- 全体のFocus、Restore Layout、Minimize Others、Followは表示対象全体に作用する。個別キャンバスのFocus、Restore LayoutはそのBoardだけに作用する。
- 同じライブ外部ウィンドウが複数の保存参照に一致しても、各Boardの参照・カードは保持し、グループ全体のAX操作だけを一度にする。配置・Followが競合する場合はメンバー順で最初の参照を採用し、個別Restoreでは対象Boardの保存値を使う。
- 共有ライブ窓の移動・最小化・復旧結果は対応する全カードの実行時状態へ反映する。配置保存とDetachは操作したBoardの参照だけに作用し、他Boardの保存配置・参照を変更しない。
- サイドバー、Status Item、ランチャーは同じ表示対象状態と切り替え経路を使う。

### 5.3 既存データの移行

- 変更前データをバックアップし、旧子Boardは並列メンバーとして平坦化する。Board ID、参照、名前、カード順、ウィンドウのレイアウトは維持する。
- 共有された子・並列メンバーは連結した平坦グループの候補としてプレビューする。2〜4個の候補は確認して統合するか、候補全体の関係を解除して単独タブに戻すかを選べる。4個を超える候補は単独タブ化を明示して確認し、勝手に分割・切り捨て・適用しない。Boardとウィンドウは保持する。
- 旧globalRootの自動共通追加は廃止する。対象Boardと保存済みウィンドウは保持し、明示された所属関係がなければ単独タブへ戻す。明示された関係がある場合だけその平坦化グループへ所属させる。自動共通追加を全Boardとの統合関係へ変換しない。
- 移行プレビューでは共通追加の解除を明示する。移行後、そのBoardのウィンドウは当該Boardまたは所属グループを表示するときだけ全体操作の対象となる。
- 移行失敗・キャンセルでは旧データを維持する。新形式の読み込み成功後もバックアップを残す。
- 「移行前へ戻す」を用意する。復元前に現在データも検証済みバックアップへ保存し、移行後の作成・編集・削除がアプリ上で巻き戻ることを明示して確認する。新旧データは自動結合しない。復元は外部ウィンドウを操作せず、バックアップ・検証失敗では現状態を維持する。

### 5.4 Board Drag and Drop

- Boardタブ全域をドラッグ元／先にできる。別Boardへ落とすと、そのBoardが属するグループ末尾へドラッグしたBoard一個を追加する。単独同士なら追加先、元の順で2Boardグループを作る。
- 既存グループ間の移動は元から一個だけ外し、元が一個になれば単独化する。同じBoard／同じグループは変更なし、追加後4個超なら元を変えず拒否する。
- Boardのキャンバスドロップ、グループ全体のドラッグ、Board順の並べ替え、空白／アプリ外への解除は初期対象外。解除は明示メニューで行う。
- ホバーで表示対象を切り替えない。所属変更後も現在の表示対象を可能な限り維持し、単独表示中のBoardを別グループへ移す場合だけ所属先を表示する。この再構成でAX配置・復旧・前面化を起こさない。
- ドロップ先・選択正規化・確定処理の詳細は BASIC_DESIGN.md §10 に従う。

## 6. Sidebar Requirements

- 既存の縦タブ風サイドバーを維持する。すべての保存済みBoardを、単独タブまたは所属グループのメンバーとして一度ずつ表示する。
- 分割グループは最大2列で折り返す。列最小96pt、間隔6pt、名前最大2行、全文ヘルプを維持する。
- 未選択グループの背景・外枠と通常時のメンバー塗りは付けない。選択中は通常タブと同じ青背景をグループ全体へ付け、メンバー個別の強調をしない。
- 項目間は1pt・primary 0.12・左右16ptの横線。メンバー間は1pt・primary 0.06の短い縦線と折り返し段間の横線。装飾は入力・Accessibility対象外。
- グループ件数と各Boardの識別を保ち、単独Boardとグループの境界を明確にする。
- Boardドロップは統合・所属移動、ウィンドウカードのドロップは明示したBoardへの参照移動。型と作用範囲を分ける。
- 「子Boardとして追加」、階層用ドロップ、透明な分離領域を廃止する。解除はメニュー操作とする。
- 削除は解除と別操作。Permanent Boardは削除不可、保存済みウィンドウのあるBoardは確認して削除する。

## 7. Split Board Canvas Requirements

- 単独タブは一つのキャンバス、グループはBoardごとの独立したキャンバスを同時表示する。カードを一つの集合へ混ぜない。
- 各キャンバスはBoard名、自分のウィンドウカード、Add Windowと対象限定操作を持つ。メンバー個別のフォーカス状態は設けない。
- 1Boardは表示領域全体、2Boardは左右、3〜4Boardは等幅・等高の2×2配置を基本とする。3Boardは保存順の3枠を使い、残りの枠は非操作の空白とする。通常は全キャンバスを一画面へ収め、各キャンバス内だけでカードをスクロールする。
- 最小キャンバス幅280pt・高さ240pt、間隔12ptを設計既定値とする。二列が収まらない幅では一列へ切り替え、縦方向も最小高さを確保できない場合は狭い表示領域として一列・外側縦スクロールを許可する。その場合も各キャンバス内の高さは有限とし、保存メンバー順に並べ、各ヘッダーへスクロールで到達できるようにする。
- 分割の境界ドラッグ・割合保存・任意配置は初期段階の対象外。
- カードはキャンバス幅に応じて列数を減らす。狭い領域でも名前と復旧・解除・追加の操作を省略しない。
- 個別キャンバスの背景やヘッダーをクリックしても操作対象を変更しない。背景クリックはAX処理を開始しない。Board Click Actionや既存のAuto Front設定が選択イベントから暗黙に前面化を起こさないようにする。
- 分割サイズの変更はWindowBoardの表示だけを変え、外部アプリの位置・サイズは変更しない。
- 親子の枝線、パス表示、child数、階層の折り畳みは廃止する。ウィンドウカードは所有Board名を識別できる。
- 処理中表示は短時間のoverlayとし、恒常的な完了メッセージ領域を設けない。

## 8. Window Discovery and Attach Requirements

- When accessibility is trusted, WindowBoard lists ordinary windows from running applications.
- WindowBoard's own windows must be excluded from external-window candidates.
- A candidate display name is based on application name and window title, with application name used when a title is unavailable.
- The user can refresh the external window list and attach a selected candidate.
- The toolbar and Add Window card attach the frontmost eligible external window.
- The frontmost selection should prefer the most recently active external application window when available, then use a visible external-window fallback.
- The same live external window must not be attached repeatedly to the same owning Board.
- Attaching a window records its current position, Board-relative offset, and available size information.
- Persisted reference identity is retained. UI card identity includes owning Board ID and reference ID, so shared references do not erase another Board's card.

## 9. Card Interaction Requirements

### 9.1 General Card Behavior

- Cards show the application name, window title when available, application icon, state, and actions appropriate to that state.
- Application icons and card tinting are cached to avoid repeated expensive icon lookup during scrolling or Board switching.
- Cards support restrained hover and insertion/removal animation without causing excessive continuous rendering.
- 仮データの分割UI試作では、詳細切替150ms、構成変更250ms、カード追加・解除180ms、移動200ms、ホバー100ms、ドラッグ元100ms、候補表示80ms、解除領域120ms、保存結果150ms、状態表示120msの動きを使う。サイドバーの構成変更は200ms、選択背景は100msとし、並列メンバーの個別強調は行わない。
- ドラッグ中はカードとキャンバスの配置を維持し、成功したドロップの配置変更はネイティブのドラッグ終了後に表示する。取消・失敗・無変更では配置を変更しない。連続操作、Board切替、Reset Demoで古い一時表示を残さない。
- 保存完了チェックは成功ごとに表示し、1.2秒後にチェックだけを消す。旧画面のフェード表示は操作・アクセシビリティ対象外とする。
- 「視差効果を減らす」では配置・拡縮・影の動きを止め、必要なフェードを100ms以下にする。起動・リセット・リサイズ・列数境界・自動スクロールには独自の配置アニメーションを加えない。以上は試作だけに適用し、本番セッション・実保存・外部ウィンドウの動作を変更しない。
- Dragging an eligible attached window card to the Permanent Board moves the window reference there and removes it from the original owning Board.
- Dragging a Permanent Board card to another Board moves its reference to that explicit Board, like any other card move.

### 9.2 Focus and Placement

- Single-clicking a live card's icon area brings its external window forward.
- Double-clicking a live card's icon area brings the window forward and moves it below the current cursor position.
- The requested placement is best-effort, clamped to the usable display area when target window size is available.
- If a card is unavailable, reconnecting, resolving, minimized, in another Space, full-screen, or otherwise unsafe to move, the placement operation must fail safely without detaching the card.

### 9.3 Per-Window Actions

- `Save Layout` explicitly updates the owning Board's restoration position, offset, and readable size. Saving one shared-window reference does not update another Board's layout; unreadable values retain their saved values.
- `Find or Reopen` attempts to find, restore, open, or activate an unavailable/minimized saved window.
- `Use Front Window` is shown only when automatic recovery activated/opened the matching application but could not identify the saved window.
- `Use Front Window` may reconnect only to a currently frontmost window that belongs to the same application as the saved reference; it must not silently substitute a window from a different application.
- `Detach from Board` removes the card from its owning Board. It does not close the external application window.
- `Remove All Windows` removes saved windows from the target Board without closing external application windows.

### 9.4 Window Card Drag and Drop

- Dragging a window card to another Board is a **move**, not a copy.
- A successful move removes the saved window reference from its source/owning Board and inserts it into the destination Board while preserving the same reference identity and saved layout metadata.
- The external macOS window is not closed, reopened, minimized, raised, or otherwise manipulated merely because its card is moved between Boards.
- A window card may be dropped onto an explicit Board canvas or Board tab in the sidebar. Sidebar dropping allows moving a window to a Board that is not currently displayed.
- Blank space between canvases is not a valid window-card destination. A destination must identify an explicit Board canvas, tab, or sidebar row.
- If the destination already contains the same saved reference or an equivalent matching window reference, the move is rejected without removing it from the source Board.
- Moving a window card is allowed for `Available`, `Minimized`, and `Unavailable` references because it is a persistence operation. Resolving, reconnecting, removing or affected conflicting-operation cards must reject movement until their operation completes.
- Dragging a card to the Permanent Board moves ownership to the Permanent Board. It does not create a duplicate. A future copy operation, if added, must be explicit and separate from drag-and-drop.
- Cards within the same owning Board should support drag reordering. This reorders the persisted Board window-reference array only and must not issue AX operations. It is a bounded UI/persistence feature, not a new window-management mechanism.
- Sidebar/header drops append to a different owning Board; dropping on a destination card uses its visible before/after insertion position. Same-owner sidebar/header drops do nothing; reorder uses explicit positions in the card area. Hover previews never change persisted order or switch the displayed Board.
- Entire padded tabs and canvas regions accept compatible drops; group-wide footers accept Board composition only because they identify no individual card owner.
- The move preserves restoration metadata and rejects only confirmed equivalent references. Application, title or document URL alone must not falsely identify distinct windows as duplicates.
- Commit revalidates ownership, destination, insertion anchor and revision. Affected resolving/reconnecting or conflicting-operation references reject the mutation. Saving both owners is atomic; failure, cancellation or stale callbacks leave existing state intact.
- Insertion geometry, drag feedback, local autoscroll, payload typing and acceptance checks are specified in BASIC_DESIGN.md §10.
- Window-card drop targets must visibly distinguish `Move to <Board name>`, invalid destinations, and same-Board reordering insertion positions.
- Board and window-card drags use distinct internal drag types. A drop target must react only to compatible items, so Board composition drops never activate the window-only `Remove from Board` zone.

### 9.5 Drag Detach

- A window card may be removed by dropping it onto one dedicated in-app `Remove from Board` drop zone at the bottom of the displayed detail. Show it only during compatible card drags, identify the original owner, and do not activate it for Board drags.
- Dropping outside the WindowBoard app, cancelling a drag, or dropping onto an unsupported target must not detach a window. Only a successful drop on the dedicated zone confirms removal.
- `Available`, `Minimized`, and `Unavailable` cards may be removed. `Reconnecting`, `Resolving`, and already-removing cards must be rejected until their operation completes.
- Drag detach uses the same removal path and exit animation as `Detach from Board`; it removes the saved reference from its owning Board, including a split-group member or Permanent Board, without controlling the external macOS window.
- Drag detach has no Undo. A removed window can be added again with the existing Add Window flow.

## 10. Attached Window States and Recovery

The UI must use these states:

| State        | Requirement                                                                              |
| ------------ | ---------------------------------------------------------------------------------------- |
| Available    | A live AX window is accessible.                                                          |
| Resolving    | A saved reference is being matched during Board loading.                                 |
| Minimized    | The window is known to be minimized and can be restored.                                 |
| Unavailable  | No matching accessible live window has been found. The saved reference remains attached. |
| Reconnecting | An explicit or deferred recovery operation is in progress.                               |

- `Unavailable` must mean that the window cannot currently be found or safely accessed, not merely that a position/size write failed.
- A temporary AX read/write failure on a known live window must not immediately turn it into `Unavailable`.
- A recovery task must clear `Reconnecting` in every success, failure, cancellation, and stale-row path.
- Failed recovery returns the card to `Unavailable` and allows retry.
- Recovery is best-effort. A successful application activation is not enough to claim a saved window was reconnected.
- Automatic missing-window recovery during Board switching is controlled by a user setting. When disabled, missing windows remain unavailable until an explicit recovery operation.
- Deferred switch-time recovery, when enabled, must run after the main Board switch rather than blocking visible Board changes.
- Recovery may use app identity, bundle identifier, document URL, window title, process identity, cached window identifiers, and window number in a best-effort order.

## 11. Layout, Follow, and Fronting

### 11.1 Layout Restoration

- Board switching restores saved window position and optional size best-effort.
- `Restore Layout` uses saved restoration values for its explicit Board or displayed group and never implicitly saves current values first.
- No-op position and size updates should be skipped when current values are already sufficiently close to saved values.
- A layout-application failure must not detach a window or erase its saved reference.
- With Follow Mode `None`, layout restoration should prefer a saved absolute origin when appropriate, including Status Item initiated switching.

### 11.2 Follow Modes

- `None`: attached windows remain attached but do not follow WindowBoard movement.
- `Smooth`: attached windows follow WindowBoard movement during motion.
- `On Release`: attached windows are moved after WindowBoard motion ends, with a short release animation where applicable.
- Follow movement operates only on eligible live attached windows. During Restore Layout, pause Follow for affected physical windows and invalidate queued older moves; resume from successfully observed/restored positions without altering saved restoration values. Failed operations retain recoverable state and must not resume using stale coordinates.
- Board-window movement observation should use AppKit notifications as the normal path and avoid a permanent high-frequency polling loop.
- AX move operations must run off the main thread and use scheduling/debouncing to reduce beachballing and energy impact.

### 11.3 Fronting

- `Focus Board` brings the resolved Current Board's live windows forward best-effort.
- WindowBoard uses application activation, AX focus, and AX raise where applicable; strict macOS z-order cannot be guaranteed.
- Auto Front may continue after deliberate Board-window movement according to its setting, but not from tab selection, canvas focus, composition refresh, or their callbacks.
- Generic Board clicks select a canvas without fronting. Use the explicit Focus/Bring Forward actions for fronting; legacy click-to-front must not remain active on selection surfaces.
- A temporary floating level may be used during explicit fronting and must return to the configured level. Ordinary tab switching must not trigger fronting callbacks.
- `Keep Window Board On Top` controls WindowBoard's normal persistent level.

## 12. Minimize and Restore

- `Minimize Others` minimizes accessible ordinary windows that are not part of the resolved Current Board.
- Windows belonging to every member of the displayed split group must be protected from minimization.
- `Minimize Others When Switching Boards` performs this action after the target Board is shown; Board loading must not wait for all minimization to finish.
- Minimize selection should reuse known candidates from Board switching where possible; manual minimize may perform a complete fresh enumeration for accuracy.
- WindowBoard records windows it minimized so `Restore Windows` restores only its own minimize history.
- Successfully restored windows are removed from that history; failed restores remain available for later retry.
- Minimize and restore remain conservative and best-effort to avoid minimizing protected windows incorrectly.

## 13. Main Window Toolbar and Board Settings

### 13.1 Toolbar

- The toolbar presents Board navigation/creation controls on the left and window/Board operations on the right.
- It includes a sidebar toggle, New Board, attach-frontmost, focus, recover missing windows, minimize others, restore minimized windows, and a More menu.
- Tooltips must explain icon-only toolbar controls.
- `Refresh Window List`, `Restore Layout`, and Board Settings are available from the More menu when not surfaced as primary controls.
- Board Settings is a low-frequency action and may choose among member Boards when the active Current Board is a group.
- Toolbar state must correctly disable actions when accessibility is unavailable, a required Board/window does not exist, or an incompatible operation is already running.

### 13.2 Board Settings

- Board Settings supports save, overwrite, rename, delete, Status Item display selection, Status Item text, switch behavior settings, persistent-on-top setting, and remove-all-windows action.
- Default/Permanent Board rename and deletion controls are disabled.
- Board settings act on their explicit target Board. Opening settings for another member does not change the displayed group; only operations inside that settings view use its explicit target. No default member or hidden toolbar attach destination exists.

## 14. Application Settings

The macOS Settings scene provides persistent behavior settings:

- `Follow Mode`
- `Position Update`
- `Auto Front`

These settings must apply immediately to the main window behavior and persist across app launches.

- Legacy `Board Click Action` fronting is disabled in the new tab/canvas UI and is not offered as a selection-triggered action. Preserve its old value only for backup/old-format compatibility; explicit Focus and Bring Forward remain available.

### 14.1 Software Updates

- WindowBoard uses Sparkle 2 for in-app software updates with its configured HTTPS update feed and Sparkle EdDSA public key.
- The user can choose `Check for Updates…` from the application menu or the Status Item menu.
- If a development build has no feed URL or public key configured, WindowBoard must not begin update checks or make update-network requests. The update action must explain that the distribution feed has not yet been configured.
- Update archives and appcasts are signed outside the application with the corresponding private EdDSA key. The private key must never be shipped in the application bundle or committed to the repository.

## 15. Status Item Requirements

- WindowBoard provides a Status Item while remaining visible in the Dock as a normal app.
- The Status Item shows the active/selected Board's configured symbol, emoji, text, or default glyph.
- The menu can show the main WindowBoard window, switch Boards, focus Board windows, minimize others, restore minimized windows, open Settings, and quit.
- Saved Boards and Current Board groups are represented in the Status Item menu.
- Selecting a grouped Board activates its split group and focuses that member. No Primary Board is required.
- The active selected Board in the active group is checkmarked.
- Status Item Board switching must use the same `WorkspaceSessionController` switching path as the main window.
- Status Item switching records current observations for every outgoing member without overwriting restoration layouts or opening the main window. Explicit layout save remains owner-scoped.

## 16. Switching Requirements

User-initiated switching to a different display target must be staged and responsive. Same-group focus changes and composition refresh do not run this sequence:

1. Record recent runtime observations for every outgoing member and persist pending metadata, but never implicitly overwrite restoration layouts.
2. Resolve the flat display target and show placeholder cards in their owning Board canvases promptly.
3. Use cached/live windows to replace placeholders and apply saved layouts in the background.
4. Mark unresolved references as unavailable without removing them.
5. Optionally begin deferred missing-window recovery after the visible switch.
6. Optionally minimize non-Current-Board windows after the target Board is shown.
7. Ignore stale async completions from an older switch once a newer Board becomes active.

- Selection itself must not front external windows. When explicitly enabled, automatic recovery may need open/activate requests; these are recovery side effects, not ordinary selection-triggered fronting.

- Main-window and Status Item Board switching share this single session path.
- Consecutive switches must not allow an older task to overwrite the active Current Board, attached windows, recovery state, or minimization state.
- Attached snapshot polling must pause while loading, applying layouts, minimizing, or restoring to avoid AX contention.

## 16.1 Quick Launcher Requirements

- The Quick Launcher is a feature of the main **WindowBoard** application target. It is not a separate application and is not added to the experimental `WindowBoardTree` target.
- The launcher opens from anywhere with `Command-Shift-Space`, and from `Show Quick Launcher` in the Status Item menu.
- It appears as a centered, transient floating panel near the screen containing the pointer. Closing the panel must not terminate or hide the main application.
- Opening the launcher repeatedly reuses one panel/controller and returns keyboard focus to the search field. Pressing the global shortcut while it is open toggles it closed.
- Results are grouped as `Boards`, `Windows`, and `Actions`, with bounded result counts so ordinary typing does not trigger an unbounded list render.
- Search is local and immediate. It matches Board name, saved Board search aliases, application name, window title, owning Board, and action terms while ignoring case, width, diacritics, and Hiragana/Katakana variation. Japanese text containing Kanji is also indexed with a local `ja_JP` tokenized reading, so a reading prefix such as `じゅ` can find `授業`. Multiple terms must all match; exact and prefix matches rank above substring, typo-tolerant, and fuzzy matches; recent successful use may refine ties without overriding clearly stronger text matches. Matching text is visually emphasized in result titles when possible.
- A Board's optional comma-separated search aliases are saved in Board Settings. `>` limits a query to Actions, `@` limits it to Windows, and `#` limits it to Boards.
- The launcher always shows the current selected Board directly below its search field. The matching Board row also has a `Current` badge and checkmark; this indication is independent of the keyboard-selected result that Return will execute.
- Keyboard operation supports Up/Down selection, Return execution, and Escape dismissal. Disabled items cannot be executed, and selection remains stable across live result refreshes when the selected item still exists.
- Board results use the same session switch path as the sidebar and Status Item. A result activates the owning split group and focuses the matched Board.
- Current Board window results expose state-appropriate behavior: bring forward when available, restore when minimized, and find or reopen when unavailable. They also provide a `Detach` control that removes the saved reference from its owning Board without closing, minimizing, moving, raising, or reconnecting the external window. Resolving or reconnecting entries remain visible but cannot start a conflicting duplicate operation.
- Saved window references belonging to inactive Boards remain searchable and are marked `Saved`. Selecting one switches to its owning Board; it does not pretend that an inactive saved reference is already a controllable live window.
- Action results include showing the main window, focusing Current Board windows, restoring layout, attaching the frontmost eligible window, recovering missing windows, minimizing others, restoring windows minimized by WindowBoard, and refreshing the main-window candidate list. Each action uses the same session/application operation path as its existing UI equivalent.
- Launcher-triggered switching records observations without implicit layout save. Switching and restoration preserve unavailable references, reject stale completions, and keep AX work off the main thread. Selection does not implicitly front external windows.
- Accessibility-dependent results are disabled when permission or required runtime state is unavailable. Failures produce a concise status message and leave saved Board/window state recoverable.
- Only one launcher-triggered operation of the same logical target may run at a time. Completion from an older recovery attempt must not overwrite a newer attachment or Board state.

## 17. Performance and Reliability Requirements

- Accessibility reads, writes, app activation, focus, raise, minimize, restore, and recovery polling must not block the main thread.
- Idle behavior must avoid permanent high-frequency polling.
- Window snapshots run at low frequency and update runtime/recovery observations only for meaningful changes. If observations are persisted, they use storage separate from restoration layouts and never modify those layouts.
- Routine snapshots should avoid reading window size; size is read for explicit layout saves and layout restoration as needed.
- Application activation/launch-triggered refreshes are debounced and limited to relevant applications where possible.
- UI updates during Board switching are batched where possible to avoid repeated full card-grid rendering.
- Card icon lookup and tint computation are cached.
- Animations must be reduced or omitted for large card sets when they impair switching responsiveness.
- Debug builds may emit low-noise timing/counter logs; these diagnostics must not be user-facing.

## 18. macOS and Accessibility Limitations

WindowBoard must communicate and behave as best-effort because public macOS APIs do not provide full control of all windows.

- Exact external-window z-order cannot be guaranteed.
- Existing windows on another Space cannot reliably be moved into the current Space.
- Full-screen windows and windows on another Space are not reliable Board targets.
- System panels, special windows, and permission-limited windows may not be controllable.
- Some applications do not permit move, resize, minimize, restore, focus, or raise through Accessibility APIs.
- Closed windows cannot always be reopened to the same document, folder, tab, or internal application state.
- Applications with multiple similar windows may not expose enough metadata to distinguish the original saved window perfectly.
- A failed AX operation must leave the Board reference recoverable whenever possible; it must not silently remove the user's saved intent.

## 19. Non-Goals

The current product does not guarantee or require:

- embedding third-party windows inside WindowBoard;
- strict global z-order control over macOS windows;
- reliable control of full-screen or cross-Space windows;
- exact restoration of all closed-window document/tab/application state;
- automatic resolution of all ambiguous windows from the same application;
- arbitrary window management outside the user's saved Boards.

## 20. Acceptance Checklist

- A user can grant accessibility permission, attach a frontmost or selected window, and see it appear immediately in the Current Board.
- A user can create, save, rename, overwrite, delete, and switch Boards, subject to Default/Permanent Board restrictions.
- A user can combine Boards into flat split groups, move a member between groups, and separate any member without deleting it. Child creation and hierarchy UI do not exist.
- A Board appears in one group or as one standalone tab; groups cannot overlap or contain groups. No tab-close action exists in this first phase.
- Each member has an independent canvas, and Board-specific actions affect only their explicit owner. Focus changes within a group do not reapply external layouts.
- Migration preserves Boards and windows, previews conflicting old memberships, verifies backups, and does not write new data if validation or confirmation fails.
- A user can move a window card to an explicit canvas or sidebar Board without changing the external window itself.
- A user can operate Board switching from either the sidebar or Status Item without diverging behavior.
- A user can see and recover unavailable/minimized saved windows without losing their saved Board membership.
- A user can restore layout, focus Board windows, minimize other windows, and restore only windows minimized by WindowBoard.
- A user can configure follow/fronting behavior and Status Item display values.
- Board switching, card scrolling, and idle operation remain responsive and do not perform unnecessary high-frequency Accessibility work.
- The app behaves safely when macOS or an external app denies a requested window operation.
- A user can open the Quick Launcher globally, search Boards/windows/actions, switch Boards through the shared session path, and execute only state-valid operations without opening a second application.
