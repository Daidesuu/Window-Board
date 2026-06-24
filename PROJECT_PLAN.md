# Window Board

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
