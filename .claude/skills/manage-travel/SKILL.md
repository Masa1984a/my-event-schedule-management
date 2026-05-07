---
name: manage-travel
description: >
  都市間の移動ブロック（フライト、電車、車など）をspeaking_eventsに登録・更新・削除する。
  travel_routesマスタの参照・追加・更新も行う。
  「移動を登録」「フライトを入れて」「新幹線の予定」「移動時間を確保」「移動ルートを追加」
  「札幌から東京への移動」「出張の移動手配」とユーザーが言ったらこのスキルを使う。
  check-conflictsスキルが移動ブロック未登録を検知した場合にもこのスキルに案内される。
  予定そのもの（登壇・会議等）の登録にはregister-eventスキルを使うこと。
---

# 移動ブロック管理

## 前提

このプロジェクトは Vercel Neon (PostgreSQL) を使用。すべての DB アクセスは `scripts/neon_client.sh` 経由で HTTP `/sql` エンドポイントを叩く。

冒頭で必ず初期化：

```bash
set -a && source .env && set +a
source scripts/neon_client.sh
```

## 機能1: 移動ブロックの登録

### 手順

1. ユーザーから移動情報を収集：
   - travel_from: 出発地（必須）
   - travel_to: 到着地（必須）
   - 日付（必須）
   - travel_mode: 移動手段（flight/train/car/bus）
   - 具体的な出発・到着時刻（わかれば）

2. travel_routes マスタから所要時間を取得：

```bash
neon_rows 'SELECT * FROM get_travel_time($1, $2, $3)' '札幌市' '東京都' 'flight'
# モード未指定（最短候補が先頭）
neon_rows 'SELECT * FROM get_travel_time($1, $2)' '札幌市' '東京都'
```

3. 時刻の決定：
   - 具体的な時刻が指定されている → そのまま使用
   - 指定なし＋翌日に予定あり → 翌日の予定の start_at から移動時間を逆算して出発時刻を提案
   - 指定なし＋前日に予定あり → 前日の予定の end_at を出発時刻として到着時刻を算出
   - いずれでもない → ユーザーに確認

4. コンフリクトチェック後、INSERT：

```bash
neon_rows 'INSERT INTO speaking_events
  (title, start_at, end_at, location, is_online, category,
   travel_from, travel_to, travel_mode, notes)
  VALUES ($1, $2, $3, $4, false, '"'"'travel'"'"',
          $5, $6, $7, $8)
  RETURNING id, title, start_at, end_at' \
  '✈️ 札幌→東京（フライト）' \
  '2026-03-23T15:00:00+09:00' '2026-03-23T18:30:00+09:00' \
  '移動中' '札幌市' '東京都' 'flight' \
  '新千歳14:00発 → 羽田15:35着 + 移動'
```

5. 登録結果をサマリ表示

### title の命名規則

移動手段に応じた絵文字を使う：
- flight: `✈️ 出発地→到着地（フライト）`
- train: `🚄 出発地→到着地（JR/電車名）`
- car: `🚗 出発地→到着地（車）`
- bus: `🚌 出発地→到着地（バス）`

## 機能2: travel_routes マスタの管理

### 新規ルート追加

```bash
neon_rows 'INSERT INTO travel_routes
  (from_city, to_city, mode, duration_minutes, notes)
  VALUES ($1, $2, $3, $4::int, $5)
  ON CONFLICT (from_city, to_city, mode) DO UPDATE
    SET duration_minutes = EXCLUDED.duration_minutes,
        notes = EXCLUDED.notes
  RETURNING id, from_city, to_city, mode, duration_minutes' \
  '札幌市' '大阪市' 'flight' '240' '新千歳→関空'
```

### マスタ一覧表示

```bash
neon_rows 'SELECT from_city, to_city, mode, duration_minutes, notes
           FROM travel_routes
           ORDER BY from_city ASC, to_city ASC, mode ASC'
```

### マスタ更新

```bash
neon_rows 'UPDATE travel_routes
           SET duration_minutes = $4::int, notes = $5
           WHERE from_city = $1 AND to_city = $2 AND mode = $3
           RETURNING *' \
  '札幌市' '東京都' 'flight' '220' '更新メモ'
```

## 機能3: 移動ブロックの一括提案

特定期間の予定を分析し、移動ブロックが必要だが未登録のものを一括で提案する。
check-conflicts スキルから案内された場合にこの機能を使う。

### 手順
1. 指定期間の予定を取得（is_online=false かつ category!='travel'）：

```bash
neon_rows "SELECT id, title, start_at, end_at, location
           FROM speaking_events
           WHERE start_at >= \$1 AND start_at <= \$2
             AND is_online = false
             AND category != 'travel'
           ORDER BY start_at ASC" \
  '2026-04-01T00:00:00+09:00' '2026-04-30T23:59:59+09:00'
```

2. 連続するペアで都市が異なるものを抽出（クライアント側で計算）
3. 各ペアについて `get_travel_time` で移動時間を取得
4. 移動ブロック案を一覧表示
5. ユーザーが選択/編集後、`json_to_recordset` で一括 INSERT

## Gotchas

- travel_routes に登録のないルートの場合、ユーザーに所要時間を確認してからマスタにも追加する
- 飛行機移動は「フライト時間+空港アクセス往復」の合計で登録する（フライト時間だけにしない）
- 同じ移動を往復で登録する場合、復路は別レコードとして登録する
- location は「移動中」とする（出発地でも到着地でもない）
- 深夜・早朝の移動ブロックを提案する場合は「前日移動の方がよいかもしれません」と注記する
- `get_travel_time` は双方向検索（from↔to を入れ替えても同じ結果）対応
- パラメータ化（`$1, $2, ...`）を必ず使う。値を SQL 文字列結合しない
