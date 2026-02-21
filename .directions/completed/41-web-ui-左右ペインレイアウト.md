web のUIについて。pending completedは良いけど、個々のタスクの表示は右ペインに出るべきだ。(メーラーのような感じ)

このルートの画面は上は中央良せの新しい指示の記入エリア。(現在どおり)

下は左右ペインに分けて。
左ペインにPending, Completedを表示可能にして。
右ペインに選択された指示の内容を表示可能。

に変更して。

---

## 作業メモ

`lib/web/server.rb` の root_html を変更し、メーラー風の左右ペインレイアウトを実装した。

### 変更内容

- **レイアウト構造**: 上部（中央寄せの指示入力エリア）と下部（左右ペイン）に分割
  - 左ペイン（幅340px）: Pending / Completed のリスト表示
  - 右ペイン（残り幅）: 選択された指示の詳細表示、未選択時はプレースホルダー表示
- **CSS変更**:
  - body のパディングを調整、textarea の min-height を 60vh → 120px に縮小
  - `.pane-container`, `.left-pane`, `.right-pane`, `.right-pane-placeholder` を追加
  - `.direction-detail` を flex レイアウトに変更し、右ペイン内で伸縮可能に
  - 選択中のアイテムのハイライト表示（`.direction-item.selected`）を追加
- **JavaScript変更**:
  - `selectedDirectionId` で選択状態を追跡
  - 指示選択時にリスト内のアイテムをハイライト、プレースホルダーを非表示
  - 閉じるボタンで選択解除、プレースホルダーを再表示
  - リスト再描画時にも選択状態を維持
