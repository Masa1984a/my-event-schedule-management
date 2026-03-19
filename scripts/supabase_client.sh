#!/bin/bash
# Supabase REST API ヘルパー
# 使い方: source scripts/supabase_client.sh

SUPABASE_URL="${SUPABASE_URL:?環境変数 SUPABASE_URL が未設定です}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-$SUPABASE_ANON_KEY}"
: "${SUPABASE_KEY:?環境変数 SUPABASE_SERVICE_ROLE_KEY または SUPABASE_ANON_KEY が未設定です}"

supabase_request() {
  local method="$1" endpoint="$2" data="$3"
  curl -s -X "$method" \
    "${SUPABASE_URL}/rest/v1/${endpoint}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    ${data:+-d "$data"}
}

supabase_rpc() {
  local fn_name="$1" data="$2"
  curl -s -X POST \
    "${SUPABASE_URL}/rest/v1/rpc/${fn_name}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H "Content-Type: application/json" \
    ${data:+-d "$data"}
}
