# Compiles a report with the @local/mospolytech-gost template (PowerShell tool on Windows).
# usage: typst-gost.ps1 <report.typ> [output.pdf | preview-{p}.png] [extra `typst compile` flags]
# --root is the report's folder, so the report references its files as path("assets/x.png").
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$Data = $env:CLAUDE_PLUGIN_DATA
if (-not $Data) {
  $Data = Get-ChildItem -Directory (Join-Path $env:USERPROFILE '.claude\plugins\data') -Filter 'mospolytech-lms*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'bin\typst.exe') } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Data) { [Console]::Error.WriteLine('typst-gost: Typst не установлен — перезапустите сессию Claude Code, чтобы плагин его скачал'); exit 1 }

$fontPaths = ''
$envFile = Join-Path $Data 'env'
if (Test-Path $envFile) {
  foreach ($line in Get-Content -Encoding UTF8 $envFile) {
    if ($line -match '^LMS_FONT_PATHS=(.*)$') { $fontPaths = $Matches[1] }
  }
}

if ($args.Count -lt 1) { [Console]::Error.WriteLine('usage: typst-gost.ps1 <report.typ> [output] [flags]'); exit 2 }
$src = $args[0]
$rest = @($args | Select-Object -Skip 1)

# The SessionStart hook runs in Git Bash and writes /c/... paths; convert them back.
$fontArgs = @()
foreach ($f in ($fontPaths -split ':(?=/)' | Where-Object { $_ })) {
  if ($f -match '^/([a-zA-Z])/(.*)$') { $f = "$($Matches[1]):\$($Matches[2] -replace '/', '\')" }
  if (Test-Path $f) { $fontArgs += @('--font-path', $f) }
}

& (Join-Path $Data 'bin\typst.exe') compile --root (Split-Path -Parent (Resolve-Path $src)) `
  --package-path (Join-Path $Root 'templates\typst') @fontArgs $src @rest
exit $LASTEXITCODE
