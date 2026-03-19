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

## 機能1: 移動ブロックの登録

### 手順

1. ユーザーから移動情報を収集：
   - travel_from: 出発地（必須）
   - travel_to: 到着地（必須）
   - 日付（必須）
   - travel_mode: 移動手段（flight/train/car/bus）
   - 具体的な出発・到着時刻（わかれば）

2. travel_routesマスタから所要時間を取得：

```bash
curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/get_travel_time" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"p_from": "札幌市", "p_to": "東京都", "p_mode": "flight"}'
```

3. 時刻の決定：
   - 具体的な時刻が指定されている → そのまま使用
   - 指定なし＋翌日に予定あり → 翌日の予定の start_at から移動時間を逆算して出発時刻を提案
   - 指定なし＋前日に予定あり → 前日の予定の end_at を出発時刻として到着時刻を算出
   - いずれでもない → ユーザーに確認

4. コンフリクトチェック後、speaking_eventsにINSERT：

```bash
curl -s -X POST "${SUPABASE_URL}/rest/v1/speaking_events" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{
    "title": "✈️ 札幌→東京（フライト）",
    "start_at": "2026-03-23T15:00:00+09:00",
    "end_at": "2026-03-23T18:30:00+09:00",
    "location": "移動中",
    "is_online": false,
    "category": "travel",
    "travel_from": "札幌市",
    "travel_to": "東京都",
    "travel_mode": "flight",
    "notes": "新千歳14:00発 → 羽田15:35着 + 移動"
  }'
```

5. 登録結果をサマリ表示

### titleの命名規則

移動手段に応じた絵文字を使う：
- flight: `✈️ 出発地→到着地（フライト）`
- train: `🚄 出発地→到着地（JR/電車名）`
- car: `🚗 出発地→到着地（車）`
- bus: `🚌 出発地→到着地（バス）`

## 機能2: travel_routesマスタの管理

### 新規ルート追加

ユーザーが新しいルートの移動時間を教えてくれた場合、マスタに追加：

```bash
curl -s -X POST "${SUPABASE_URL}/rest/v1/travel_routes" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"from_city": "札幌市", "to_city": "大阪市", "mode": "flight", "duration_minutes": 240, "notes": "新千歳→関空"}'
```

### マスタ一覧表示

```bash
curl -s "${SUPABASE_URL}/rest/v1/travel_routes?order=from_city.asc,to_city.asc" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}"
```

## 機能3: 移動ブロックの一括提案

特定期間の予定を分析し、移動ブロックが必要だが未登録のものを一括で提案する。
check-conflicts スキルから案内された場合にこの機能を使う。

### 手順
1. 指定期間の予定を取得
2. 連続するオフライン予定で都市が異なるペアを抽出
3. 各ペアについてtravel_routesから移動時間を取得
4. 移動ブロック案を一覧表示
5. ユーザーが選択/編集後、一括INSERT

## Gotchas

- travel_routesに登録のないルートの場合、ユーザーに所要時間を確認してからマスタにも追加する
- 飛行機移動は「フライト時間+空港アクセス往復」の合計で登録する（フライト時間だけにしない）
- 同じ移動を往復で登録する場合、復路は別レコードとして登録する
- locationは「移動中」とする（出発地でも到着地でもない）
- 深夜・早朝の移動ブロックを提案する場合は「前日移動の方がよいかもしれません」と注記する
- Windows環境ではcurlの `-d` に日本語を直接渡すとエンコーディングエラーになる。日本語を含むJSONは一時ファイルに書き出して `-d @/tmp/req.json` で渡すこと
