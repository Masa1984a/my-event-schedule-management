---
name: register-event
description: >
  新しい登壇・イベント予定を1件DBに登録する。登録前にコンフリクト（時間重複）を
  自動チェックし、物理的な移動が必要な場合はtravel_routesマスタを参照して移動時間を考慮し
  警告する。移動ブロックの自動生成も提案する。
  「予定を追加」「登壇が入った」「新しいイベント」「〇月〇日に〜がある」のように
  ユーザーが新しい予定について言及したらこのスキルを使う。
  既存予定の変更にはupdate-eventスキルを使うこと。
---

# 新規予定登録

## 前提

このプロジェクトは Vercel Neon (PostgreSQL) を使用。すべての DB アクセスは `scripts/neon_client.sh` 経由で HTTP `/sql` エンドポイントを叩く。

冒頭で必ず初期化：

```bash
set -a && . "$HOME/.neonrc" && set +a   # Managed Agents: DATABASE_URL を ~/.neonrc から読込
source scripts/neon_client.sh
```

## 手順

1. ユーザーから以下の情報を収集（不足分は質問して補完）：
   - title（必須）
   - 日時: start_at, end_at（必須、`+09:00` 付き）
   - location（必須）
   - is_online（「オンライン」を含むか推定、確認）
   - category（推定して提示、確認）
   - notes（任意）

2. **登録前コンフリクトチェック**（必ず実行）：

```bash
neon_rows 'SELECT * FROM check_conflicts($1, $2)' \
  '2026-04-09T11:30:00+09:00' '2026-04-09T13:30:00+09:00'
```

3. **移動必要性チェック**（新規予定がオフラインの場合）：
   - 前後の予定を取得し、都市が異なるオフライン予定があるか確認

```bash
# 直前の予定（前日 〜 当日 start_at まで）
neon_rows 'SELECT title, start_at, end_at, location, category
           FROM speaking_events
           WHERE end_at <= $1 AND is_online = false
           ORDER BY end_at DESC LIMIT 1' '2026-04-09T11:30:00+09:00'

# 直後の予定
neon_rows 'SELECT title, start_at, end_at, location, category
           FROM speaking_events
           WHERE start_at >= $1 AND is_online = false
           ORDER BY start_at ASC LIMIT 1' '2026-04-09T13:30:00+09:00'
```

   - travel_routes マスタから移動時間を取得：

```bash
neon_rows 'SELECT * FROM get_travel_time($1, $2)' '札幌市' '東京都'
# モード指定あり
neon_rows 'SELECT * FROM get_travel_time($1, $2, $3)' '札幌市' '東京都' 'flight'
```

   - 移動時間が確保できない場合 → 警告
   - 十分な移動ブロックが未登録の場合 → 自動生成を提案

4. 確認後、INSERT：

```bash
neon_rows 'INSERT INTO speaking_events
  (title, start_at, end_at, location, is_online, category, notes)
  VALUES ($1, $2, $3, $4, $5::boolean, $6, $7)
  RETURNING id, title, start_at, end_at' \
  'Findy主催「Claude Code Skills実践！」' \
  '2026-04-09T11:30:00+09:00' '2026-04-09T13:30:00+09:00' \
  '札幌市' 'true' 'speaking' ''
```

5. **移動ブロック提案**（該当する場合）：
   - 例: 「4/27 函館の予定の前に、札幌→函館の移動（JR北斗 3.5時間）を登録しますか？」
   - 承認されたら category='travel' で INSERT（travel_from, travel_to, travel_mode も設定）

```bash
neon_rows 'INSERT INTO speaking_events
  (title, start_at, end_at, location, is_online, category,
   travel_from, travel_to, travel_mode, notes)
  VALUES ($1, $2, $3, $4, false, '"'"'travel'"'"',
          $5, $6, $7, $8)
  RETURNING id, title' \
  '🚄 札幌→函館（JR北斗）' \
  '2026-04-27T07:00:00+09:00' '2026-04-27T10:30:00+09:00' \
  '移動中' '札幌市' '函館市' 'train' 'JR北斗 約3.5時間'
```

6. 登録完了後、登録内容をサマリ表示

## Gotchas

- タイムゾーンは `+09:00` 固定（DB は TIMESTAMPTZ で UTC 保存される）
- ユーザーが「来週の木曜」のような相対日時を使う場合は、今日の日付から算出する
- 終了時刻が未指定の場合、登壇系は90分、会議系は60分、懇親会系は3時間をデフォルト
- 移動ブロックの title は「🚄 札幌→函館（JR北斗）」のように移動手段を含める
- 飛行機移動は空港アクセス時間を含めた全体時間で登録する（フライト時間だけにしない）
- パラメータ化（`$1, $2, ...`）を必ず使う。値を SQL 文字列結合しない
- BOOLEAN は文字列 `'true'`/`'false'` を渡し、SQL 内で `$N::boolean` キャストする
- `category='travel'` のように SQL 内のリテラル文字列はシングルクオートで囲み、Bash 上ではエスケープ（`'"'"'travel'"'"'`）が必要
