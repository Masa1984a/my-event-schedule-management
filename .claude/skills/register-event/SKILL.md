---
name: register-event
description: >
  新しい登壇・イベント予定を1件Supabaseに登録する。登録前にコンフリクト（時間重複）を
  自動チェックし、物理的な移動が必要な場合はtravel_routesマスタを参照して移動時間を考慮し
  警告する。移動ブロックの自動生成も提案する。
  「予定を追加」「登壇が入った」「新しいイベント」「〇月〇日に〜がある」のように
  ユーザーが新しい予定について言及したらこのスキルを使う。
  既存予定の変更にはupdate-eventスキルを使うこと。
---

# 新規予定登録

## 手順

1. ユーザーから以下の情報を収集（不足分は質問して補完）：
   - title（必須）
   - 日時: start_at, end_at（必須）
   - location（必須）
   - is_online（「オンライン」を含むか推定、確認）
   - category（推定して提示、確認）
   - notes（任意）

2. **登録前コンフリクトチェック**（必ず実行）：

```bash
curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/check_conflicts" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"p_start": "2026-04-09T11:30:00+09:00", "p_end": "2026-04-09T13:30:00+09:00"}'
```

3. **移動必要性チェック**（新規予定がオフラインの場合）：
   - 前後の予定を取得し、都市が異なるオフライン予定があるか確認
   - travel_routesマスタから移動時間を取得：

```bash
curl -s -X POST "${SUPABASE_URL}/rest/v1/rpc/get_travel_time" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"p_from": "札幌市", "p_to": "東京都"}'
```

   - 移動時間が確保できない場合 → 警告
   - 十分な移動ブロックが未登録の場合 → 自動生成を提案

4. 確認後、Supabase REST APIでINSERT

5. **移動ブロック提案**（該当する場合）：
   - 例: 「4/27 函館の予定の前に、札幌→函館の移動（JR北斗 3.5時間）を登録しますか？」
   - 承認されたらcategory='travel'でINSERT（travel_from, travel_to, travel_modeも設定）

6. 登録完了後、登録内容をサマリ表示

## Gotchas

- タイムゾーンは `+09:00` 固定
- ユーザーが「来週の木曜」のような相対日時を使う場合は、今日の日付から算出する
- 終了時刻が未指定の場合、登壇系は90分、会議系は60分、懇親会系は3時間をデフォルト
- 移動ブロックのtitleは「🚄 札幌→函館（JR北斗）」のように移動手段を含める
- 飛行機移動は空港アクセス時間を含めた全体時間で登録する（フライト時間だけにしない）
- Windows環境ではcurlの `-d` に日本語を直接渡すとエンコーディングエラーになる。日本語を含むJSONは一時ファイルに書き出して `-d @/tmp/req.json` で渡すこと
