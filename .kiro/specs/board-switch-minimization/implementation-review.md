# 実装統合レビュー — Board切替時の最小化

更新日: 2026-10-23 / 対象: タスク7.1

## 判定と検証範囲

タスク1.1〜6.5のコミット差分（基点 `9c973661`、終点 `8acd3a1`）と現在の実装を確認した。新しい要求状態・実行枠・復元台帳は既存Session内にあり、独立した常駐所有者、保存形式移行、配置保存の意味変更は導入していない。静的確認で未解決の重大な本番不具合は見つかっていない。最終完了判定ではなく、7.2の通常版ビルド・起動・Tree互換と7.3の実AX操作は別の未完了項目である。

以下のテスト名は実在するXCTestメソッドを示す。表のテストは原則 `WorkspaceMinimizationTests`、`Executor` は `WindowMinimizationExecutorTests`、`Policy` は `WindowMinimizationPolicyTests`、`Inspection` は `WindowOperationInspectionTests` を指す。fakeサービスの検証を実機の証拠とは扱わない。

## 33基準の対応

| 基準 | 本番実装の具体的な入口・処理 | 対応する検証 |
| --- | --- | --- |
| 1.1 | Session `materializeAutomaticRequest` → `launchAutomaticMinimization` → Executor `run` | `testCachedSwitchPublishesBeforeCandidateRefreshAndMinimizesNewWindow` |
| 1.2 | Sessionの登録解決結果と `CandidateSource.refresh`、Executorの最大一回の補完 | `testCachedSwitchPublishesBeforeCandidateRefreshAndMinimizesNewWindow`、`testAutomaticCandidateCoverageUsesFreshIdentityAndOnlyFailedScopeFallbackOnce` |
| 1.3 | Session `acceptSwitchIntent` / `materializeAutomaticRequest` のautomaticEnabled検査 | `testSwitchResolutionReportReusedAndOffOrEmptyAddsNoFeatureCalls` |
| 1.4 | Session `materializeAutomaticRequest` の合成登録集合検査 | `testOffEmptyInvalidAndStaleMaterializationDoNotCreateWork`、`testSwitchResolutionReportReusedAndOffOrEmptyAddsNoFeatureCalls` |
| 2.1 | Session `switchWorkspace` のplaceholderと解決反映後に自動要求を起動 | `testCachedSwitchPublishesBeforeCandidateRefreshAndMinimizesNewWindow`（列挙gate中の表示更新） |
| 2.2 | Session `acceptSwitchIntent` と単一pending、読込み待機のprivate再投入 | `testQueuedDifferentTargetsInvalidateAtAcceptanceAndReplayOnlyLatestContext`、`testThreeSwitchesWhileOldWriteHeldConvergeOnlyToLatestBoard` |
| 2.3 | Session `updateMinimizationProgress` / `displayStatusMessage`、Status Item `statusUpdates(for:)` | `testProgressProjectionRetainsLatestBusyUntilLastSlotFinishes`、`testStatusItemSubscriptionPublishesProgressWithoutStatusMessageMutation` |
| 3.1 | Session `pendingAutomaticMinimization`、`finishOperation` / `takeNextMinimizationOperation` | `testThreeSwitchesWhileOldWriteHeldConvergeOnlyToLatestBoard` |
| 3.2 | Session `startManualMinimizationOperation` / `completeMinimization` の共通終端 | `testManualInflightSuccessOrFailureKeepsLatestWorkerBusyAndPhysicalLedger`、`testEmptyOrFailedManualPreparationStillHandsOffToLatestAutomaticRequest` |
| 3.3 | Session `requestMinimizationReconcile`、Executor固定候補再分類と最新保護照会 | `testDeferredRecoveryReclassifiesFixedCandidatesWithoutEnumeration`、`testRecoveryWhileFullSnapshotPendingRevisitsFormerlyRegisteredCandidate` |
| 3.4 | Session `isCurrentMinimizationOperation` / `canApplyMinimizationReceipt` / 完了所有者guard | `testStalePhysicalSuccessIsRecordedWithoutPublishingOldUIAndDuplicateIsIdempotent`、`testManualPreparationDoesNotOverwriteReconnectedAttachmentInSameIntent` |
| 3.5 | Executor `run` 内 `operate` の読取前・書込直前authorize、取消確認 | Executor `testStopAfterReadPreventsWriteAndPreservesSnapshot`、`testInFlightWriteRecordsSuccessBeforeStoppingNextOperation` |
| 3.6 | Sessionの旧成功記帳と最新登録の復元許可、Executor `restoreAttachment` | `testInflightOldSuccessRecordedAndLatestSwitchRestoresItsAttachment`、`testThreeSwitchesWhileOldWriteHeldConvergeOnlyToLatestBoard` |
| 4.1 | Policy `classify`、Session `protectionSnapshot` / `authorizeStep` | Executor `testReplacementReclassifiesPreviouslyRegisteredCandidateWithoutRelisting`、`testThreeEntryPathsPreserveComposedProtectionAndSavedStateWithAutomaticOnOrOff` |
| 4.2 | Executor `eligibleWindow` と登録復元ループ、書込前の同identity/handle照合 | Executor `testAvailableAttachmentsRestoreAndFailedRestoreDoesNotStopOthers`、`testRestoreReplacementDuringReadDiscardsOldObservationAndUsesLatestHandle` |
| 4.3 | 保護集合に利用不能登録を保持し、復元はavailableかつ非reconnectingのみ | Executor `testFinalFingerprintCheckReclassifiesAndUnavailableReconnectingRecordsStayUntouched`、`testMissingRecoverySettingControlsRealOpenActivateAndPollingForSameReferences` |
| 4.4 | Policy `classify` の既存Terminal・曖昧同一アプリ・VS Code例外 | Policy `testTerminalProtectsDistinctNumberDocumentAndTitleButOnlyWhenAvailable`、`testAmbiguityFallbackAndConcreteDisambiguation`、`testVSCodeNeverUsesAmbiguousProtectionIncludingMissingBundleFallback` |
| 4.5 | Session `requestMemberSelection` / `selectMemberBoard` は最小化intent非発行 | `testMemberSelectionWithinDisplayedCompositionDoesNotIssueIntentOrWindowWork` |
| 5.1 | Executor各receipt反映後の続行、Session明示復元の対象ごとのdo/catch | Executor `testKnownManualNoOpUnknownAndWriteFailureContinueToSuccess`、`testExplicitRestoreRetainsUnknownAndFailedTrueThenCommitsBeforeNextRead` |
| 5.2 | Session `commitReceipt` の累積summary、`completeMinimization` の最新結果表示 | `testReconcileRetainsFailureAndAutomaticSnapshotAfterManualCompletion`、`testLauncherAutomaticProgressFeedsStatusItemAndResumesSnapshotsAfterFailure` |
| 5.3 | AX `inspectWindows` / `aggregateInspections`、coverage・issuesの維持 | Inspection `testProductionAggregationDistinguishesZeroPartialAndFailure`、`testDiagnosticNormalZeroAndEnumerationFailureRemainDistinct` |
| 5.4 | Session `commitReceipt` は古いintentの物理成功も先に台帳へ反映 | `testStaleManualPhysicalSuccessRemainsRestorableThroughPublicOperation`、`testStalePhysicalSuccessIsRecordedWithoutPublishingOldUIAndDuplicateIsIdempotent` |
| 5.5 | Session `restoreMinimizedWindows`、AX `minimizedObservation` | `testKnownManualNoopAndFailuresMatchPhysicalEventsAndCanRetry`、`testExplicitRestoreRetainsUnknownAndFailedTrueThenCommitsBeforeNextRead` |
| 5.6 | Executor `operate` の `.alreadyDesired` | Executor `testKnownManualNoOpUnknownAndWriteFailureContinueToSuccess`、`testOnlyChangedMinimizationCreatesLedgerEntry` |
| 5.7 | Session `commitReceipt` の版一致削除・unknown/失敗保持 | `testExplicitRestorePreservesNewVersionAndOtherEntryDuringWrite`、`testExplicitRestoreRetainsUnknownAndFailedTrueThenCommitsBeforeNextRead` |
| 5.8 | Session `commitReceipt` はdesiredMinimizedかつ `.changed` だけ追加 | `testOnlyChangedMinimizationCreatesLedgerEntry` |
| 6.1 | 主画面・Status Itemから `switchWorkspace`、Launcherから `switchWorkspaceFromLauncher` → 同じ要求処理 | `testThreeEntryPathsPreserveComposedProtectionAndSavedStateWithAutomaticOnOrOff`（実メニュー選択は7.3） |
| 6.2 | 最小化台帳はメモリ内、Storeへ最小化結果を書き込まない | `testThreeEntryPathsPreserveComposedProtectionAndSavedStateWithAutomaticOnOrOff`（保存名・順・所属・配置比較） |
| 6.3 | 既存 `shouldRestoreMissingWindows` と背景復旧の元intent検査を維持 | `testMissingRecoverySettingControlsRealOpenActivateAndPollingForSameReferences`（fakeのopen/activate/poll実呼出数） |
| 7.1 | Policy分類、Executor `OperationSummary`、Session `emitDiagnostic` | `testDiagnosticMixedCandidatesAndOperationFailures` |
| 7.2 | Executor `apply` のchanged/alreadyDesired/readFailed/writeFailed別集計 | `testDiagnosticMixedCandidatesAndOperationFailures`、`testDiagnosticOperationBoundariesAndSanitizedSummary` |
| 7.3 | Session `emitDiagnostic` started/superseded/finished/handoffとintent/operation関連付け | `testDiagnosticOperationBoundariesAndSanitizedSummary` |
| 7.4 | 既存操作入口・status表示の自動購読、診断表示を必須にしない | `testLauncherAutomaticProgressFeedsStatusItemAndResumesSnapshotsAfterFailure`、通常UI静的接続確認（実操作は7.3） |

## 責務・並行処理・保存のレビュー

- `WorkspaceSessionController` が要求受付世代、最新pending最大一件、手動/自動共通実行枠最大一件、task handle、進捗、台帳を所有する。`finishOperation` は所有operation/intentが一致するときだけ解放し、次要求を返す。`completeMinimization` は返された要求を起動する。読込みrevisionと受付intentは別用途である。
- Executorは一要求の局所状態だけを持つ。`run` はnonisolated async、実際の呼出元もTask.detachedであり、サービスのAX読取/書込をMainActorへ移していない。Session更新コールバックだけMainActorへ戻る。新しい無条件のSendable保証は追加していない。
- 失効は協調的で、実行中の同期AX書込を強制停止しない。書込結果は必ずreceiptとしてawait反映してから次操作に進む。読取前の許可と保護照会は原子的ではないが、書込直前に再許可し、有効な書込許可からAX書込まで追加のawaitを挟まない。
- 保護集合の変化は固定候補全体の再分類を生む。全列挙の反復や常時監視は追加しない。継続的な外部変更下でのループ回数や終了時間は保証しない。「操作が落ち着いた」条件（3.3）の下で整える設計であり、実測していない時間性能は記載しない。
- `commitReceipt` は物理的な成功と現行UI適用を分ける。復元削除は取得時のentryVersion一致が必要で、古い復元が新しい最小化記録を消さない。明示復元と自動処理の新しい優先順位は作っていない。
- `completedMinimizationOperations` は終了後の重複receiptを拒否するUUID集合でSession寿命まで増える。窓/AX要素を保持せず、一operationにつきUUID一件。step集合は終了時解放する。長時間・高頻度操作ではメモリが無制限に増える点は非阻害の保守課題で、実測メモリ量や上限保証はない。任意の件数で切ると遅延duplicateを再受理するため、本タスクで根拠なく変更しない。
- 診断はタイトル・文書URL・任意のwindowIDを新たにLoggerへ出さず、stage/PID/failure別集計とUUIDを送る。従来の他ログ全体を匿名化する変更ではない。
- AXの共通診断型のみTreeへ追加登録し、最小化要求モデル・Session・ExecutorをTreeへ追加していない。Treeの最新コンパイルは7.2で別に確認する。
- コミット差分で本番変更は設計表のSession、Status Item、AXサービス、新Models/Executor、ターゲット登録に限る。作業ツリーにあるAPP_REQUIREMENTS、App、Store、Views、スクリプト等の既存利用者変更は本タスクで変更・巻戻ししない。保存モデルのCodableや保存キーを変更しない。

## テスト安定化

既存のSnapshot旧世代結果破棄テストは、15 msの固定sleepで初回samplerが開始したと仮定していた。開始が遅れると再起動後が初回となり、sample-2期待が成立しない。初回開始expectationと再開gateを導入し、取消後も戻るAXに似た旧結果と新世代consumeを待つ。

既存Fronting再予約テストは30 ms後に処理済みと仮定していた。最新処理の実行expectationを待ち、旧処理0・最新1を確認する。いずれも本番コードの振る舞いは変更しない。`WindowMatchingTests.testNewerSwitchRemainsActiveWhenPreviousResolutionFinishesLater` は既存の制限時間付き待機を維持し、本タスクでは触れない。

## 実行結果と残る境界

新鮮な全件XCTestは285件、失敗0、終了コード0、`TEST SUCCEEDED`。ログは `build/minimization-task-7.1-tests-fresh.log`。コマンドは `xcodebuild -project WindowBoard.xcodeproj -scheme WindowBoard -configuration Debug -derivedDataPath build/IntegrationDerivedData test` を `/private/tmp/wb-minimization-task-7.1` で実行した。通常の `build/DerivedData` へ既存依存をコピーする準備が停止し、Sparkle manifest未到着の依存解決失敗になったため、同じbuild配下の新規DerivedDataから依存解決して検証した。四つのソースディレクトリ全109ファイルをバイト比較し不一致0を確認した。

初回準備中にコピー先project未作成で実行してしまい、xcodebuildはproject不存在で終了した。また上記の不完全な依存コピーでの実行もテストに到達していない。いずれも成功証拠に含めない。

コンパイル警告はSession明示復元の `MainActor.run` 戻り値未使用、既存試作テストのSwift 6移行時Actor警告、App Intents依存なしのメタデータ抽出skipを確認した。今回の新しい隔離違反警告は検出していない。Sessionの警告は台帳適用のBoolを意図的に使わない箇所で、動作不具合ではない。

既存 `build/minimization-task-5.5-telemetry.log` はXCTest中の実Logger観測で、fake sinkのみの観測ではない。ただし実外部窓の最小化証拠ではない。単一worker・最大同時書込1のgate試験は、すべてのAX処理を全体で直列化した証明ではない。

通常版GUIの起動、実メニュー/Launcher操作、制御用外部窓への最小化・復元、Terminal保護、閉窓/応答失敗は7.2/7.3で確認する。別Space・フルスクリーン・厳密なz-orderは保証しない。
