---
name: import-events
description: >
  テキストやマークダウン形式の予定リストをパースしてSupabaseのspeaking_eventsテーブルに一括登録する。
  このスキルは、ユーザーが複数の予定をまとめて登録したいとき、テキストから予定を読み取って
  インポートしたいとき、「予定を一括登録」「まとめて入れて」「このリストをDBに入れて」と
  言ったときに使う。予定データのフォーマットが明示されていなくても、テキストに日時・タイトル・
  場所が含まれていればこのスキルを使うこと。
---

# 予定一括インポート

## 手順

1. ユーザーから予定データ（テキスト/マークダウン）を受け取る
2. 各予定から以下を抽出する：
   - title: イベント名
   - start_at / end_at: 開始・終了日時（TIMESTAMPTZ、+09:00をデフォルト）
   - location: 場所
   - is_online: 「オンライン」を含む場合は true
   - category: 以下のルールで推定
     - 「授業」「大学」「高専」→ lecture
     - 「登壇」「イベント」「AMA」→ speaking
     - 「懇親会」「お疲れ会」「慰労会」→ social
     - 「Talent Discussion」「Officewide」→ internal
     - 「健康診断」→ health
     - 「移動」「フライト」「新幹線」→ travel
     - それ以外 → other
3. パース結果を一覧表示してユーザーに確認を求める
4. 確認後、Supabase REST API で一括INSERT
5. 登録後、check_conflicts RPCを呼んで重複がないか確認し結果を報告
6. 異なる都市間のオフライン予定が連続する場合、移動ブロックの登録を提案する

## Supabase API 呼び出し

環境変数 `SUPABASE_URL` と `SUPABASE_SERVICE_ROLE_KEY` を使用。

```bash
# 一括INSERT
curl -s -X POST "${SUPABASE_URL}/rest/v1/speaking_events" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '[{...}, {...}]'
```

## Gotchas

- タイムゾーンは必ず `+09:00`（JST）を付与する。ユーザーが省略しても補完すること
- 「札幌市(オンライン)」のような表記は location=札幌市, is_online=true と分離する
- 同一日に複数イベントがある場合（例: 報告会→慰労会）は別レコードとして登録
- category の自動推定結果は必ずユーザーに確認を取ること

## バリデーション

- INSERT前: start_at < end_at であることを検証
- INSERT後: 登録件数が入力件数と一致することを確認
- INSERT後: check_conflicts RPCで重複チェックを実行
- Windows環境ではcurlの `-d` に日本語を直接渡すとエンコーディングエラーになる。日本語を含むJSONは一時ファイルに書き出して `-d @/tmp/req.json` で渡すこと
