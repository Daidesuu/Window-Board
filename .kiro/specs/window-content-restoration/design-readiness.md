# 内容復元の設計確定に必要な条件

状態：設計レビュー未通過。実装指示書ではなく、未解決の前提と合格条件を整理した文書。要件の範囲は変更しない。

## 先行検証

| 対象 | 検証内容 | 合格条件 | 関連要件 |
| --- | --- | --- | --- |
| Finder取得 | 二窓、同名別フォルダ、同一フォルダの重複タブ、非選択・溢れたタブ | 各窓のURL列、重複数、順序、選択位置が独立した正解と一致。不明項目を識別できる | 3.1, 3.3, 3.5 |
| Finder窓の対応 | AX要素とApple Events対象、新窓作成後・タブ追加後の識別 | 別窓を操作せず一意に対応できる。対応が失われたら操作前に停止 | 3.2, 5.2, 5.3 |
| Finder復元 | 元窓消失後に一窓へ重複を含む全タブを作成し選択を復元 | 全列を読み戻して照合。他窓不変。存在しないフォルダは項目別の不足となる | 3.2, 3.3, 3.4, 3.5 |
| Finderの操作競合 | 取得中・復元中の利用者によるタブ選択とフォーカス変更 | 利用者の選択を無条件に戻さず、誤窓へ続行しない。拒否・停止も有限に終了 | 1.2, 7.1, 7.3 |
| VS Code窓の対応 | 同じプロジェクトの二窓、拡張再起動、再接続、新窓 | 拡張接続と登録対象の実窓が一意に対応。タイトルやプロジェクト一致だけで認定しない | 4.1, 5.2, 5.3, 5.5 |
| VS Code新窓 | 新窓を開き拡張に復元要求を届ける | 古い接続・他Boardの窓を再利用しない。自動対応が不成立なら必要な手動手順を明示 | 4.2, 5.3, 5.4 |
| VS Code構成 | 単一folder、保存済み・未保存の複数root、ファイルのみ、Remote、Trust制限 | 保存済みファイル集合とactive fileを照合。不存在ファイルの新規作成や別projectへの混入を成功にしない | 4.2, 4.3, 4.4, 4.5, 4.6, 7.4 |

検証には専用の窓と既知のテスト用フォルダ／保存済みファイルを使う。利用者の既存窓や未保存内容を検証素材として変更しない。権限の新規許可が必要になった場合は、その時点で必要性を説明する。

## 要件へ戻して確認する判断

- VS Codeの補助拡張を利用者が導入する前提を許容するか。必要なら導入なしの共通復旧と詳細復元を区別する。
- 新窓の安全な自動識別が成立しない場合、利用者による明示的なペアリングを詳細復元の途中に含めてよいか。
- 自動のFinder取得にタブ選択が必要だった場合、利用者の操作に干渉しない取得をどこまで成立させられるか。実機検証の結果と代替を示してから判断する。
- 補助拡張を独立specとし、本specでは共通の要求・結果・所有者契約を所有する分割が必要か。

これらは未承認の案であり、本書の作成によって必須手順や対象外条件を追加しない。

## 境界と変更箇所の候補

| 責務 | 新規候補 | 既存の接続先 |
| --- | --- | --- |
| 内容の構成・品質・版・反映規則 | WindowBoard/Models/WindowContentRecord.swift、WindowBoard/Models/WindowContentReducer.swift | WindowBoard/Models/SavedWorkspace.swift |
| 共通の取得・復元調停 | WindowBoard/Services/WindowContentCaptureCoordinator.swift、WindowBoard/Services/WindowContentRecoveryCoordinator.swift | WindowBoard/App/WorkspaceSessionController.swift |
| Finder取得・適用・照合 | WindowBoard/Services/FinderContentAdapter.swift | WindowBoard/Services/AccessibilityWindowService.swift |
| VS Code通信と対象窓の対応 | WindowBoard/Services/VSCodeContentBridge.swift、WindowBoard/Services/VSCodeWindowBindingCoordinator.swift | 既存Session、Integrations/VSCodeCompanion/（新規候補） |
| 内容の安全な保存 | 保存方式決定後に必要最小限の追加ファイルを確定 | WindowBoard/Stores/WorkspaceStore.swift |
| 共通結果を使う両入口 | 新たな状態所有者は作らない | WindowBoard/Views/ContentView.swift、WindowBoard/Launcher/QuickLauncherIntegration.swift |

上記は最終ファイル構造計画ではない。実在する接続先は設計確定時に再照合する。内容更新による名前・順序・構成・配置の変更、Treeの行動変更、未保存本文の保存、任意コマンド実行、汎用連携基盤はこの機能の責務に追加しない。

## 再開条件

先行検証の証拠と利用者フローを確定し、必要ならrequirements.mdまたはspec境界を更新してから設計生成を再実行する。最終design.mdでは全48条件の対応表、型付き契約、保存互換、期限・キャンセル、両入口の状態遷移、具体的な試験を揃えて再レビューする。単一URLだけの復元や未対応表示を、詳細復元要件の代替達成として扱わない。


## 実機確認の追記

利用者の確認指示により、専用窓でFinder三タブの全パス・順序・重複・選択を読み取り、元窓を閉じた後の再構成を確認した。VS Code 1.141.2では二つのエディターグループの保存済みファイルパスを読み取れたが、両グループにselectedタブがあるためactive fileの判断にグループとフォーカスの区別が必要だった。詳細と未検証範囲は [feasibility-verification.md](feasibility-verification.md) を参照。Finderの限定条件での成立性は前進したが、raw AX／複数窓識別とVS Code補助拡張の窓対応は未確認のため、設計レビュー未通過を維持する。


## 2026-10-25 VS Code検証の更新

補助拡張を実行し、二つの保存済みファイル・active file・一folderの観測結果を画面と照合した。拡張が生成する識別値を、対象のネイティブ窓配下のタブとWebview本文のAX情報から完全一致で取得できた。パネルを閉じても二ファイルと選択は保持された。単一開発ホストでの成立証拠であり、同一project二窓や新窓自動接続、raw AX、IPCまでは未検証。起動引数による完全隔離は成立を確認できず、既存拡張が表示された。詳細はfeasibility-verification.mdの同日項目を参照。設計生成状態は変更しない。


## 2026-10-25 公式CLI検証の更新

直接CLI起動で専用データ領域二つを使用し、一方の再起動を含む三回の取得・識別パネル表示／終了を確認した。各回で二ファイルとactive fileが一致、instanceID／challenge／sessionIDは毎回更新され、通常の外部拡張は列挙されなかった。F5経由の隔離不成立の原因そのものは未確定だが、CLI直接起動の成立条件を得た。raw AX読み取りは通常環境でも権限不在で終了し、二窓同時のAX対応付け・IPC・復元は未検証。詳細はfeasibility-verification.mdとverification-results.jsonを参照。設計生成状態は変更しない。


## 2026-10-27 二窓照合の更新

Accessibility権限が反映され、専用の同一フォルダ二窓に異なるchallengeが一意対応すること、一方の終了で旧値が消えること、再起動で新しいinstanceIDとchallengeへ更新されることをraw AXで確認した。renderer accessibilityの起動引数を付けた窓では本文のAXHeading／AXStaticTextも完全一致したが、引数なしの窓は詳細情報が取得できなかった。したがって既存の任意窓で同じ照合ができる保証は残る。パネル終了後は非同期の読み戻しが必要で、最大5秒の待機へ直した検証スクリプトの追加実行は成功した。詳細と未検証範囲はfeasibility-verification.mdを参照。製品コードと設計承認状態は変更しない。


## 2026-10-27 FinderのAX操作試験

AXメニューの新規Finderウインドウを実行したが、操作前後の参照差集合が二候補となり、新規の所有窓を一意に確定できなかった。以後のフォルダ変更・タブ操作・閉鎖は行わず中断した。CFEqualの差集合だけを安全な新窓識別契約として採用しない。次候補はFinder標準Apple Eventsの作成結果と固有URLの照合であり、別方式のため未実行。詳細はfeasibility-verification.mdに記録。Finder詳細復元と設計生成は未完了のまま。


## 2026-10-27 Finder併用経路の成立確認

許可済みApple Eventsの明示的な作成結果・固有anchorとAXを併用し、Aの三タブ（重複あり・中央選択）を完全閉鎖後の新Aへ再現できた。before/afterは一致し、比較用Bの二タブと選択も保持された。AE window IDはタブ単位で変化し、AXCloseButtonは選択タブだけを閉じたため、閉鎖の判断には不在確認が必要。AXURL／Documentはnilで、場所はAXTitleのフルパスと既知fixture／AE target URLを併用した証拠。通常ローカルフォルダの固有anchor付き検証に限る。任意の既存窓・特殊場所・多数タブ・同時操作の保証には拡張しない。詳細はfeasibility-verification.md、集計はverification-results.jsonへ追記した。製品ソースとspec承認状態は未変更。
