# Brief: window-content-restoration

## Problem

通常版WindowBoardの利用者は、Boardに登録していた窓が存在しなくなった後でFind or Reopenを実行すると、以前そのBoardで使っていた内容が戻らず、空の窓や別の内容から作業を組み直す必要がある。ブラウザのタブだけに限定せず、一般的な外部アプリの文書・フォルダ・プロジェクト・アプリ内画面も対象に、実現可能な範囲で作業を再開したい。

## Current State

以下は既存コードの静的確認であり、内容復元の実機成功を示さない。

- SavedWindowReferenceはアプリ識別情報、タイトル、文書URL一つ、任意のworkspaceURL、配置等を持つ。タブ集合やアプリ内部状態を保存するpayloadはない。
- 窓の文書URLは主にAXDocumentから取得する。同一窓の内容変更が、キャッシュされた文書URLへ常に追従する仕組みにはなっていない。
- Find or Reopenは既存窓への再接続、文書URLのオープン、アプリの起動・アクティブ化と窓の再照合を行う。現状のTerminalはホームディレクトリを開き、VS Codeでは文書URLによる再オープンを避ける。workspaceURLを内容復元へ利用する処理はない。
- 照合には同一アプリ候補へのフォールバックがあり、再接続成功と元の内容の確認は区別されていない。
- 通常版の状態所有者はWorkspaceSessionController。既存のRecoveryCoordinator／ResolverとAccessibilityWindowServiceを復旧・照合・AXの境界として使う。

根拠とアプリ種別ごとの実現可能性は `docs/discovery/window-content-restoration.md` に記録している。

## Desired Outcome

- 登録窓が生きている間に取得できた再オープン情報をBoardの登録参照に関連付け、窓が閉じた後のFind or Reopenで活用する。
- 一般のアプリには文書・フォルダ・URL等の共通手段を提供し、個別連携があるアプリでは取得・復元可能な内容を増やす。
- 登録先Boardと復元対象の対応を守り、別の同一アプリ窓を見つけただけで以前の内容が戻ったと扱わない。
- 再接続、内容を指定した再オープン、確認済みの復元、部分復元、確認不能・非対応・失敗を実際の根拠に応じて区別する。最終的な表示語句は要件・設計で定める。
- 情報取得に失敗した場合や空の新規窓へ接続した場合に、有効な保存済み復元情報を誤って失わない。

## Approach

**利用者が選択したB：共通基盤＋アプリ別連携を段階的に追加する。**

文書・フォルダ・URL等の共通の再オープン情報と、対象アプリが公開するCLI・deep link・AppleEvents・拡張等を使う個別の復元能力を組み合わせる。個別連携が使えないアプリでも共通の範囲へフォールバックし、対応不能な内部状態を復元済みと表示しない。

一般アプリの内容復元という一つの目的のもと、初期対応は共通基盤と対象を絞った個別連携による縦の実装範囲とする。全アプリへの連携を一括実装する計画にはしない。初期対象と各復元項目は後述の利用者回答で確定しており、ブラウザ拡張など独立した配布物が必要になった場合は、その導入・配布を別仕様へ分ける必要性を再評価する。

選定後の独立した実現性確認では、新たな重大なプラットフォーム上の障害は見つかっていない。ただし公開APIの存在は、特定アプリやmacOS版での動作検証を代替しない。新規の外部ライブラリは未選択であり、将来の依存の保守・ライセンスが承認済みという意味ではない。

## Scope

- **In**: 通常版の登録窓に関する再オープン情報の取得・保存・更新方針、共通復旧手段、アプリ別能力の判定と個別連携、Find or Reopenへの接続、復元結果の照合、部分復元・非対応・失敗の扱い、保存互換性、必要な権限とデータ保持の整理。
- **Out**: 任意アプリの完全な内部状態の複製、終了したプロセスのメモリやSSH接続の復活、ファイルの過去版への巻戻し、未保存編集・Undo・認証状態の共通保証、全アプリ対応の宣言、非公開アプリDBの書換え、配置保存の意味変更、Tree・分割UI試作の改修。

## Boundary Candidates

- **内容取得と能力判定**: 共通に取得できる情報とアプリ別の情報を区別する。AXを使う取得・操作は既存サービス境界内、背景実行を維持する。
- **保存と更新**: Boardの登録参照との対応、保存時点、取得失敗と明示消去の区別、互換性を扱う。Sessionを迂回した常駐状態所有者を作らない。
- **復旧の実行と照合**: 既存RecoveryCoordinatorと内容確認を接続する。Resolverの照合判断に起動・内容変更等の副作用を持たせない。
- **個別連携**: 対象アプリ・対応版・取得項目・復元項目・必要権限・結果確認方法を明示する。特定アプリだけの条件を共通AX処理へ無制限に混ぜない。
- **利用者への結果表示**: 実際に確認できた到達点を伝え、既存の登録保持・明示的な代替窓選択と整合させる。

## Out of Boundary

- 最小化worker・実行枠・復元台帳を本機能の別実装へ置き換えない。
- Follow・前面化・Save Layoutの全体再設計、Workspace型の全体改名、保存形式の無関係な移行を行わない。
- 別Boardの作業窓を無条件に再利用・上書きしない。対象アプリ全体の終了・再起動や全セッション復元を、窓単位の復元と同一視しない。
- 内容保存のための操作を、未保存文書の強制保存や任意コマンドの自動再実行へ拡大しない。
- WindowBoardにも対象アプリにも残っていない閉じた内容の回収を保証しない。

## Upstream / Downstream

- **Upstream**: 既存SavedWindowReference／WorkspaceStore、SessionのBoard所有者・世代管理、明示RecoveryCoordinator／Resolver、AccessibilityWindowService、macOSの公開APIと利用者の権限、各対象アプリが公開する復旧手段。
- **Downstream**: Find or Reopenの操作元、Quick Launcher等の共通復旧利用者、将来の追加アプリ連携。切替時自動復旧を利用する場合も既存設定と既定OFFを維持し、その接続範囲を要件で明記する。

## Existing Spec Touchpoints

- **Extends**: 現在の仕様一覧に本機能全体を扱う既存specはない。新規単一機能として扱う。
- **Adjacent**: board-switch-minimization。登録保持・古い結果の排除・再接続後の保護に接するが、最小化要求・台帳の所有権は変更しない。APP_REQUIREMENTS.md／BASIC_DESIGN.mdの配置保存方針と、未適用の次期構成設計を混同しない。

## Constraints

- Swift／SwiftUI／AppKit、macOS 14以上を対象とする既存構成を尊重する。公開APIと対象アプリが提供する入口の範囲に限る。
- AccessibilityとAppleEventsのAutomationは別の権限。連携ごとに必要性と拒否時の挙動を定め、未取得でも既存の登録を失わない。
- NSWorkspaceの起動受付やアプリが開いたことだけでは、目的の窓・内容の復元成功を判断できない。
- アプリの対応版、同じ文書の複数窓、プロファイル、既存窓へのルーティングを個別に検証する。ランタイムのタブID・窓IDだけを永続的な内容識別子にしない。
- ファイル参照の保存は内容のコピーではない。存在・アクセス権・移動、必要ならbookmarkの更新を扱う。
- URL・ファイルパス等に私的情報を含み得るため、保存・削除・診断出力の範囲を明確にする。認証情報の保存を共通復元の前提にしない。
- 既存データに対する後方互換性と読込失敗時の保持を確認し、必須項目の追加でBoard全体を失う設計にしない。
- 実装・実機検証・追加依存の導入は本discoveryでは行っていない。

## Open Decisions for Requirements

1. 初期対応はFinderとVS Codeに確定。利用者は「より詳しい復元」を選択した。Finderは全タブのフォルダ・並び・選択タブ、VS Codeはプロジェクト／workspace・開いていた保存済みファイル一覧・選択中ファイルを復元目標とする。
2. 保存方針は利用者指定によりA「そのBoardで最後に使っていた内容へ自動更新」に確定。配置のSave Layoutとは意味を分ける。具体的な取得方法・頻度は設計で検討し、先に閉じた窓や取得失敗をどう扱うかは要件に反映する。
3. 要件では、別Boardへの復元だけを理由に他Boardの保存済み内容を置き換えない。共有窓や同じ文書の複数窓を識別する具体的な方法は設計で定める。
4. 要件では、内容未確認の別窓を復元成功として自動確定せず、既存の明示的な代替窓選択を維持する。確認方法は設計で定める。
5. 拡張・追加権限・別配布物が必要な連携の初期採否と、独立specへ分ける条件。

## Feasibility Evidence

- [AX属性取得と未対応・失敗](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [指定アプリでURLを開くNSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))
- [VS Code公式CLI](https://code.visualstudio.com/docs/configure/command-line)
- [AppleEvents entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
- [Chrome拡張とnative messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)、[Incognito](https://developer.chrome.com/docs/extensions/reference/manifest/incognito)

これらは方式の成立条件を確認する根拠であり、本プロジェクトでの連携実装・実機動作を示すものではない。

## Requirements Clarification Record

利用者回答「finder,vscodeでA」により、初期の個別対応はFinderとVS Code、内容保存は最後に使っていた内容への自動更新と確定した。各アプリで保存・復元する内容の粒度は、この回答だけから全タブ・全ファイル対応と推定しない。

利用者は続けて「より詳しい復元で」と回答し、上記のFinder全タブ構成とVS Codeのプロジェクト／workspace・開いていたファイル一覧・選択中ファイルを要求範囲に確定した。要件書は9領域・48基準で生成したが、利用者承認・実装・実機検証は未完了。Finder全タブを取得・再現できる公開手段は後続の実現性確認事項であり、単一フォルダ対応へ黙って縮小しない。
