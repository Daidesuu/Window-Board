# Window Board

## 現在の到達点

当初の「ボードを動かすと選択した1つのウインドウが追従する」MVPは完了済みである。

現在の Window Board は、単一ウインドウ追従MVPではなく、複数の外部ウインドウを workspace として保存・復元する macOS window session manager 段階に入っている。

---

## Current Implementation

### 主要機能

- 複数ウインドウの attach / detach
- `Attach Frontmost Window`
- Follow Mode
  - `None`
  - `Smooth`
  - `On Release`
- 位置更新モード
  - 明示的な `Update Position`
  - attach時の相対位置維持
- attached window の前面化
- WindowBoard の一時的な前面維持
- `Keep Window Board On Top`
- workspace の保存 / rename / overwrite / delete / switch
- workspace の位置保存・復元
- workspace のウインドウサイズ保存・復元
- Status Item からの workspace 切り替え
- Settings 画面
- `Open / Reconnect`
- `Minimize Unattached`
- `Restore Minimized`
- `Minimize Unattached On Workspace Switch`

---

## Current Architecture

### WindowBoardAppState

アプリ全体の共有オブジェクトと設定値を保持する。

- `WorkspaceStore`
- `WorkspaceSessionController`
- Settings 用の `Follow Mode` / `Position Update` / `Auto Front` / `Board Click Action`
- WindowBoard の `NSWindow` 参照
- Status Item controller との接続

### WorkspaceSessionController

workspace の実行状態と切り替え処理の中心。

責務：

- active / selected workspace 管理
- attached window list 管理
- unavailable / reconnecting 状態管理
- minimized window 履歴管理
- workspace 保存・上書き・rename・delete
- workspace switch
- `Open / Reconnect`
- `Minimize Unattached`
- `Restore Minimized`

main window からの切り替えも Status Item からの切り替えも、同じ controller 経由にする。

### ContentView

WindowBoard ウインドウに依存するUIと操作を担当する。

- board window の位置監視
- board移動時のfollow処理
- boardクリック処理
- WindowBoard の一時前面化
- main window 上のボタン・一覧・workspace UI

### AccessibilityWindowService

外部ウインドウに対する AX 操作を担当する。

- window list取得
- position / size取得
- position / size設定
- minimize / restore
- activate / raise
- saved reference からの best-effort open / reconnect

---

## Workspace Switch Behavior

workspace切り替えは、体感速度と復元安定性を両立するため、段階的に行う。

1. 現在のactive workspaceの位置・サイズを保存する。
2. 切り替え先workspaceの全attached windowをplaceholderとして即表示する。
3. キャッシュ済みwindow、fresh window list、open/reconnect pollingの順に候補を探す。
4. 見つかったwindowからplaceholder行へ即反映する。
5. 未解決windowには一括でopen/activateを発火する。
6. `listWindows()` は共有polling loopで読み、未解決reference全部を同じ一覧に照合する。
7. position / size は必要な場合だけ復元する。
8. `raise` はwindowごとに即実行せず、可能な範囲で最後にまとめる。
9. `Minimize Unattached On Workspace Switch` はworkspace表示後に後追いで実行する。
10. Status Item 経由では WindowBoard ウインドウを開かず、保存済み絶対位置を優先する。

---

## Attached Window Lifecycle

attached window は、閉じられた・minimizeされた・stale AX elementになった場合でも、原則としてattached listから消さない。

状態：

- available
- reconnecting
- unavailable

復元方針：

- `windowNumber` / pid / bundle / title / documentURL / saved reference を使ってbest-effortで照合する。
- exact window復元ができないアプリでは、最低限アプリのactivate/openを試す。
- minimized window は候補に含め、必要に応じて `AXMinimized = false` を試す。
- 復元失敗はattached解除ではなく unavailable 状態として表示する。

---

## Current Constraints

- macOSの公開APIでは、他アプリwindowの厳密なz-order保証はできない。
- Full Screen、別Space、特殊パネル、権限不足のwindowは完全制御できない。
- AX resize / move / minimize はアプリ側制約で失敗することがある。
- closed windowの完全復元はアプリ依存であり、同じdocument/windowを必ず開けるとは限らない。
- `Minimize Unattached` はbest-effortであり、同一アプリ複数windowでは誤判定を避けるため保守的に扱う。

---

## Near-Term Priorities

- workspace switchの安定化
- stale / minimized / closed window復元の不具合整理
- UIの整理
- 古い未使用load経路の削除
- Status Item と main window の挙動差の解消
- AX操作のさらなる軽量化
- workspace仕様の固定

---

## 概要

Window Board は、macOS 上で複数のアプリケーションウインドウをグループ化し、一つの作業単位として管理するためのユーティリティアプリである。

一般的なウインドウマネージャが「整列」「リサイズ」「ショートカット移動」を主目的とするのに対し、Window Board は「複数のウインドウをまとめて扱う」ことを目的とする。

例えば、

- Safari（資料）
- PDF（教科書）
- Notes（メモ）

を一つの作業セットとして扱い、まとめて移動・管理できるようにする。

---

# コンセプト

ウインドウを直接埋め込むのではなく、ボードウインドウを基準として対象ウインドウを追従させる。

```text
Board
 ├─ Safari
 ├─ Terminal
 └─ Finder
```

ユーザーからは「ボードにウインドウが貼り付いている」ように見えるが、実際には独立したウインドウとして存在する。

---

# MVP（最小実装）

## 目標

「ボードを動かすと選択した1つのウインドウが追従する」

これを安定して実現する。

---

## MVP機能一覧

### 1. ボードウインドウ

- Window Board用のウインドウを表示
- ドラッグ可能

### 2. ウインドウ一覧取得

現在開いているアプリのウインドウ一覧を取得する。

例：

```text
Safari
Terminal
Finder
Chrome
```

### 3. ウインドウ選択

一覧から対象ウインドウを1つ選択する。

### 4. 相対位置保存

選択時にボードとの相対位置を保存する。

```text
offsetX = targetX - boardX
offsetY = targetY - boardY
```

### 5. 追従移動

ボード移動時に対象ウインドウも移動する。

```text
targetX = boardX + offsetX
targetY = boardY + offsetY
```

### 6. 前面化

ボード移動後に対象ウインドウを前面化する。

---

# UI案

## MVP

```text
Window Board

[ Select Window ]

Attached:
Safari

[ Bring To Front ]
[ Detach ]
```

---

# 使用技術

## 言語

- Swift

## UI

- SwiftUI
- AppKit

## ウインドウ制御

- Accessibility API
- AXUIElement

---

# 必要権限

## アクセシビリティ権限

対象ウインドウの取得・移動のために必要。

確認項目：

```swift
AXIsProcessTrusted()
```

権限がない場合は設定画面へ誘導する。

---

# アーキテクチャ

## Board Window

アプリのメインウインドウ。

責務：

- UI表示
- ドラッグ操作
- ウインドウ管理

## Attached Window

追従対象ウインドウ。

保持する情報：

```swift
struct AttachedWindow {
    let axWindow: AXUIElement
    let pid: pid_t
    var offset: CGPoint
}
```

## Window Tracker

対象ウインドウの位置更新を担当。

---

# MVP対象外

以下は後回しとする。

- 複数ウインドウ対応
- レイアウト保存
- Workspace保存
- ScreenCaptureKit
- リサイズ同期
- 自動吸着
- ショートカット
- 常時最前面化

---

# 将来実装したい機能

## 1. 複数ウインドウ対応

```text
Board
 ├ Safari
 ├ Terminal
 ├ Xcode
 └ Chrome
```

複数ウインドウを同時に追従させる。

---

## 2. Workspace

作業環境を保存する。

例：

### Study

```text
Safari
PDF
Notes
```

### Development

```text
Xcode
Terminal
Browser
```

ワンクリックで復元できるようにする。

---

## 3. レイアウト保存

各ウインドウの配置を記録する。

例：

```text
左側     PDF
右上     Notes
右下     Safari
```

---

## 4. 一括前面化

登録された全ウインドウを前面に戻す。

---

## 5. リサイズ同期

ボードサイズ変更時に対象ウインドウもリサイズする。

---

## 6. 自動吸着

ウインドウがボード付近に来たら自動登録する。

---

## 7. ショートカット対応

例：

```text
⌘⌥B
```

でボードを表示。

---

## 8. ボードの複数作成

例：

```text
Study Board
Development Board
Research Board
```

を同時管理する。

---

## 9. ScreenCaptureKit連携

対象ウインドウのプレビューを表示する。

用途：

- ミニマップ
- サムネイル表示
- 状態確認

---

## 10. スナップ機能

ボード内のレイアウトに沿って自動整列する。

---

## 11. クラウド同期

将来的に設定を同期する。

候補：

- iCloud
- CloudKit

---

# 制約

## 可能

- ウインドウ移動
- ウインドウ位置取得
- ウインドウサイズ変更
- 前面化
- グループ管理

## 不可能または困難

- 他アプリのウインドウ埋め込み
- 他アプリの window.level 変更
- 完全な常時最前面固定
- フルスクリーンウインドウの安定制御

---

# 長期ビジョン

Window Board を単なるウインドウ管理ツールではなく、

「作業空間（Workspace）そのものを管理するプラットフォーム」

へ発展させる。

最終的には、

- 作業セット保存
- ワンクリック復元
- 複数ボード管理
- レイアウト管理
- プレビュー表示

を統合した、macOS向けのウインドウグループマネージャを目指す。
