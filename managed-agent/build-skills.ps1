<#
.SYNOPSIS
  ローカルの .claude/skills を Claude Managed Agents 用の配布バンドルに変換する。

.DESCRIPTION
  各スキルについて managed-agent/dist/<skill>/ を作り、
    - SKILL.md の bootstrap を「.env 依存」から「~/.neonrc 依存」へ書き換え
    - 共有スクリプト scripts/neon_client.sh を同梱
  したうえで managed-agent/dist/<skill>.zip を生成する（zip ルートに <skill>/ 接頭辞）。

  ローカルの .claude/skills 配下は一切変更しない（dist/ にのみ出力）。

.NOTES
  Managed Agents のサンドボックスには .env が無く、Agent/Environment 定義に
  環境変数を直接渡すフィールドも公式には存在しない。よって DATABASE_URL は
  setup-agent.ps1 がセッション開始時に ~/.neonrc へ書き込み、各スキルはそれを読む。
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$skillsSrc = Join-Path $RepoRoot '.claude\skills'
$neonClient = Join-Path $RepoRoot 'scripts\neon_client.sh'
$distRoot   = Join-Path $PSScriptRoot 'dist'

if (-not (Test-Path $skillsSrc))  { throw "skills ディレクトリが見つかりません: $skillsSrc" }
if (-not (Test-Path $neonClient)) { throw "neon_client.sh が見つかりません: $neonClient" }

# 配布対象スキル（ディレクトリ名）
$skills = @('register-event','update-event','check-conflicts','import-events','manage-travel')

# bootstrap 書き換え: .env を読む行 → ~/.neonrc を読む行
$oldLine = 'set -a && source .env && set +a'
$newLine = 'set -a && . "$HOME/.neonrc" && set +a   # Managed Agents: DATABASE_URL を ~/.neonrc から読込'

# dist をクリーンに作り直す
if (Test-Path $distRoot) { Remove-Item $distRoot -Recurse -Force }
New-Item -ItemType Directory -Path $distRoot | Out-Null

foreach ($skill in $skills) {
  $srcSkillMd = Join-Path $skillsSrc "$skill\SKILL.md"
  if (-not (Test-Path $srcSkillMd)) { throw "SKILL.md が見つかりません: $srcSkillMd" }

  $outDir       = Join-Path $distRoot $skill
  $outScriptDir = Join-Path $outDir 'scripts'
  New-Item -ItemType Directory -Path $outScriptDir -Force | Out-Null

  # SKILL.md を読み、bootstrap を書き換えて出力
  $content = Get-Content -Raw -LiteralPath $srcSkillMd
  if ($content -notmatch [regex]::Escape($oldLine)) {
    Write-Warning "[$skill] 既定の bootstrap 行が見つかりません。手動確認推奨。"
  }
  $content = $content.Replace($oldLine, $newLine)
  # UTF-8 (BOM なし) で書き出す
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $outDir 'SKILL.md'), $content, $utf8)

  # neon_client.sh を同梱（LF を維持するためバイナリコピー）
  Copy-Item -LiteralPath $neonClient -Destination (Join-Path $outScriptDir 'neon_client.sh') -Force

  # zip 化（zip ルートに <skill>/ が来るようフォルダごと圧縮）
  $zipPath = Join-Path $distRoot "$skill.zip"
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Compress-Archive -Path $outDir -DestinationPath $zipPath -Force

  Write-Host "✓ $skill -> $zipPath"
}

Write-Host ""
Write-Host "完了: $distRoot に 5 スキルのバンドルと zip を生成しました。"
Write-Host "次は: .\upload-skills.ps1 でアップロード"
