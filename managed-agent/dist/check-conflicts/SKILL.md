---
name: check-conflicts
description: >
  登録済みの予定一覧を表示し、時間的なコンフリクトや物理的な移動問題がないか確認する。
  移動ブロックの過不足もチェックする。週次・月次のスケジュール概観も提供する。
  「予定を確認」「コンフリクトない？」「来週のスケジュール」「4月の予定」「登壇一覧」
  「被ってる予定ある？」「移動大丈夫？」とユーザーが言ったらこのスキルを使う。
  予定の追加・変更には別のスキル（register-event / update-event）を使うこと。
---

# コンフリクト確認 & スケジュール一覧

## 前提

このプロジェクトは Vercel Neon (PostgreSQL) を使用。すべての DB アクセスは `scripts/neon_client.sh` 経由で HTTP `/sql` エンドポイントを叩く。

冒頭で必ず初期化：

```bash
set -a && . "$HOME/.neonrc" && set +a   # Managed Agents: DATABASE_URL を ~/.neonrc から読込
source scripts/neon_client.sh
```

## 手順

1. 期間の特定：
   - ユーザーが期間を指定 → その範囲で検索
   - 未指定 → 今日から30日間をデフォルト

2. 予定の取得（移動ブロック含む）：

```bash
neon_rows 'SELECT id, title, start_at, end_at, location, is_online, category,
                  travel_from, travel_to, travel_mode, notes
           FROM speaking_events
           WHERE start_at >= $1 AND start_at <= $2
           ORDER BY start_at ASC' \
  '2026-04-01T00:00:00+09:00' '2026-04-30T23:59:59+09:00'
```

3. コンフリクト分析（4種類）：
   - **🔴 時間重複**: 同一時間帯に2件以上 → 要対応
   - **🟡 移動不可**: 同日・異都市でオフライン予定が近接し、移動ブロックが未登録 → 移動時間確認
     - travel_routesマスタから所要時間を取得して判定
   - **🟠 高密度警告**: 1日3件以上 or 週5件以上 → 負荷注意
   - **🔵 移動ブロック未登録**: 異なる都市間のオフライン予定が連続するのに、間にcategory='travel'の予定がない → 登録を推奨

4. 移動ブロック未登録チェックのロジック：
   - 予定を start_at 順に並べる
   - 連続するオフライン予定（is_online=false かつ category!='travel'）の location が異なる場合
   - 間に category='travel' の予定が存在するか確認
   - 存在しない場合 → travel_routes から移動時間を取得し、🔵で報告

5. 移動時間の取得（必要なペアごとに）：

```bash
neon_rows 'SELECT * FROM get_travel_time($1, $2)' '札幌市' '函館市'
```

6. 出力フォーマット：

```
## 📅 2026年4月のスケジュール（12件 + 移動2件）

### 🔴 コンフリクト: 0件
なし

### 🟡 移動注意: 1件
- 4/24 東京(ALTA慰労会 21:00終了) → 4/26 札幌(健康診断 09:00開始)
  ✈️ 必要移動時間: 約3.5時間（フライト+空港アクセス）
  ⚠️ 前日移動推奨。移動ブロックを登録しますか？

### 🔵 移動ブロック未登録: 2件
- 4/17 小樽(小樽商科大学) → 4/20 苫小牧(苫小牧高専): 間2日あり余裕あるが移動ブロック未登録
- 4/20 苫小牧(苫小牧高専) → 4/27 函館(未来大学): 間6日あり余裕あり

### 🟠 高密度: なし

### 📋 予定一覧
| 日付 | 時間 | タイトル | 場所 | 種別 |
|------|------|---------|------|------|
| 4/1  | 09:00-12:00 | FY26 Talent Discussion ML9 | 🖥️ オンライン | internal |
| ...  | ... | ... | ... | ... |
| 🚄   | 終日 | 札幌→東京（フライト）| ✈️ 移動 | travel |
| ...  | ... | ... | ... | ... |
```

7. カテゴリ別の集計：

```bash
neon_rows 'SELECT category, COUNT(*) AS n
           FROM speaking_events
           WHERE start_at >= $1 AND start_at <= $2
           GROUP BY category ORDER BY category' \
  '2026-04-01T00:00:00+09:00' '2026-04-30T23:59:59+09:00'
```

## Gotchas

- DB に格納された TIMESTAMPTZ は UTC で返ってくる（例 `2026-04-09 02:30:00+00`）。表示時は JST(+09:00)に変換すること
- オンライン予定同士のコンフリクトも警告する（同時参加は困難）
- 移動距離チェックは `is_online = false` の予定のみ対象
- category='travel' の予定は移動ブロックとして特別扱い（🚄アイコン表示）
- 予定が0件の場合は「この期間に登録済みの予定はありません」と返す
- 移動ブロック未登録の警告では、manage-travel スキルでの登録を案内する
- 大量の SQL を組み立てる場合は SQL injection を避けるためパラメータ化（`$1, $2, ...`）を必ず使う。値リテラルを文字列結合しない
