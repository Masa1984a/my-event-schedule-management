<#
.SYNOPSIS
  Claude Managed Agents の Agent / Environment / Session を作成し、
  サンドボックスに DATABASE_URL を注入する（bootstrap イベント）。

.DESCRIPTION
  1. .env から DATABASE_URL を読み込む
  2. skill-ids.json の 5 スキルを束ねた Agent を作成
  3. cloud + unrestricted networking の Environment を作成
  4. Session を作成
  5. 「~/.neonrc に DATABASE_URL を書け」という bootstrap user.message を送信
  6. 生成 ID を managed-agent/agent-ids.json に保存

  ⚠ セキュリティ注記: 公式に Agent/Environment へ env var/secret を渡すフィールドが
  無いため、本スクリプトは DATABASE_URL を user.message 経由でサンドボックスに渡す。
  この値はセッションのイベントログ（サーバ側保存）に残る。個人用途では許容範囲だが、
  本番では Vault / egress-proxy 方式への置換を検討すること。

.NOTES
  要: 環境変数 ANTHROPIC_API_KEY。
#>
[CmdletBinding()]
param(
  [string]$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$Model      = 'claude-opus-4-8',
  [string]$AgentName  = 'Schedule Manager',
  [string]$EnvName    = ('schedule-env-' + (Get-Date -Format 'yyyyMMddHHmmss'))
)

$ErrorActionPreference = 'Stop'
if (-not $env:ANTHROPIC_API_KEY) { throw "環境変数 ANTHROPIC_API_KEY が未設定です。" }

$beta = 'managed-agents-2026-04-01'
$headers = @{
  'x-api-key'         = $env:ANTHROPIC_API_KEY
  'anthropic-version' = '2023-06-01'
  'anthropic-beta'    = $beta
  'content-type'      = 'application/json'
}

# --- DATABASE_URL を .env から読む ---
$envFile = Join-Path $RepoRoot '.env'
if (-not (Test-Path $envFile)) { throw ".env が見つかりません: $envFile" }
$dbLine = Get-Content $envFile | Where-Object { $_ -match '^\s*DATABASE_URL\s*=' } | Select-Object -First 1
if (-not $dbLine) { throw ".env に DATABASE_URL がありません。" }
$dbUrl = ($dbLine -replace '^\s*DATABASE_URL\s*=', '').Trim().Trim('"').Trim("'")
if ($dbUrl -match "'") { throw "DATABASE_URL にシングルクオートが含まれており bootstrap が壊れます。手動対応してください。" }

# --- skill-ids.json ---
$idsPath = Join-Path $PSScriptRoot 'skill-ids.json'
if (-not (Test-Path $idsPath)) { throw "skill-ids.json が無い。先に upload-skills.ps1 を実行してください。" }
$ids = Get-Content -Raw $idsPath | ConvertFrom-Json

$skills = @()
foreach ($p in $ids.PSObject.Properties) {
  $skills += @{ type = 'custom'; skill_id = $p.Value; version = 'latest' }
}

$system = @"
あなたは登壇・イベントのスケジュール管理アシスタントです。
データは Neon (PostgreSQL) の speaking_events / travel_routes に保存され、
DB アクセスは各スキル同梱の scripts/neon_client.sh（Neon HTTP /sql）経由で行います。
接続文字列はサンドボックスの ~/.neonrc に DATABASE_URL として保存されています。

ルール:
- 予定の追加/変更/確認/一括取込/移動手配は、必ず対応するスキルの手順に従う。
- 日時のタイムゾーンは +09:00 固定。DB は TIMESTAMPTZ(UTC) で保存される。
- 予定登録・変更の前に必ずコンフリクトチェックを行う。
- オフライン予定では都市間移動の要否を travel_routes で確認し、必要なら移動ブロックを提案する。
- SQL は必ずパラメータ化し、値を文字列結合しない。
"@

# --- 1. Agent ---
Write-Host "Agent を作成中..."
$agentBody = @{
  name   = $AgentName
  model  = $Model
  system = $system
  tools  = @(@{ type = 'agent_toolset_20260401' })
  skills = $skills
} | ConvertTo-Json -Depth 10
$agent = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/agents' -Headers $headers -Body $agentBody
Write-Host "  Agent ID: $($agent.id) (v$($agent.version))"

# --- 2. Environment ---
Write-Host "Environment を作成中..."
$envBody = @{
  name   = $EnvName
  config = @{ type = 'cloud'; networking = @{ type = 'unrestricted' } }
} | ConvertTo-Json -Depth 10
$environment = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/environments' -Headers $headers -Body $envBody
Write-Host "  Environment ID: $($environment.id)"

# --- 3. Session ---
Write-Host "Session を作成中..."
$sessBody = @{
  agent          = $agent.id
  environment_id = $environment.id
  title          = 'Schedule management session'
} | ConvertTo-Json -Depth 10
$session = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/sessions' -Headers $headers -Body $sessBody
Write-Host "  Session ID: $($session.id)"

# --- 4. bootstrap: ~/.neonrc に DATABASE_URL を書く ---
Write-Host "bootstrap（DATABASE_URL 注入）を送信中..."
# 注意（過去のバグ対策）:
#  - `$HOME` は bash 側で展開させる。PowerShell here-string では backtick で `$HOME` をエスケープ。
#  - 接続文字列は `&` を含むため、ファイル内では必ず値を ' ' で括る
#    （括らないと source 時に bash が `&` をバックグラウンド演算子と解釈し URL が切れる）。
$bootstrapText = @"
セットアップを行います。次の bash を実行し、~/.neonrc に DB 接続情報を書き込んでください
（その後 source して接続確認まで行い、成否のみ報告。値はログに出さないこと）:
umask 077 && printf "export DATABASE_URL='%s'\n" '$dbUrl' > "`$HOME/.neonrc" && echo "neonrc written"
"@
$evtBody = @{
  events = @(@{
    type    = 'user.message'
    content = @(@{ type = 'text'; text = $bootstrapText })
  })
} | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Post -Uri "https://api.anthropic.com/v1/sessions/$($session.id)/events" -Headers $headers -Body $evtBody | Out-Null
Write-Host "  bootstrap 送信完了。"

# --- 保存 ---
$out = [ordered]@{
  agent_id       = $agent.id
  agent_version  = $agent.version
  environment_id = $environment.id
  session_id     = $session.id
  created_at     = (Get-Date).ToString('o')
}
$outPath = Join-Path $PSScriptRoot 'agent-ids.json'
$out | ConvertTo-Json | Set-Content -LiteralPath $outPath -Encoding utf8

Write-Host ""
Write-Host "完了。ID は agent-ids.json に保存しました。"
Write-Host ""
Write-Host "=== 動作確認（SSE ストリームを開いてから発話を送る） ==="
Write-Host "ストリーム購読:"
Write-Host "  curl.exe -N https://api.anthropic.com/v1/sessions/$($session.id)/stream ``"
Write-Host "    -H `"x-api-key: `$env:ANTHROPIC_API_KEY`" -H `"anthropic-version: 2023-06-01`" ``"
Write-Host "    -H `"anthropic-beta: $beta`" -H `"Accept: text/event-stream`""
Write-Host ""
Write-Host "発話送信（別ターミナルで）例:"
Write-Host "  「2026/6/14 14:00-15:30 に旭川高専でオンライン登壇。コンフリクト確認して登録して」"
