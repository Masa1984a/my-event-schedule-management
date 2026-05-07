---
name: import-events
description: >
  テキストやマークダウン形式の予定リストをパースしてspeaking_eventsテーブルに一括登録する。
  このスキルは、ユーザーが複数の予定をまとめて登録したいとき、テキストから予定を読み取って
  インポートしたいとき、「予定を一括登録」「まとめて入れて」「このリストをDBに入れて」と
  言ったときに使う。予定データのフォーマットが明示されていなくても、テキストに日時・タイトル・
  場所が含まれていればこのスキルを使うこと。
---

# 予定一括インポート

## 前提

このプロジェクトは Vercel Neon (PostgreSQL) を使用。すべての DB アクセスは `scripts/neon_client.sh` 経由で HTTP `/sql` エンドポイントを叩く。

冒頭で必ず初期化：

```bash
set -a && source .env && set +a
source scripts/neon_client.sh
```

## 手順

1. ユーザーから予定データ（テキスト/マークダウン）を受け取る
2. 各予定から以下を抽出する：
   - title: イベント名
   - start_at / end_at: 開始・終了日時（TIMESTAMPTZ、`+09:00` をデフォルト）
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

4. 確認後、JSON 配列を作って `json_to_recordset` で一括 INSERT：

```bash
# パース結果を一時ファイル events.json に書き出しておく
# 形式: [{"title": "...", "start_at": "2026-04-09T11:30:00+09:00", "end_at": "...",
#         "location": "札幌市", "is_online": false, "category": "speaking", "notes": ""}, ...]

EVENTS_JSON=$(python -c "import json,sys; print(json.dumps(json.load(open('.claude/worktrees/events.json',encoding='utf-8'))))")

neon_rows 'INSERT INTO speaking_events
  (title, start_at, end_at, location, is_online, category, notes)
SELECT title, start_at, end_at, location, is_online, category, notes
FROM json_to_recordset($1::json) AS t(
  title TEXT, start_at TIMESTAMPTZ, end_at TIMESTAMPTZ,
  location TEXT, is_online BOOLEAN, category TEXT, notes TEXT
)
RETURNING id, title, start_at' "$EVENTS_JSON"
```

5. 登録後、check_conflicts で重複がないか確認し結果を報告：

```bash
# 入力件数の各時間帯について重複チェック (一行ずつ)
neon_rows 'SELECT * FROM check_conflicts($1, $2)' \
  '2026-04-09T11:30:00+09:00' '2026-04-09T13:30:00+09:00'
```

6. 異なる都市間のオフライン予定が連続する場合、移動ブロックの登録を提案する（manage-travel スキルへ案内）

## Gotchas

- タイムゾーンは必ず `+09:00`（JST）を付与する。ユーザーが省略しても補完すること
- 「札幌市(オンライン)」のような表記は location=札幌市, is_online=true と分離する
- 同一日に複数イベントがある場合（例: 報告会→慰労会）は別レコードとして登録
- category の自動推定結果は必ずユーザーに確認を取ること
- `json_to_recordset` を使うと型を明示できて安全。BOOLEAN, TIMESTAMPTZ も自動変換される
- 大量インポート時は事前に `.claude/worktrees/events.json` 等にファイル化して `python -c "..."` で読み込ませると Bash のクオート地獄を回避できる

## バリデーション

- INSERT 前: `start_at < end_at` であることを Python 側で検証
- INSERT 後: `RETURNING` で返された件数が入力件数と一致することを確認
- INSERT 後: 各レコードについて check_conflicts で重複チェックを実行
