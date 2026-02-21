Slackへの通知で出力がうまくされていない。

* 費用と所要時間が出ていない
* 出力がなんか違う気がする
* 空になってしまう場合がある

以下の出力をもとに原因を特定して修正して。

[aijigu] Direction #28 (28-web-startポート指定対応) started
[6:10 PM][aijigu] Direction #28 (28-web-startポート指定対応) completed優先順位: CLI引数 > 環境変数(`AIJIGU_WEB_PORT`) > デフォルト値(8080)
[6:11 PM][aijigu] Direction #29 (29-web送信後タスク名表示とpending定期リロード) started
[6:14 PM][aijigu] Direction #29 (29-web送信後タスク名表示とpending定期リロード) completed3. **定期的なpendingリロード**: `setInterval(loadDirections, 10000)` を追加し、10秒ごとにpending/completedリストを自動更新。
[6:14 PM][aijigu] Direction #31 (31-slack通知が2段階目になっている問題) started
[6:17 PM][aijigu] Direction #31 (31-slack通知が2段階目になっている問題) completed**修正**: `lib/commands/direction.bash` の `result_text` 保存処理に `$attempt -eq 1` の条件を追加。最初の試行（実質的な作業）のメッセージのみを保存するようにし、Slack通知には1段階目の結果が使用されるようにした。
[6:17 PM][aijigu] Direction #30 (30-webメッセージとUI英語化) started
[6:19 PM][aijigu] Direction #30 (30-webメッセージとUI英語化) completedDirection ファイルは `.directions/completed/` に移動済み、変更はコミット済みです。
[6:19 PM][aijigu] Direction #32 (32-slack通知コストと実行時間表示) started
[6:22 PM][aijigu] Direction #32 (32-slack通知コストと実行時間表示) completed
```
```
```[6:22 PM][aijigu] Direction #33 (33-web-completed展開わかりにくい) started
[6:24 PM][aijigu] Direction #33 (33-web-completed展開わかりにくい) completed
137.5s | $0.5493これにより、ユーザーがセクションの展開・折りたたみが可能であることを視覚的に認識できるようになりました。

---

## 作業メモ

`lib/commands/direction.bash` に以下の3つの修正を実施。

### 1. 出力がおかしい問題（コードブロック除去）

`last_msg`（Claudeの結果テキスト）を `` ``` `` コードブロックで囲んでいたが、Claude の出力にバッククォートやMarkdownが含まれるため、Slack の mrkdwn パーサーがコードブロックの開始・終了を誤認し、表示が崩れていた。コードブロック囲みを廃止し、プレーンテキストとして改行区切りで表示するよう変更。また500文字で切り詰めるようにした。

### 2. 空になる問題（result_text 保存条件の緩和）

`result_text` の保存が `$attempt -eq 1` のときのみだったため、初回試行で result が空だった場合にメッセージが一切保存されなかった。初回が空なら後続の試行でも保存するよう条件を `$attempt -eq 1 || ! -f "$last_message_dir/${id}.txt"` に変更。

### 3. 費用と所要時間の抽出フォールバック修正

`jq ... | tail -1 || echo 0` のフォールバックが、`tail -1` が常に成功するため機能していなかった。パラメータ展開のデフォルト値 `${var:-0}` に変更し、jq が出力を返さない場合でも確実に 0 にフォールバックするようにした。
