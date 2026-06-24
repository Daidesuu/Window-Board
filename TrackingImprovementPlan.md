# Window Board - Smooth Tracking Improvement Plan

## 背景

現在の実装では、Board Window をドラッグした際に対象ウインドウが追従するものの、動きが滑らかではない。

原因として、Accessibility API によるウインドウ移動が通常の NSWindow の移動よりも遅く、さらにドラッグ中に不要な処理が発生している可能性がある。

本ドキュメントでは、追従性能を改善するための実装方針をまとめる。

---

# 現在の問題

以下のような構造だと、ドラッグ中に大量の処理が発生する。

```swift
func windowDidMove(_ notification: Notification) {
    moveAttachedWindow()
    raiseAttachedWindow()
}
```

問題点:

- ドラッグ中に毎回 AXRaise が呼ばれる
- Accessibility API 呼び出し回数が増える
- フォーカスの変化が発生する
- イベント処理が詰まりやすい
- カクつきの原因になる

---

# 改善方針

## 1. ドラッグ中は移動のみ行う

ドラッグ中は対象ウインドウの位置更新だけを行う。

前面化処理は行わない。

```text
Board移動
↓
対象ウインドウ移動
```

---

## 2. 前面化を遅延実行する

ユーザーがドラッグを止めた後に一度だけ AXRaise を実行する。

### debounce方式

```swift
private var raiseWorkItem: DispatchWorkItem?

func scheduleRaise() {
    raiseWorkItem?.cancel()

    let item = DispatchWorkItem { [weak self] in
        self?.raiseAttachedWindow()
    }

    raiseWorkItem = item

    DispatchQueue.main.asyncAfter(
        deadline: .now() + 0.18,
        execute: item
    )
}
```

効果:

- AXRaise回数削減
- ドラッグ中の負荷軽減
- フォーカス変化の抑制

---

# 3. 差分移動方式へ変更

現在:

```text
targetPosition =
boardPosition + offset
```

改善:

```text
dx = currentBoardX - previousBoardX
dy = currentBoardY - previousBoardY

targetX += dx
targetY += dy
```

差分のみ反映する。

### メリット

- 計算量削減
- ジッター軽減
- ボードとの追従性向上

---

# 4. 前回位置を保持する

```swift
private var lastBoardOrigin: CGPoint?
```

Board の移動量のみを対象ウインドウへ反映する。

---

# 5. 小数点座標を丸める

Accessibility API に送る座標は整数化する。

```swift
CGPoint(
    x: round(point.x),
    y: round(point.y)
)
```

効果:

- 微細な揺れを抑制
- 不要な更新を削減

---

# 6. 閾値を設ける

1px未満の変化は無視する。

```swift
if abs(dx) < 1 && abs(dy) < 1 {
    return
}
```

効果:

- API呼び出し回数削減
- CPU使用率低下

---

# 7. ドラッグ中のログ出力を禁止

禁止例:

```swift
print(boardWindow.frame.origin)
```

理由:

- windowDidMove は大量に呼ばれる
- コンソール出力がパフォーマンスを悪化させる

---

# 推奨アーキテクチャ

```text
Board Drag
    ↓
windowDidMove
    ↓
差分計算
    ↓
対象ウインドウ移動
    ↓
scheduleRaise()
    ↓
0.18秒待機
    ↓
AXRaise
```

---

# 推奨実装

```swift
final class BoardWindowController: NSObject, NSWindowDelegate {

    var attachedWindow: AXUIElement?

    private var lastBoardOrigin: CGPoint?

    private var raiseWorkItem: DispatchWorkItem?

    func windowWillMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        lastBoardOrigin = window.frame.origin
    }

    func windowDidMove(_ notification: Notification) {

        guard let boardWindow = notification.object as? NSWindow else {
            return
        }

        let currentOrigin = boardWindow.frame.origin

        guard let lastOrigin = lastBoardOrigin else {
            lastBoardOrigin = currentOrigin
            return
        }

        let dx = currentOrigin.x - lastOrigin.x
        let dy = currentOrigin.y - lastOrigin.y

        if abs(dx) >= 1 || abs(dy) >= 1 {
            moveAttachedWindowBy(dx: dx, dy: dy)
        }

        lastBoardOrigin = currentOrigin

        scheduleRaise()
    }

    private func scheduleRaise() {

        raiseWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.raiseAttachedWindow()
        }

        raiseWorkItem = item

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.18,
            execute: item
        )
    }
}
```

---

# 将来的な最適化

## CADisplayLink相当の同期

将来的には画面リフレッシュレートに合わせて更新する。

目標:

```text
60fps
または
120fps(ProMotion)
```

---

## ウインドウ移動のバッチ処理

複数ウインドウ対応時:

```text
Board
 ├ Safari
 ├ Terminal
 ├ Chrome
 └ Xcode
```

更新をまとめて行う。

---

## ScreenCaptureKitによるプレビュー

追従対象の状態確認用。

MVPでは不要。

---

# 成功条件

以下を満たしたら改善成功とする。

- Safari が自然に追従する
- Finder が自然に追従する
- Terminal が自然に追従する
- ドラッグ中のカクつきが大幅に減る
- CPU使用率が過度に上昇しない
- ドラッグ停止後に対象ウインドウが前面へ戻る

```
:::
```
