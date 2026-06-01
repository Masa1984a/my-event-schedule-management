---
name: update-event
description: >
  既存の登壇・イベント予定を更新または削除する。日時変更、場所変更、キャンセルなどに対応。
  更新前にコンフリクトチェックを実行する。移動ブロックの連動更新も行う。
  「予定を変更」「時間が変わった」「キャンセルになった」「場所が変わった」「リスケ」と
  ユーザーが言ったらこのスキルを使う。新規登録にはregister-eventスキルを使うこと。
---

# 予定更新・削除

## 前提

このプロジェクトは Vercel Neon (PostgreSQL) を使用。すべての DB アクセスは `scripts/neon_client.sh` 経由で HTTP `/sql` エンドポイントを叩く。

冒頭で必ず初期化：

```bash
set -a && . "$HOME/.neonrc" && set +a   # Managed Agents: DATABASE_URL を ~/.neonrc から読込
source scripts/neon_client.sh
```

## 手順

1. 対象イベントの特定（タイトル / 日付の断片から検索）：

```bash
# タイトル ILIKE 部分一致
neon_rows 'SELECT id, title, start_at, end_at, location, category
           FROM speaking_events
           WHERE title ILIKE $1
           ORDER BY start_at ASC' '%検索ワード%'

# 日付範囲フォールバック
neon_rows 'SELECT id, title, start_at, end_at, location, category
           FROM speaking_events
           WHERE start_at >= $1 AND start_at <= $2
           ORDER BY start_at ASC' \
  '2026-04-01T00:00:00+09:00' '2026-04-30T23:59:59+09:00'
```

   - 候補が複数ある場合はリスト表示してユーザーに選択させる

2. 変更内容の確認：
   - 変更前と変更後を並べて表示
   - ユーザーの承認を得る

3. **日時変更の場合はコンフリクトチェック**（自身を除外）：

```bash
neon_rows 'SELECT * FROM check_conflicts($1, $2, $3::uuid)' \
  '2026-04-09T11:30:00+09:00' '2026-04-09T13:30:00+09:00' \
  'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
```

4. **関連する移動ブロックの確認**：

```bash
# 対象予定の前後 24h で travel ブロックを取得
neon_rows 'SELECT id, title, start_at, end_at, travel_from, travel_to
           FROM speaking_events
           WHERE category = '"'"'travel'"'"'
             AND start_at BETWEEN ($1::timestamptz - interval '"'"'24 hours'"'"')
                              AND ($2::timestamptz + interval '"'"'24 hours'"'"')
             AND ($3 IS NULL OR travel_from = $3 OR travel_to = $3)
           ORDER BY start_at' \
  '2026-04-09T11:30:00+09:00' '2026-04-09T13:30:00+09:00' '札幌市'
```

   - 場所が変わった場合 → 移動ブロックの更新/削除を提案
   - 日時が変わった場合 → 移動ブロックの時間調整を提案
   - キャンセルの場合 → 関連する移動ブロックも削除するか確認

5. UPDATE / DELETE 実行：

```bash
# 単一カラム更新の例（タイトル変更）
neon_rows 'UPDATE speaking_events
           SET title = $1
           WHERE id = $2::uuid
           RETURNING id, title, start_at' \
  '新タイトル' 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'

# 複数カラム同時更新（日時 + 場所）
neon_rows 'UPDATE speaking_events
           SET start_at = $1, end_at = $2, location = $3
           WHERE id = $4::uuid
           RETURNING id, title, start_at, end_at, location' \
  '2026-04-09T13:00:00+09:00' '2026-04-09T15:00:00+09:00' '東京都' \
  'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'

# 削除
neon_rows 'DELETE FROM speaking_events
           WHERE id = $1::uuid
           RETURNING id, title' \
  'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
```

6. 操作結果をサマリ表示

## Gotchas

- 削除は取り消せないので必ず確認を取る
- ILIKE 検索は日本語でも動作する（`'%札幌%'` のように `%` で挟む）
- 部分一致で見つからない場合は日付範囲での検索にフォールバック
- category='travel' の予定を直接編集する場合は manage-travel スキルに案内する
- updated_at はトリガーで自動更新されるので明示的に SET しない
- UUID は `$N::uuid` キャストが必要
- パラメータ化（`$1, $2, ...`）を必ず使う。値を SQL 文字列結合しない
