# 要件生成時の実現性補足

## 状態

2026-10-23。静的・公式資料の調査であり、実アプリ操作や内容復元の成功証拠ではない。利用者の要求範囲はFinder全タブのフォルダ・並び・選択タブと、VS Codeのプロジェクト／workspace・開いていたファイル一覧・選択中ファイル。保存はそのBoardで最後に使っていた内容への自動更新。

## Finderの未確定事項

調査担当がApple提供のインストール済み辞書 `/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.sdef` を読取り確認した。Finder windowのtargetはあるが、タブの列挙・並び・選択タブを表す項目は見つからなかった。「新規タブで開く」設定は全タブ情報を取得する機能ではない。

これは当該辞書に機能が見当たらないという証拠であり、すべての公開手段で不可能という結論ではない。後続のギャップ分析・設計で取得と再現の両方を検証する。単一フォルダを開く、または複数の別窓を開くことを全タブ復元の代替達成としない。未成立なら阻害事項を提示し、要求範囲を黙って狭めない。

## VS Codeの可能性と限界

[公式API](https://code.visualstudio.com/api/references/vscode-api)にはworkspaceFolders、workspaceFile、TabGroups、選択中グループ／タブ、通常ファイルのTabInputText.uri等がある。対象アプリ側の連携を含めて要求項目を扱う可能性はあるが、WindowBoardへの接続や実機動作は未検証。

比較・Notebook・独自エディタ・Terminal・Webview等は通常ファイル一つと同一視しない。[公式CLI](https://code.visualstudio.com/docs/configure/command-line)のファイル・フォルダを開く機能だけで、既存窓の全ファイル一覧の取得が成立するとは扱わない。既存窓への再利用では別Boardの作業を上書きしないことを確認する。

## 要件レビュー記録

requirements.mdへ書き込む前に、一時ドラフトを対象に数値ID・EARS形式・領域ごとの受け入れ基準・実装詳細の混入を機械的に確認した。9領域・48基準で成功。独立した読み取りレビューでも範囲・観測可能性・取得失敗時の記録保持・部分復元後の再試行・Board間の保護を確認し、必須修正と追加の利用者確認事項なし（PASS）。

本レビューは要件の品質確認であり、FinderとVS Codeの実現性、設計の承認、テスト成功を証明するものではない。要件の利用者承認は未設定で、実装開始可能にはしていない。

---

## ギャップ分析 — window-content-restoration（2026-10-24）

### 1. 分析条件と結論

- 対象は現在の作業ツリーとrequirements.mdの9領域・48基準。要件は生成済み・未承認であり、本分析で承認状態を変更しない。既存の未コミット変更も現在実装の一部として読み取り、巻き戻さない。
- 手法は静的なコード・プロジェクト設定・テスト内容の調査、公式資料、インストール済みFinder辞書の確認。コード変更、ビルド、テスト実行、GUI操作、AX操作、AppleEvents送信、権限変更は行っていない。
- 既存の登録・復旧・背景処理・世代検査を再利用できるが、内容の取得・保存・詳細復元・内容の照合という一連の機能は未実装。既存テストや過去の最小化改善の成功を本機能の証拠にしない。
- Finder全タブの取得・適用・読み戻しは **Unknown / Research Needed**。単一フォルダURLの再オープンでは3.1〜3.3を満たさない。当該スクリプティング辞書にタブ機能がないことは、すべての公開手段で不可能という証明ではない。
- VS Codeには要求情報を扱う公開機能の候補があるが、WindowBoardから直接利用する仕組みはない。アプリ内連携、窓との対応付け、導入・停止・互換性が新しい検討領域になる。
- 保存失敗時の既存データ消去、同一アプリの先頭窓へのフォールバック、主画面とLauncherの独立した結果適用は、そのまま流用すると内容保持・誤復元防止に不足する。

**分類**：`Missing`＝現在実装に必要機能がない、`Unknown`＝公開資料や静的調査だけでは成立を確認できない、`Constraint`＝既存仕様・実装・プラットフォームが課す条件。既存資産があっても、当該受け入れ基準全体を充足済みと判定するものではない。

### 2. 現在の資産・パターン・接続箇所

ソース位置は今回確認した作業ツリーを基準とする。

| 資産 | 確認できた現在の責務・再利用点 | 今回の境界で不足するもの |
| --- | --- | --- |
| `WindowBoard/Models/SavedWorkspace.swift:150` | SavedWindowReferenceのアプリ識別・文書URL一つ・workspaceURL・配置、登録ID、保存値のコピー | 複数内容、選択、完全性、観測時点、内容の版、取得失敗と明示削除の区別 |
| `WindowBoard/Models/WindowInfo.swift:25` / `AttachedWindowSnapshotReducer.swift:38` | ライブ窓識別とタイトル更新。取得不能でも登録を保持する遷移 | タイトル更新は旧documentURLを維持し、内容変更を取得しない |
| `WindowBoard/App/WorkspaceSessionController.swift:711,979,1010,2096` | attach時保存、所有Board別の保存、切替前保存、登録参照の保持 | 内容だけの更新、退出元への背景取得の反映、内容世代・復元中の記録保護 |
| `WindowBoard/Services/AttachedWindowSnapshotCoordinator.swift:35,53,104` | 低頻度・背景採取、活動状態、取消・revision検査。状態と保存を所有しない | 現在は位置・タイトル・最小化状態のみ。内容取得・部分結果・連携イベントはない |
| `WindowBoard/Services/AccessibilityWindowService.swift:23,486,715` | 注入可能な操作protocol、共通の文書／アプリオープン、AXDocument取得 | Finderタブ、VS Code窓内容、内容付き復元結果・能力判定はない |
| `WindowBoard/Services/AttachedWindowRecoveryCoordinator.swift:4,15,55` | 元のライブ窓の再利用、背景で開く要求とポーリング、取消 | Board・内容版・保護する別窓の文脈、内容適用・確認、不足項目・権限理由 |
| `WindowBoard/Models/AttachedWindowRecoveryResolver.swift:46` / `WindowMatching.swift:31` | 純粋な照合、明示的な同一アプリ代替経路 | 文書／タイトルの後に先頭同一アプリ窓を採用するため、内容の一意確認と異なる |
| `WindowBoard/Views/ContentView.swift:1853,1907,1937` | 主画面の明示復旧、登録単位のlocal revision、結果表示 | 内容版・共通要求世代・詳細結果の表示と一元反映 |
| `WindowBoard/Launcher/QuickLauncherIntegration.swift:256,377,416` | 同じRecoveryCoordinatorを利用、Launcher内のrevision検査 | 主画面と異なるrevisionと結果反映。入口横断の整合性は未確立 |
| `WindowBoard/Stores/WorkspaceStore.swift:142,167` | Board全体を保存・読込み | 全配列decode失敗で空になり、初期化に伴う保存で旧データを置換し得る。encode失敗では保存キーを削除する |

**既存調査の表現補足**：SavedWindowReference.make／makePreservingOffsetは、新規参照ではworkspaceURLStringをnilにするが、既存savedReferenceをコピーする経路では既存workspaceURLStringを保持する。一方documentURLStringは`SavedWorkspace.swift:226,266`でWindowInfo由来のnilを含めて置き換える。新旧のどちらにもタブ／ファイル集合の取得経路はない。

**守る規約**：利用者向けBoardと内部Workspace名を維持する。状態・保存の判断は既存Sessionを中心とし、Coordinatorを別の常駐Sessionにしない。AXは既存サービス境界から背景実行する。純粋な照合と外部操作を分ける。位置用snapshotの既存制御を、内容を観測した証拠として流用しない。Sessionは2549行、ContentViewは2150行、AXサービスは748行あり、単純な追加集中は責務の肥大化を招く。

### 3. Requirement-to-Asset Map

| 基準 | 既存の資産・接続箇所 | ギャップ分類と確認事項 |
| --- | --- | --- |
| 1.1 | attachWindow、SavedWindowReference.make | **Missing**：登録時の新鮮な内容取得、複数項目と完全性の保存。キャッシュ情報の即時保存のみでは不足 |
| 1.2 | SnapshotCoordinator／Reducer、WindowInfo.updatingTitle | **Missing**：内容変更の自動確認。現在の10秒間隔の採取は内容採取ではない |
| 1.3 | persistActiveWorkspaceSnapshotForSwitch、performSwitchWorkspace | **Missing**：切替元の不変な対象を保持した背景内容取得と反映。切替前のキャッシュ保存だけでは不足 |
| 1.4 | make／makePreservingOffset | **Missing / Constraint**：nil文書URLによる既存値消去と区別する、取得不能時の保持 |
| 1.5 | SavedWindowReference、保存経路 | **Missing**：完全／部分／失敗の取得品質と、部分結果を完全な空集合とみなさない更新規則 |
| 1.6 | 登録参照は単一文書情報のみ | **Missing**：全体取得の成立、タブ／ファイルの閉鎖確認、項目の削除判定 |
| 1.7 | Snapshotのrevision・ライブID・再接続中除外 | **Missing**：内容取得の世代、Board・参照・ライブ窓の一致検査。既存位置採取の検査は参考資産 |
| 1.8 | Snapshot Activity、reconnecting状態 | **Missing**：復元に使う内容版の固定、空・途中・失敗後の部分構成による上書き防止 |
| 2.1 | openSavedWindowReference、RecoveryCoordinator | **Missing / Constraint**：共通オープンは再利用可能だが、内容付き要求と窓・項目の結果確認がない |
| 2.2 | 既存文書URLオープン | **Missing**：共通能力と詳細能力の区別、到達点に応じた表示 |
| 2.3 | 任意のsavedReference、旧保存モデル | **Constraint**：旧形式の再オープンを維持しつつ新しい詳細記録なしで読める必要 |
| 2.4 | bestSavedWindowの同一アプリ先頭フォールバック | **Missing / Constraint**：内容不明と曖昧一致を区別し、別内容へ自動確定しない |
| 3.1 | AXDocument一つ | **Missing / Unknown**：Finder全タブのURL列・順序・選択を同一窓の構成として取得する経路 |
| 3.2 | 共通URLオープン | **Missing / Unknown**：一つのFinder窓への構成再現と読み戻し。一窓一フォルダのオープンを代替達成にしない |
| 3.3 | 現状にタブ集合なし | **Unknown**：同一フォルダの重複タブと各位置を維持する取得・作成・確認 |
| 3.4 | Boolオープン、粗い復旧結果 | **Missing / Constraint**：フォルダ別の利用可否と結果集約。特殊な場所・アクセス不能を区別 |
| 3.5 | 復旧Result／Issue | **Missing**：全体取得・適用・確認の不足項目と能力の表現 |
| 4.1 | workspaceURL保存欄、VS Code識別 | **Missing / Unknown**：プロジェクト・ファイル集合・active fileの取得と対象窓への対応付け |
| 4.2 | VS Codeは文書URL再オープンを除外 | **Missing / Unknown**：要求した窓へプロジェクト／ファイルを適用し、選択状態を確認する接続 |
| 4.3 | workspaceURLの既存値保持のみ | **Missing / Constraint**：workspaceとフォルダ集合の表現・取得・復元。未保存workspaceを既存ファイルパスと同一視しない |
| 4.4 | アプリ起動・アクティブ化 | **Missing**：プロジェクトなしのファイル集合窓の区別と安全な復元 |
| 4.5 | 既存結果は窓単位 | **Missing / Constraint**：ファイル／プロジェクト別の存在・適用・確認結果。新規の空ファイルを開いた状態と復元成功を区別 |
| 4.6 | 通常文書URL一つ | **Missing / Constraint**：未保存・比較・Notebook等と通常の保存済みファイルの分類、範囲外表示 |
| 5.1 | RecoveryCoordinatorの元ライブ窓優先 | **Constraint**：既存の優先動作を維持。再接続を保存内容の一致確認とは扱わない |
| 5.2 | 文書／タイトル／先頭同一アプリ照合 | **Missing**：内容根拠のない候補を自動確定しない内容対応の照合結果 |
| 5.3 | 現在は開く要求の後に候補照合 | **Missing / Unknown**：別Board使用中の窓を保護した要求先の指定・再利用防止。後から照合するだけでは遅い |
| 5.4 | Use Front Window、純粋Resolver | **Missing**：曖昧／確認不能の結果と明示選択の接続。現在の先頭候補採用を置き換える範囲の検討 |
| 5.5 | switch revision、入口ごとの復旧revision | **Missing**：内容版・所有Boardと入口横断の要求識別。退出元への正当な記録更新と現在UI更新を分ける |
| 5.6 | 所有Board別のinline登録参照 | **Missing**：共有ライブ窓で別Board復元の影響を他Boardの内容記録へ波及させない反映規則 |
| 6.1 | restoredOriginal等の窓復旧Result | **Missing**：内容成功／部分／確認不能／非対応／失敗の根拠付き結果 |
| 6.2 | 主画面とLauncherのRestored／Reconnected表示 | **Missing**：窓の利用可能性と内容復元成功の明確な分離 |
| 6.3 | 現在のIssueは開けたか・一致したか中心 | **Missing**：不足したフォルダ／ファイル／選択等の項目別結果 |
| 6.4 | 両入口独立のlocal revision | **Missing**：同じ対象への入口横断の最新要求検査、表示の一貫性 |
| 6.5 | 現在の参照に内容観測時点なし | **Missing**：最後に正常取得した時点・品質の保持と、未観測変更を保存済みとしない表示 |
| 7.1 | Accessibility信頼のUIゲート | **Missing / Constraint**：追加連携の不在・権限拒否・対応版等を区別し、既存記録を維持する動作 |
| 7.2 | 各登録を独立して明示復旧 | **Missing**：新しい内容取得・項目別復元でも独立続行できる失敗集約。既存窓復旧は参考資産 |
| 7.3 | 40回ポーリングとsleep、取消 | **Missing / Constraint**：同期外部呼出しを含む有限な終了。試行回数の上限は全体時間の上限ではない |
| 7.4 | 文書URL文字列と既存照合 | **Missing / Unknown**：移動・削除・アクセス不能の判別と同名別対象への誤置換防止。bookmarkの要否も検討 |
| 7.5 | 失敗後の再実行入口 | **Missing**：元記録の保持、部分復元済み窓の既存優先との整合、不足項目の再試行と重複作成防止 |
| 8.1 | 合成Codableと旧任意フィールド | **Constraint**：詳細記録なし・未知版・不正payloadでも既存Board・配置を失わない読込み |
| 8.2 | Store.load／persist | **Missing / Constraint**：現在の全体decode失敗・encode失敗時消去に対する保持・エラー通知・退避方針 |
| 8.3 | deleteWorkspace、detach、inline参照 | **Missing**：削除・移動後に遅延取得が復活させない無効化。追加cache／連携側の記録があればその整理 |
| 8.4 | 既存のID・件数中心の診断 | **Missing**：新payloadと連携エラーの診断への流出防止、完全URL／パスを含まない検証 |
| 8.5 | 現行復旧には強制保存や任意作業コマンド再実行なし | **Constraint**：個別連携でも同じ境界を維持し、開く操作と内容・処理の巻戻しを混同しない |
| 9.1 | 既存の保存では内容識別とgeometryが同じ参照にまとまる | **Missing**：内容だけの更新と、Store／メモリ内savedReferenceの一致。全配列・配置保存の流用は要注意 |
| 9.2 | 切替時自動復旧設定・既定OFF | **Constraint**：内容の自動採取を復旧開始につながない。既存設定の回帰検証が必要 |
| 9.3 | 共通RecoveryCoordinator、異なる結果適用先 | **Missing**：主画面／Launcherで同じ内容記録・判断・要求世代を使う接続 |
| 9.4 | unavailable時に登録保持する既存遷移 | **Constraint**：内容の失敗でも同じ保持規則を維持する |

この表は要件充足の合否ではなく、設計へ引き継ぐ実装ギャップである。`Constraint`だけの行も新しい経路を含めた検証が必要。

### 4. 外部連携の実現性と未確定部分

#### Finder

Apple提供のインストール済み `/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.sdef:312–339` にはwindow.id、窓の前後順window.index、Finder window.targetがある。window.indexはタブ内の順序ではない。タブ列挙・タブ順・選択タブを表す項目は見つからず、421行のfolders open in new tabsは設定項目である。

公開AXでタブのラベルや順序を読める可能性があっても、全タブのフォルダURL・重複・選択を正しい窓へ結び付ける成立性は未検証。ラベルだけでは同名フォルダを区別できない。タブを一時的に選択して取得する候補では、選択・フォーカスの変化と復旧、自動記録中の利用者操作との競合を調べる必要がある。[Apple AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement)

**判定**：詳細取得と詳細復元の双方がResearch Needed。複数URLを開くことや、現在のフォルダが分かることから、全タブ復元可能とは推定しない。技術的に成立しなければ設計の阻害事項を提示する。要件の削減は本分析では決定しない。

#### VS Code

公式APIのwindow.tabGroups、各groupのtabs／activeTab、activeTabGroup、変更イベント、TabInputText.uri、workspaceFolders、workspaceFileは要求情報の候補になる。ただしこれらはVS Code内で使う機能で、WindowBoardから直接読める外部APIではない。textDocumentsだけを開いている全タブの代用にせず、Diff／Notebook／Custom Editor／Terminal／Webview／未保存項目を分類する。[公式API](https://code.visualstudio.com/api/references/vscode-api)

公式CLIはファイル・フォルダのオープンを支援するが、既存窓の全ファイル取得や任意の登録窓の指定は提供する契約ではない。--reuse-windowは最後のアクティブ窓を使うため、他Boardの窓の保護に不足する。存在しないファイルを新規ファイルとして開く場合があり、タブが出現しただけでは復元成功にならない。[公式CLI](https://code.visualstudio.com/docs/configure/command-line)

companion extensionとローカル連携は候補だが未選定。拡張側のセッションをAXの実窓へ一意に対応付ける仕組み、再起動後の再対応付け、要求の認証・寿命、同一プロジェクトの二窓を区別する方法が必要。タイトルやプロジェクトURLだけで一意としない。新しい連携口を採用する場合に限り、偽の送信元・古いメッセージ・別窓への誤適用の対策を設計する。

保存済みworkspaceファイルと未保存workspaceのフォルダ集合は区別する。Remoteの拡張実行場所やURIをローカルパスと同一視しない。Restricted Modeの動作、拡張の有無・停止・版違い・導入／更新が利用者に見える境界となる。Workspace Trustの付与を自動化して成立させない。[Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host)、[Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust)、[拡張配布](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)

**判定**：要求を扱える公開機能はあるが、窓単位の連携・適用・確認はMissing / Unknown。CLIだけで充足できるとは判定しない。外部ライブラリは未選定のため、将来依存の保守やライセンスの適合性を確認済みと扱わない。

#### 共通オープンと権限

現在のオープン処理には「要求を受け付けた」ことと「内容が戻った」ことの区別が必要。NSWorkspace.openのBoolも、指定アプリの非同期openが返すアプリ／Errorも、特定窓の内容確認そのものではない。[Boolのopen](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:))、[非同期のopen](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))

AppleEvents方式を選ぶ場合にのみ、Automation利用目的と実際の署名・Hardened Runtime・Sandbox設定に合う権限構成を検証する。現在の通常版Info.plistにはNSAppleEventsUsageDescriptionがなく、projectにはCODE_SIGN_ENTITLEMENTSやautomation entitlementの設定がなく、Debug／ReleaseにCODE_SIGNING_ALLOWED=NOがある。これを将来の配布アプリがAutomationを利用できる証拠にしない。Accessibilityの許可とAutomationの許可も別である。現段階では追加権限の付与・要求は行わない。[利用目的](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)、[entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)

### 5. 保存・世代・整合性の重点課題

1. **内容だけの反映**：既存の保存は参照配列全体とgeometryを更新する経路がある。内容の自動更新で配置・名前・順序・所属を変更しない更新単位が必要。Storeの新payloadとメモリ中のsavedReferenceのコピーを一致させないと、後の配置保存で古い内容が復活し得る。
2. **不変な対象識別**：取得開始時のBoard・登録参照・ライブ窓・取得世代を保持する候補。切替元への遅延した正当な内容記録と、切替先UIへ適用してよい結果を分ける。削除・移動・同じBoardへの再切替・窓の差替えで再確認する。
3. **部分結果と完全構成**：取得不能と空集合と利用者による閉鎖を区別する。異なる時点の部分情報の寄せ集めを一つの完全構成に昇格させない。正常取得済みの情報は保持しても、全タブ／全ファイルを確認済みとは表示しない。
4. **復元記録の保護**：開始時の記録を不変に保ち、復元途中・部分失敗後の窓を通常の完全取得とみなして復元元を消さない。部分復元済みの窓へ再試行するとき、既存ライブ窓優先と不足項目追加・重複防止を両立させる条件を定める。
5. **新payloadの互換性**：単に任意フィールドを追加するだけでは、未知版や不正なpayloadで全Boardのdecodeを失敗させ得る。既存Storeのencode失敗時消去と、decode失敗後の既定Board保存による置換も含め、最後の有効記録の保持・退避・通知を検討する。
6. **コピー・移動・再構築**：saveCurrentWorkspaceは現在の参照IDを保って新Boardへコピーする。moveAttachedWindowは参照を移して二つのStore更新を行い、reorderは参照値を移す。WindowBoardAppStateにはSavedWindowReferenceを明示的に再構築する経路もある。payloadを落とさず、コピー後は独立、移動前の遅延結果は無効となるよう検討する。
7. **入口間の整合**：主画面とLauncherは同じCoordinatorを使うが、要求revisionとSessionへの直接反映は別々。同時要求・入口の切替・別Boardへの遅延結果に対する共通方針が必要。外部操作の副作用はUI適用後のguardだけでは取り消せないため、開く／適用する前の対象確認も必要。

ここで挙げた保持・識別方法は設計候補であり、新しい型・保存形式・同時実行規則の決定ではない。

### 6. 実装構成の選択肢

以下のA／B／Cは、discoveryで利用者が選択した「B：共通基盤＋アプリ別連携」を実装する構成の比較であり、製品方針を変更する選択肢ではない。どの構成でもFinderの成立性とVS Code窓連携の検証は必要。

| 構成 | 主な変更と接続 | 利点 | 欠点・成立条件 |
| --- | --- | --- | --- |
| A：既存部品中心に拡張 | SavedWindowReference、Snapshot、AXサービス、RecoveryCoordinator、Session、両入口へ内容機能を追加。必要なVS Code内連携は最小の追加物として接続 | 既存の注入・保存・復旧のパターンを広く使える。旧登録との共存を進めやすい | Session／AX／UIがさらに肥大化。内容の判定を入口ごとに複製しやすい。単一URL処理の追加だけでは詳細目標を満たさない |
| B：内容用の新部品を中心に追加 | 能力判定、内容採取・結果判定、アプリ別連携、内容用保存領域の候補を独立した部品として用意し、既存Sessionが対象・反映を管理 | プラットフォーム依存と詳細状態を隔離し、単体で検証しやすい。既存の文書URL用途を保ちやすい | 保存先が分かれるならBoard削除・コピー・移動・復元と同期が必要。新しいSessionや独立したBoard所有者を作る形はAGENTSに反するため採用不可 |
| C：既存状態基盤＋局所的な新内容部品を併用 | 既存登録・Store・Sessionの所有権を維持し、内容だけの更新と共通の要求／結果反映を拡張。採取の調停、純粋な内容比較、Finder／VS Code連携は局所部品へ分離 | 既存資産を維持しながらアプリ別処理と両入口の重複を抑えられる。段階的に検証しやすい | 内容版・取得品質・復元中保護・旧データ互換性などの契約を先に詰める必要。ターゲット境界と拡張配布の計画が増える |

**設計へ推奨する候補**はC。既存の状態所有権を守りつつ、Finder／VS Codeの不確定性を局所的に検証しやすいため。ここでは最終採用・新API・保存形式を決定しない。

段階化する場合、(1)FinderとVS Codeの成立性検証、(2)完全／部分の記録と安全な保存、(3)自動採取と背景反映、(4)詳細復元と内容確認、(5)両入口・権限拒否・データ互換の統合確認、という依存順が候補。途中の共通単一URL機能だけを全要件の完成とは扱わない。専用拡張など独立配布物が必要になれば、別specへ切り出すかを設計で再評価し、本specとの契約を明示する。

### 7. 互換性・テストのギャップ

- **共有モデル**：TreeはSavedWorkspace／WorkspaceStore／AXサービス／WindowMatchingを共有している。通常版のみの行動拡張でも、新しい保存型の依存やprotocol必須メソッドはTreeとfakeサービスを壊し得る。内容機能が使えない従来の利用者を完全対応に見せるdefault実装は避け、未対応を表現する互換性を検討する。
- **ターゲット登録**：Xcodeプロジェクトは明示的なsource list。新しいSwiftファイルは必要なターゲットに登録し、通常版用連携をTreeへ無条件に組み込まない。新規VS Code拡張・通信・署名／権限構成は現在のターゲット構成にはない。
- **既存試験**：WindowMatchingTestsはResolver、元ライブ窓、最小化復元、保存参照での再接続、起動失敗、明示的な前面窓選択を扱う。SnapshotCoordinator／Reducer、WorkspaceMinimization、QuickLauncher等は世代・切替・操作の参考資産。現在のQuickLauncherTestsは検索・view model・dispatchが中心で、主画面との復旧競合や内容の一致を証明しない。今回は実行していない。
- **記録の試験**：取得失敗対空集合、部分対完全、古い世代、切替退出元への正しい保存、コピー・移動・削除・同じ窓の別Board参照、復元途中・部分失敗後の上書き抑止、StoreとsavedReferenceの不一致を固定する試験が必要。
- **復旧の試験**：同一プロジェクト二窓・同名別フォルダ・同一URL重複タブ・複数root・未保存workspace・ファイルだけの窓・選択対象消失・削除済みパスを開いて空ファイルになる場合・不足対象再試行・別窓再利用・入口横断同時要求を確認する必要。
- **失敗と保護**：AX拒否、条件付きAutomation拒否、連携なし／停止／版不一致、アプリ無応答と遅延復帰、保存失敗・旧形式・未知／不正payload、診断に完全パス／URLが含まれないことを確認する必要。
- **実機証拠**：fakeの内容Resultが成功してもFinder／VS Codeの成立性は証明できない。限定した検証用窓を使い、記録内容と復元後の内容を独立に読み戻す検証が必要。別Space・フルスクリーンの制御保証は追加しない。

### 8. 工数・リスクの見立て

- **Effort：XL（2週間以上の分類）**。二つのアプリの詳細取得・適用・照合、自動記録と保存の保持、両入口の整合、追加連携の導入を含むため。既存単一URLの拡張だけなら小さくできるが、それは今回の全要求を満たす工数ではない。実測や納期の約束ではなく、成立性検証によって上下する概算分類。
- **Risk：High**。Finder全タブの公開手段が未確定で、VS Codeと実窓の一意対応・追加配布物が必要な可能性がある。加えて現行Storeの失敗時消去が内容記録の安全性と衝突する。
- **主な不確定要因**：非表示タブのURL取得、窓再利用の制御、拡張セッションの識別、Remote／Restricted Mode／特殊場所の境界、同期外部操作の中断性、内容の完全構成を観測する条件。

### 9. Research Needed — 設計で先に確認する事項

| 順 | 課題と対象要件 | 観測可能な成立条件 |
| --- | --- | --- |
| 1 | Finder取得（3.1,3.3,3.5） | 複数窓・同名別フォルダ・同一URL重複タブを使い、各窓の全URL列・順序・選択位置が独立した正解と一致する。取得不能は不足と識別し、タブラベルだけで完全としない |
| 2 | Finder適用と確認（3.2〜3.5,5.3） | 元窓閉鎖後、一つの対応窓へ順序・重複・選択を再現して読み戻す。他の窓が変わらず、一部フォルダ不可では不足項目を返す。成立しなければ詳細Finder対応の阻害事項とする |
| 3 | VS Codeと窓の対応（4.1,5.2〜5.5） | 同一プロジェクト二窓、workspaceなし、複数rootで取得・要求・結果を正しい窓へ一意対応できる。古い拡張セッションや別の送信元を受理しない |
| 4 | VS Code復元範囲（4.2〜4.6,7.4） | 単一folder、保存済み／未保存workspace、ファイルだけ、特殊入力、Remoteを区分し、成立環境の対象集合と選択が再読取りで一致する。存在しないファイルを新規作成して成功と扱わない |
| 5 | 権限・停止・導入（7.1,7.3） | 必要な権限拒否・追加連携不在／停止・Trust制限・版不一致・無応答で有限な結果へ移り、有効記録を保持する。採用する追加物の導入／更新と依存ライセンスを確認する |
| 6 | 自動記録の整合（1.2〜1.8,5.5,5.6,7.5） | 内容変更、Board退出、移動／削除、復元途中と部分失敗、共有窓で記録が正しい所有先・版へ反映される。タブ選択等が取得に必要なら利用者の選択・フォーカスとの競合を評価する |
| 7 | 保存保護と互換（8.1〜8.3,9.1） | 旧形式・未知／不正payload・保存失敗でも最後の有効なBoard・配置・記録を失わず、内容だけの更新が後の配置保存で巻き戻らない。コピー／移動／削除の意味を保持する |
| 8 | 全入口・共有利用者（6.1〜6.5,8.4,9.2〜9.4） | 主画面とLauncherで同じ要求／結果規則を確認し、自動復旧OFFでopenしない。詳細未対応の利用者とTreeが互換を保ち、診断に内容・完全URL／パスを出さない |

今回のgap分析では上記の実機PoCや外部連携実装を実行していない。設計は未知点を解消する調査を先行させて進められるが、全タブ／全ファイルの成立証拠なしに実装可能・対応完了とは判断しない。

### 10. 次フェーズへの引継ぎ

research.mdの既存調査を残したまま本分析を追記した。requirements.md、spec.json、承認状態、ソース、プロジェクト設定は変更しない。実装構成は未選定で、要件の自動承認もしない。

設計時はまずResearch Needed 1〜4の成立性を確認し、必要な追加配布物・権限・窓の識別契約を判断する。そのうえで内容の完全性・版・取得失敗・部分復元後の再試行・安全な保存の契約を定める。技術上成立しない項目は利用者へ提示し、要件を黙って狭めない。


## 設計フェーズの追加調査と統合判断（2026-10-24）

### Summary

複雑な外部アプリ連携として包括調査を実施した。既存Session／保存／復旧の契約、Finderの公開操作、VS Codeの拡張APIと窓識別を分担調査し、親担当が統合した。以下は設計候補と未解決条件であり、実装済み機能ではない。要件は `-y` により承認したが、設計レビューは未通過である。

参照した指針は `kiro-spec-design` の discovery／synthesis／review gate と `build-macos-apps:appkit-interop`。AppKitへの橋渡しを局所化し、Sessionと別の状態所有者を作らない方針へ反映した。

### Research Log — Finder

- ローカルFinder.sdefにはFinder windowのtarget、window id、ウインドウ作成があるが、全タブ列・選択タブ・タブ作成を表す契約は見つからない。これはApple Events単独では設計根拠が不足するという意味で、他の公開手段による実現不可能を意味しない。
- AXにはタブ関連属性、選択、Press、Document、URLがある。ただしFinderが非選択タブの実URLを公開すること、タブ作成後も要素識別が安定することは未確認。タブ名からURLを推測しない。
- AXの窓とApple Eventsの窓idが等しいという保証は確認できない。タイトル、位置、最前面という条件だけで別の窓への書き込みを許可しない。
- 非選択タブのURL取得にタブ選択が必要なら、自動記録そのものが利用者の操作に干渉し得る。内部の排他制御だけではFinderや利用者をロックできず、フォーカス変更時の安全な中断を検証する必要がある。
- 新しいFinder窓を作成し、その窓だけにタブを追加してtargetを設定し、全列と選択を読み戻す候補を検討した。新窓との一意対応・タブ追加先・挿入順が未確認なので、実行可能な確定バックエンドとは扱わない。
- 今回の画面読み取りではFinderのDesktopのみ取得した。利用者のタブや窓を変更していない。非表示タブのURL列や復元操作を検証できたという証拠にはならない。
- AXメッセージのタイムアウトは設定した要素に対する契約を確認し、同値の別ハンドルにも自動で適用されるとは想定しない。タイムアウト設定だけで外部操作の取り消しを保証しない。

### Research Log — VS Code

- 安定版APIのtabGroups、TabInputText、workspaceFolders、workspaceFile、showTextDocumentにより、保存済みファイル列と選択、プロジェクト情報の取得・適用を行う拡張が候補になる。拡張ホストのPIDをmacOSのアプリPIDとして扱わない。
- API調査に使った固定版は1.74.0の型定義。これは最小対応版の確定や実機互換試験を意味しない。採用時には実際の対象VS Code／Node環境を固定して検証する。
- ネイティブ側とUI拡張をローカル通信で接続する候補を検討した。型付きの取得・適用・照合要求のみ許し、任意コマンド実行口を作らない。接続世代、要求ID、期限、フレーム長、所有者とファイル権限を検証し、認証情報や完全パスは診断へ出さない。
- 拡張APIにはネイティブAX窓IDがない。同じプロジェクトの二窓をプロジェクトURIだけで区別できない。拡張が生成した一時チャレンジを対象窓のAXから確認する案は、公開されるAX情報で成立するか未検証。
- openFolder／newWindowの完了だけでは新しい窓や接続を一意に取得できない。復元先を安全に結び付ける自動手順は未確定。手動ペアリングを必須にするなら利用者フローの変更として要件へ戻す必要がある。
- ファイルだけの窓、未保存の複数root workspace、保存済みworkspaceと現在のroot列が異なる場合の扱いも決定が必要。RemoteやRestricted Modeを黙って対象外にしない。特殊入力と未保存本文は要件どおり詳細復元の対象外とし、同名ファイルへ代替しない。

### Architecture Pattern Evaluation

既存状態基盤と局所的な内容部品を併用するC案を推奨する。Sessionが所有者・世代・反映を管理し、アプリ別処理は取得／適用／照合の事実を返す。主画面とLauncherに別々の正否判定を置かない。追加拡張は独立した配布・起動・更新・互換性を持つため、共通基盤と同じライフサイクルとは扱わない。

### Design Decisions — 親担当による統合

**一般化**：FinderとVS Codeで共通なのは、完全または部分的な内容構成、観測品質、Boardごとの所有者、版、復元要求、照合結果である。アプリ固有操作は一般化せず、それぞれの能力と証拠を返す。

**採用と自作**：既存のSession、AppKit／Foundation／AX、VS Codeの安定APIとNode標準機能を優先する。既存の単一URL再接続は全内容の保存・照合を解決しないため、内容版と反映規則はプロジェクト内で定義する。ブラウザ用のセッションライブラリ、汎用プラグイン基盤、クラウド同期は導入しない。新規外部ライブラリの採用は確定していない。

**簡素化**：新しいSession、独立したBoardストア所有者、アプリごとのUI復旧状態を増やさない。共通の取得・復元調停と純粋な反映規則に絞る。VS Code内の補助拡張が必要なら境界を明示し、配布条件の決定前に通常版へ必須依存として埋め込まない。

**反映契約の候補**：

1. 所有者はBoard IDと登録参照IDの組。取得要求には所有者世代、窓接続世代、観測順序を付ける。退出元の有効な取得結果は、現在のBoardが変わっていても元の所有先へ保存できる。一方で削除・移動・再接続前の結果は拒否する。
2. 完全な構成、部分観測、取得不能を区別する。部分結果を異なる時点の要素と寄せ集めて完全状態にしない。確認できた完全な空集合と、取得失敗による空値を区別する。
3. 復元開始時の記録を固定し、復元途中の空状態で上書きしない。部分失敗後も再試行の元記録を保持する。同じ実窓を参照する別Boardにも復元操作の影響が及ぶため、抑止を所有者一つだけに限定しない。
4. 元の生存窓は再利用し内容を再適用しない。同じアプリ・同じタイトルだけの候補を内容復元成功としない。他Boardに結び付く窓への操作は実行前に拒否する。
5. 内容のみの更新は名前・順序・構成・配置を変更しない。後続の配置保存は最新の内容版を保持するよう再統合し、古いメモリ内の参照で内容を巻き戻さない。
6. 取得・適用・照合に有限の期限を設ける。論理的な要求キャンセルと既に発生した外部操作を区別し、遅い結果で現在の登録や完了状態を更新しない。詳細な秒数は実測前の保証値として記載しない。
7. 成功は起動ではなく読み戻した対象構成との照合で判断する。完全、部分、未確認、未対応、失敗を両入口で共通表示する。

**保存方式の未確定点**：現行Storeの失敗時の空配列化・保存キー削除は8.2と衝突する。内容エンベロープを個別に復号し未知版を保持すること、保存失敗で旧データを消さないことは必要。Board全体の新ファイル移行と内容専用保存のどちらを採るかは未決定。前者の移行範囲と、後者のコピー・移動・削除の同期を比較し、不要な全面移行を既成事実にしない。

### Risks and Recommendations — 設計レビュー結果

レビュー判定は **BLOCKED**。APIが存在するという調査と、要件を満たす対象窓で安全に実行できる契約を区別した。Finderの3.1〜3.5、VS Codeの4.1〜4.4と誤窓保護5.2〜5.4について未確認の前提があり、全48条件を満たす実行可能な最終設計とは評価できない。これは実現不可能の結論ではない。

独立した境界は、共通内容基盤、Finder連携、VS Code補助拡張である。特に補助拡張の導入・配布・ペアリングは既存仕様にない利用者フローを伴う。各責務の契約を固定してからspec分割の必要性を判断する。現時点で別specを自動生成したり要件を縮小したりしない。

次に必要な検証と判断は `design-readiness.md` に整理した。設計ゲートの「Write design.md only after the review gate passes.」に従い、design.mdを作成せず、design.generatedとready_for_implementationはfalseを維持する。requirements.mdは変更しない。

### References

- [Finderのタブに関するApple利用者ガイド](https://support.apple.com/en-au/guide/mac-help/mchlp1032/mac) — 利用者操作の説明。全タブ用プログラムAPIの保証とは区別。
- ローカル `/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.sdef` — Apple Eventsの語彙。
- [AXTabs属性](https://developer.apple.com/documentation/applicationservices/kaxtabsattribute)
- [AXアクション列挙](https://developer.apple.com/documentation/applicationservices/1462053-axuielementcopyactionnames)
- [AXメッセージタイムアウト](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [VS Code 1.74.0 型定義](https://raw.githubusercontent.com/microsoft/vscode/1.74.0/src/vscode-dts/vscode.d.ts)
- [VS Code Commands](https://code.visualstudio.com/api/references/commands)
- [VS Code Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host)
- [VS Code Workspace Trust](https://code.visualstudio.com/api/extension-guides/workspace-trust)
- [Node IPC](https://nodejs.org/api/net.html#ipc-support)


## 実機確認の追記

利用者の確認指示により、専用窓でFinder三タブの全パス・順序・重複・選択を読み取り、元窓を閉じた後の再構成を確認した。VS Code 1.141.2では二つのエディターグループの保存済みファイルパスを読み取れたが、両グループにselectedタブがあるためactive fileの判断にグループとフォーカスの区別が必要だった。詳細と未検証範囲は [feasibility-verification.md](feasibility-verification.md) を参照。Finderの限定条件での成立性は前進したが、raw AX／複数窓識別とVS Code補助拡張の窓対応は未確認のため、設計レビュー未通過を維持する。


### 追加検証の進捗

Finderでは二窓をウインドウメニューのフルパスで選び分け、一方へタブを追加する画面操作を確認した。利用者による入力競合を検知したため以後の操作を停止した。製品のAX要素識別・競合検知の成立性は依然として未検証。VS Codeの最小開発用拡張と隔離起動手順を専用tmpへ用意し、製品変更を伴わず次の実行確認に進める状態を準備中。実行結果はまだない。詳細はfeasibility-verification.mdへ追記した。


## 2026-10-25 VS Code検証の更新

補助拡張を実行し、二つの保存済みファイル・active file・一folderの観測結果を画面と照合した。拡張が生成する識別値を、対象のネイティブ窓配下のタブとWebview本文のAX情報から完全一致で取得できた。パネルを閉じても二ファイルと選択は保持された。単一開発ホストでの成立証拠であり、同一project二窓や新窓自動接続、raw AX、IPCまでは未検証。起動引数による完全隔離は成立を確認できず、既存拡張が表示された。詳細はfeasibility-verification.mdの同日項目を参照。設計生成状態は変更しない。


### 2026-10-25 継続調査

指定した隔離用ディレクトリの不在を確認し、F5経由の起動引数反映は未確定とした。検証用拡張に拡張ID／isActive診断を追加し構文確認、READMEを既存の実行結果と二窓照合手順へ更新した。今回は画面操作ツールが利用できず実行していない。feasibility-verification.mdへ制限を追記した。二窓・新窓の未検証状態と設計承認状態は維持する。


## 2026-10-25 公式CLI検証の更新

直接CLI起動で専用データ領域二つを使用し、一方の再起動を含む三回の取得・識別パネル表示／終了を確認した。各回で二ファイルとactive fileが一致、instanceID／challenge／sessionIDは毎回更新され、通常の外部拡張は列挙されなかった。F5経由の隔離不成立の原因そのものは未確定だが、CLI直接起動の成立条件を得た。raw AX読み取りは通常環境でも権限不在で終了し、二窓同時のAX対応付け・IPC・復元は未検証。詳細はfeasibility-verification.mdとverification-results.jsonを参照。設計生成状態は変更しない。


## 2026-10-27 二窓照合の更新

Accessibility権限が反映され、専用の同一フォルダ二窓に異なるchallengeが一意対応すること、一方の終了で旧値が消えること、再起動で新しいinstanceIDとchallengeへ更新されることをraw AXで確認した。renderer accessibilityの起動引数を付けた窓では本文のAXHeading／AXStaticTextも完全一致したが、引数なしの窓は詳細情報が取得できなかった。したがって既存の任意窓で同じ照合ができる保証は残る。パネル終了後は非同期の読み戻しが必要で、最大5秒の待機へ直した検証スクリプトの追加実行は成功した。詳細と未検証範囲はfeasibility-verification.mdを参照。製品コードと設計承認状態は変更しない。


## 2026-10-27 FinderのAX操作試験

AXメニューの新規Finderウインドウを実行したが、操作前後の参照差集合が二候補となり、新規の所有窓を一意に確定できなかった。以後のフォルダ変更・タブ操作・閉鎖は行わず中断した。CFEqualの差集合だけを安全な新窓識別契約として採用しない。次候補はFinder標準Apple Eventsの作成結果と固有URLの照合であり、別方式のため未実行。詳細はfeasibility-verification.mdに記録。Finder詳細復元と設計生成は未完了のまま。


## 2026-10-27 Finder併用経路の成立確認

許可済みApple Eventsの明示的な作成結果・固有anchorとAXを併用し、Aの三タブ（重複あり・中央選択）を完全閉鎖後の新Aへ再現できた。before/afterは一致し、比較用Bの二タブと選択も保持された。AE window IDはタブ単位で変化し、AXCloseButtonは選択タブだけを閉じたため、閉鎖の判断には不在確認が必要。AXURL／Documentはnilで、場所はAXTitleのフルパスと既知fixture／AE target URLを併用した証拠。通常ローカルフォルダの固有anchor付き検証に限る。任意の既存窓・特殊場所・多数タブ・同時操作の保証には拡張しない。詳細はfeasibility-verification.md、集計はverification-results.jsonへ追記した。製品ソースとspec承認状態は未変更。
