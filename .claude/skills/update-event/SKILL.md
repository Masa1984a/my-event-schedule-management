---
name: update-event
description: >
  既存の登壇・イベント予定を更新または削除する。日時変更、場所変更、キャンセルなどに対応。
  更新前にコンフリクトチェックを実行する。移動ブロックの連動更新も行う。
  「予定を変更」「時間が変わった」「キャンセルになった」「場所が変わった」「リスケ」と
  ユーザーが言ったらこのスキルを使う。新規登録にはregister-eventスキルを使うこと。
---

# 予定更新・削除

## 手順

1. 対象イベントの特定：
   - ユーザーの言及内容（タイトルや日時の断片）から検索

```bash
# タイトルで部分一致検索
curl -s "${SUPABASE_URL}/rest/v1/speaking_events?title=ilike.*検索ワード*&order=start_at.asc" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}"
```

   - 候補が複数ある場合はリスト表示してユーザーに選択させる

2. 変更内容の確認：
   - 変更前と変更後を並べて表示
   - ユーザーの承認を得る

3. **日時変更の場合はコンフリクトチェック**（check_conflicts RPCにp_exclude_idで自身を除外）

4. **関連する移動ブロックの確認**：
   - 対象予定の前後にcategory='travel'の予定があり、travel_to またはtravel_fromが対象予定のlocationと一致する場合、連動更新が必要か確認
   - 場所が変わった場合 → 移動ブロックの更新/削除を提案
   - 日時が変わった場合 → 移動ブロックの時間調整を提案
   - キャンセルの場合 → 関連する移動ブロックも削除するか確認

5. Supabase REST API で PATCH（更新）または DELETE（削除）

```bash
# 更新
curl -s -X PATCH "${SUPABASE_URL}/rest/v1/speaking_events?id=eq.{uuid}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"title": "新タイトル", "start_at": "..."}'

# 削除
curl -s -X DELETE "${SUPABASE_URL}/rest/v1/speaking_events?id=eq.{uuid}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}"
```

6. 操作結果をサマリ表示

## Gotchas

- 削除は取り消せないので必ず確認を取る
- ilike検索は日本語でも動作する
- 部分一致で見つからない場合は日付範囲での検索にフォールバック
- category='travel' の予定を直接編集する場合は manage-travel スキルに案内する
- Windows環境ではcurlの `-d` に日本語を直接渡すとエンコーディングエラーになる。日本語を含むJSONは一時ファイルに書き出して `-d @/tmp/req.json` で渡すこと
