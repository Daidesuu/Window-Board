# Boardごとのウィンドウ内容復元：実現可能性調査

2026-10-23。kiro-discoveryでの調査。対象は通常版の一般的な外部アプリ。コード変更・アプリ操作・実機検証は行っていない。実装確認、公式APIの事実、それらからの設計上の判断を区別する。利用者はB（共通基盤＋アプリ別連携）を選択した。要件・設計・タスクの確定や実装承認を意味しない。

## 問題と到達目標

Boardの登録ウィンドウが存在しないとき、Find or Reopenでアプリを開いても、そのBoardで使っていた内容が戻らない。ブラウザだけでなく、文書・フォルダ・プロジェクト・アプリ内画面などを可能な範囲で再開したい。

調査上の結論は、アプリを問わず任意の内部状態を完全保存する仕組みではなく、まず「何を開くか」を保存し、アプリが公開する機能に応じて「どこまで状態を戻すか」を拡張する方法が現実的、というもの。これはAPI上の見込みであり、特定アプリの実機保証ではない。

## 現在の実装で確認できたこと

- `WindowBoard/Models/SavedWorkspace.swift:150` のSavedWindowReferenceは、アプリ識別子・タイトル・文書URL一つ・workspaceURL・配置を保存する。タブ集合や編集状態を保存するpayloadはない。
- 同ファイルmake／makePreservingOffsetはworkspaceURLStringをnilで初期化する。調査範囲ではworkspaceURLを一般的な内容復元に利用する処理はない。
- `WindowBoard/Services/AccessibilityWindowService.swift:715` は窓自身のAXDocumentだけを取得し、UI内のタブ等を走査しない。
- `WorkspaceSessionController.currentWorkspaceReferences` の文書識別はキャッシュ済みWindowInfoに依存する。Snapshotはタイトル更新時に既存documentURLを保持するため、同一窓で開く文書が変わるとURLが古い可能性がある。静的に確認したリスクで、再現試験は未実施。
- `AccessibilityWindowService.openSavedWindowReference` は、VS Code以外では取得済み文書URLを開き、Terminalではホームディレクトリを開き、それ以外はアプリの起動・アクティブ化へ進む。workspaceURLを開く処理はない。
- `AttachedWindowRecoveryCoordinator.recover` は既存窓の再利用を試み、開く要求後に列挙・照合する。内容の適用・確認工程はない。
- `WindowMatching.bestSavedWindow` は文書URL・タイトル照合後に同一アプリの先頭候補へフォールバックする。「Reconnected」は以前の内容を確認したことと同義ではない。

今回の症状は単純に復旧の待ち時間を延ばすだけでは解決できない。内容の事前取得・保存、再オープン方法、復元結果の照合が必要になる。

## 公開APIの事実と限界

- AppleのAXDocumentは、そのAccessibilityオブジェクトが表す文書URL。すべてのアプリ・すべてのタブがこの属性を提供する契約ではない。[AXDocument](https://developer.apple.com/documentation/applicationservices/kaxdocumentattribute)、[属性取得](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- NSWorkspace.openは指定アプリでURLを開く。成功時の結果はアプリであり、特定の窓の内部状態復元を保証するものではない。[NSWorkspace.open](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))
- NSWindowRestorationは、対象アプリ自身が保存した状態を使って自分の窓を再生成する仕組み。WindowBoardが他アプリの内部状態を共通形式で取得・復元できるという意味にはならない。後半はAPIの責務からの判断。[NSWindowRestoration](https://developer.apple.com/documentation/appkit/nswindowrestoration/restorewindow(withidentifier:state:completionhandler:))
- ファイルbookmarkはファイルへの参照であり、以前のファイル内容のコピーではない。Sandbox対応ではアクセス権とstale bookmarkの扱いも必要。[ファイルアクセス](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

## アプリ種別ごとの見込み（実機未検証）

| 種別 | 復元を目指せるもの | 共通対応で保証しないもの |
| --- | --- | --- |
| 文書・PDF・画像 | 保存済みファイルを元のアプリで開く。必要に応じbookmarkで参照を維持 | 未保存編集、過去版、Undo、選択範囲、ページ位置。位置等は個別連携なら検討可能 |
| Finder等のフォルダ画面 | フォルダURLを開く。表示方法・選択項目等は個別連携を調査 | 元のタブ構成や窓と一対一での対応 |
| IDE・制作アプリ | プロジェクト／workspace／ファイルを開く。公開CLIや専用URLを利用 | 全編集タブ、未保存バッファ、デバッガ状態、再生・レンダリング途中の状態 |
| Terminal | 個別連携・明示指定で作業フォルダ、プロファイル、保存されたwindow groupを扱う候補 | 終了したプロセス、SSH接続、実行途中のメモリ状態。コマンド再実行は状態復元と別の操作 |
| ブラウザ | 個別連携・拡張で窓ごとのURL集合、順序、固定タブ等を保存・再作成する候補 | 入力途中、ページ内メモリ、戻る履歴、認証状態、プライベート閲覧の無条件復元 |
| チャット・クラウド・業務アプリ | 公開された会話／文書／画面のdeep linkやアプリAPI | 外部から指定する入口がない画面・内部状態 |
| 再オープン情報を公開しないアプリ | アプリ起動・手動再接続を残す | 自動で以前の内容が戻るという表示・保証 |

保存済みファイルを開く場合も、その時点のファイル内容を開くのであって、Board保存時点の版へ巻き戻す機能ではない。閉じる前にWindowBoardも対象アプリも保存していなかった情報は、一般の仕組みでは後から復元できない。

### 具体例の公式根拠

- VS Codeはファイル・フォルダ・workspaceや行／列を指定するCLIを持つ。ただし現行WindowBoardはまだこれを内容復元へ接続していない。[CLI](https://code.visualstudio.com/docs/configure/command-line)、[workspace](https://code.visualstudio.com/docs/editing/workspaces/multi-root-workspaces)
- Terminalは新規窓の作業ディレクトリ設定とwindow groupを提供する。これだけでWindowBoardから任意窓の内容を取得できるとは断定しない。[作業ディレクトリ](https://support.apple.com/guide/terminal/trmlstrtup/mac)、[window group](https://support.apple.com/guide/terminal/trml15652/mac)
- ChromeのTabs APIはURL・順序・固定状態等を扱う。URL取得には権限が必要で、拡張の導入・対応ブラウザ・プロファイルごとの検証が別途必要。[Tabs](https://developer.chrome.com/docs/extensions/reference/api/tabs)、[Groups](https://developer.chrome.com/docs/extensions/reference/api/tabGroups)、[Incognito](https://developer.chrome.com/docs/extensions/reference/manifest/incognito)
- AppleEventsの個別連携にはAutomation権限・利用目的説明・配布設定を検討する。Accessibility権限と同じものとしない。[利用目的](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)、[entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)

## 検討する方式

### A：共通の再オープン情報だけを整える（小〜中）

文書・フォルダ・URL等を事前に取得し、Boardの登録参照に保持して、Find or Reopenで使う。アプリ別の内部状態は扱わない。依存と保守が少ない一方、URLを取得できないアプリやタブ集合には届かない。取得失敗と消去を区別し、既存の情報を空の新規窓で上書きしない必要がある。

### B：共通基盤＋アプリ別連携を段階的に追加する（中、対象追加で拡大）

Aを基礎に、取得可能な内容と復元方法をアプリ別に登録する。公開CLI・deep link・AppleEvents・拡張等を使い、非対応アプリはAの範囲へ戻す。到達範囲を広げやすいが、アプリや権限・バージョンごとの検証と保守が必要。利用者が選択した方針。

任意のアプリの完全セッション複製は、独立した第三案として保証できる根拠がない。アプリ自身のセッション保存を利用する場合も、Boardをまたぐ他の窓への影響を確認する。

## 既存アーキテクチャとの境界候補

- 保存対象：Boardの登録参照に復元用情報を持たせる。Sessionが保存・世代・適用対象を所有する。
- 取得・操作：共通AXは既存AccessibilityWindowServiceの境界内。個別連携は能力を明示した処理として分離し、別の常駐Sessionを作らない。
- 復旧：既存RecoveryCoordinatorへ開く要求と結果確認を接続。Resolverは照合を担当し、内容復元の副作用を持たせない。
- 結果：既存窓へ再接続、指定内容を開いて確認、部分復元、非対応／失敗を区別する。別の同一アプリ窓を見つけただけで内容復元成功にしない。
- 既存spec：board-switch-minimizationとは隣接する。最小化要求・実行枠・台帳の仕様を拡張するものではなく、新しい内容保存・復元の仕様候補。
- 対象外：Tree・分割UI試作・配置保存意味の変更・Workspaceの全体改名・任意プロセスのメモリ保存・非公開のアプリDB書換え。

## 方式選定後に決める点

1. 保存時点：Board退出時の自動記録、明示的な内容保存、または併用。配置のSave Layoutとは意味を分ける。
2. 取得時点：閉じた後ではなく、生きているうちの取得が必要。退出時だけでは先に閉じられた窓を取りこぼす可能性がある。
3. 同じアプリ・同じ文書の複数窓や、複数Boardからの同じ実窓参照をどう扱うか。
4. 元の内容を確認できない場合に、別窓へ接続するか、利用者の選択を待つか。
5. 初期の個別連携対象。一般的な基盤を作っても、全アプリの内部状態対応を一括で約束しない。
6. 保存情報の互換性・ファイルアクセス・URL等のプライバシーと削除。現在のStoreには全体JSONの読込失敗時の制約があるため、安易な必須項目追加を避ける。

B選択後に独立した実現性確認を行い、新たな重大障害なしと判断した。権限・対象アプリごとの確認・追加配布物の導入が必要となる制約をBriefへ記録した。Briefは `.kiro/specs/window-content-restoration/brief.md` に保存。初期対応アプリや保存タイミングは要件段階の未決事項で、実装は開始していない。
